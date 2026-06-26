import AppKit
import Foundation
import IOKit.pwr_mgt
import ServiceManagement

// Vigilus — a menu bar app that controls Mac sleep two ways:
//   1. Power assertions (temporary, no admin) — like `caffeinate`.
//   2. pmset system settings (permanent, needs admin) — like `sudo pmset`.

// MARK: - Shell helpers

/// Runs a non-privileged command and returns its stdout.
func runShell(_ launchPath: String, _ args: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

/// Runs a command with admin rights via macOS's native auth dialog.
/// Returns true on success (user authenticated and command exited cleanly).
@discardableResult
func runPrivileged(_ shellCommand: String) -> Bool {
    let escaped = shellCommand.replacingOccurrences(of: "\"", with: "\\\"")
    let source = "do shell script \"\(escaped)\" with administrator privileges"
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return false }
    script.executeAndReturnError(&error)
    return error == nil
}

// MARK: - Temporary sleep prevention (IOKit power assertions)

final class SleepController {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    /// Persisted across launches; defaults to true on first run.
    var keepDisplayAwake: Bool {
        get { UserDefaults.standard.object(forKey: "keepDisplayAwake") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepDisplayAwake") }
    }

    @discardableResult
    func enable() -> Bool {
        guard !isActive else { return true }
        let assertionType = keepDisplayAwake
            ? kIOPMAssertionTypeNoDisplaySleep as CFString
            : kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        let reason = "Vigilus: keeping the Mac awake" as CFString
        let result = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        isActive = (result == kIOReturnSuccess)
        return isActive
    }

    func disable() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }

    func toggle() {
        if isActive { disable() } else { enable() }
    }
}

// MARK: - Permanent system sleep settings (pmset)

/// One power source that can be toggled independently.
enum PowerSource: String {
    case ac = "AC"
    case battery = "Battery"

    var header: String { self == .ac ? "AC Power" : "Battery Power" }
    var pmsetFlag: String { self == .ac ? "-c" : "-b" } // -c = charger, -b = battery
}

final class PmsetController {
    private let defaults = UserDefaults.standard
    private let defaultSleepMinutes = 1

    private func savedKey(_ source: PowerSource) -> String { "savedSleep_\(source.rawValue)" }

    /// True when the Mac is currently running on wall power.
    func activeSourceIsAC() -> Bool {
        (runShell("/usr/bin/pmset", ["-g", "ps"]) ?? "").contains("AC Power")
    }

    /// Reads the *configured* idle-sleep timers from `pmset -g custom` for one
    /// source ("AC Power" or "Battery Power"). Uses `custom` rather than `-g`
    /// so transient "(prevented by …)" state doesn't distort the value.
    /// Returns nil if that source has no block (e.g. Battery on a desktop).
    func settings(for header: String) -> (sleep: Int, displaySleep: Int, disabled: Bool)? {
        guard let output = runShell("/usr/bin/pmset", ["-g", "custom"]) else { return nil }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)

        var block: [Substring] = []
        var capturing = false
        var matched = false
        var sawAnyHeader = false
        for line in lines {
            if line.hasPrefix("AC Power") || line.hasPrefix("Battery Power") {
                sawAnyHeader = true
                capturing = line.hasPrefix(header)
                if capturing { matched = true }
            } else if capturing {
                block.append(line)
            }
        }
        // Single-source machine (desktop): one unlabeled block == AC.
        let scope: [Substring]
        if matched { scope = block }
        else if !sawAnyHeader && header == "AC Power" { scope = lines }
        else { return nil }

        func value(of key: String) -> Int? {
            for line in scope {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2, parts[0] == Substring(key) { return Int(parts[1]) }
            }
            return nil
        }
        guard let s = value(of: "sleep"), let d = value(of: "displaysleep") else { return nil }
        return (s, d, (value(of: "disablesleep") ?? 0) == 1)
    }

    /// Whether idle sleep is currently active (the Mac will sleep) for a source.
    /// nil means the source doesn't exist (e.g. Battery on a desktop).
    func sleepEnabled(for source: PowerSource) -> Bool? {
        guard let s = settings(for: source.header) else { return nil }
        return !s.disabled && s.sleep > 0
    }

    /// Turns idle sleep on or off for a single source (needs admin).
    /// When disabling, the current sleep timer is remembered so enabling can
    /// restore it; when enabling, that remembered value (or a sane default) is
    /// used so sleep genuinely comes back instead of staying at "Never".
    @discardableResult
    func setSleep(enabled: Bool, for source: PowerSource) -> Bool {
        let flag = source.pmsetFlag
        if enabled {
            var minutes = defaults.integer(forKey: savedKey(source))
            if minutes <= 0 { minutes = defaultSleepMinutes }
            // Clear any global disablesleep too, so sleep can actually happen.
            return runPrivileged("/usr/bin/pmset \(flag) sleep \(minutes) disablesleep 0")
        } else {
            // Remember the real timer before zeroing it.
            if let cur = settings(for: source.header), cur.sleep > 0 {
                defaults.set(cur.sleep, forKey: savedKey(source))
            }
            return runPrivileged("/usr/bin/pmset \(flag) sleep 0")
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let sleepController = SleepController()
    private let pmset = PmsetController()
    private let scheduler = Scheduler()
    private lazy var scheduleWindow = ScheduleWindowController(scheduler: scheduler)
    private lazy var scheduleStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private lazy var toggleItem = NSMenuItem(title: "", action: #selector(toggleSleep), keyEquivalent: "s")
    private lazy var awakeStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var displayItem = NSMenuItem(title: "Also Keep Display Awake", action: #selector(toggleDisplay), keyEquivalent: "")
    private lazy var acItem = NSMenuItem(title: "", action: #selector(toggleAC), keyEquivalent: "")
    private lazy var batteryItem = NSMenuItem(title: "", action: #selector(toggleBattery), keyEquivalent: "")
    private lazy var loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    /// Timer that auto-releases the assertion, and when it will fire.
    private var sleepTimer: Timer?
    private var awakeUntil: Date?
    private let scheduleOptions: [(title: String, minutes: Int)] = [
        ("15 Minutes", 15), ("30 Minutes", 30), ("1 Hour", 60), ("2 Hours", 120), ("4 Hours", 240),
    ]

    private lazy var sloganItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var sloganIndex = 0
    private let slogans = [
        "✨ Lumos! — never let your Mac sleep on the job",
        "🦉 Constant vigilance!",
        "⚡ Mischief managed — it sleeps when you say so",
        "🕯️ I solemnly swear to keep your screen alight",
        "🪄 Lumos Maxima!",
    ]

    private static func sloganStyled(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.wantsLayer = true // needed for the glow animation
        let menu = NSMenu()
        menu.delegate = self // refresh the live status line each time the menu opens

        // Slogan header (rotates each time the menu opens)
        sloganItem.isEnabled = false
        sloganItem.attributedTitle = Self.sloganStyled(slogans[0])
        menu.addItem(sloganItem)
        menu.addItem(.separator())

        // --- Temporary (no admin) ---
        toggleItem.target = self
        menu.addItem(toggleItem)

        // "Prevent Sleep for ▸" timed submenu.
        let scheduleItem = NSMenuItem(title: "Prevent Sleep for", action: nil, keyEquivalent: "")
        let scheduleMenu = NSMenu()
        for option in scheduleOptions {
            let item = NSMenuItem(title: option.title, action: #selector(scheduleSleep(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.minutes
            scheduleMenu.addItem(item)
        }
        scheduleItem.submenu = scheduleMenu
        menu.addItem(scheduleItem)

        awakeStatusItem.isEnabled = false // live countdown, non-clickable
        menu.addItem(awakeStatusItem)

        displayItem.target = self
        menu.addItem(displayItem)

        // Recurring weekly schedule.
        menu.addItem(.separator())
        scheduleStatusItem.isEnabled = false
        menu.addItem(scheduleStatusItem)
        let editScheduleItem = NSMenuItem(title: "Edit Schedule…", action: #selector(openSchedule), keyEquivalent: "")
        editScheduleItem.target = self
        menu.addItem(editScheduleItem)

        // --- System settings (pmset, admin) ---
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Config system sleep by pmset", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        note.isEnabled = false
        note.attributedTitle = NSAttributedString(
            string: "This lasts permanently — even after you quit the app.",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]
        )
        menu.addItem(note)

        acItem.target = self
        menu.addItem(acItem)
        batteryItem.target = self
        menu.addItem(batteryItem)

        // --- App preferences ---
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit Vigilus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        scheduler.onChange = { [weak self] in self?.refreshUI() }
        scheduler.start()
        restoreManualState() // auto-resume manual Prevent Sleep from last session
        refreshUI()
    }

    @objc private func openSchedule() {
        scheduleWindow.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // closing the schedule window keeps the menu bar app running
    }

    // Refresh the live pmset status line right before the menu is shown.
    func menuWillOpen(_ menu: NSMenu) {
        sloganItem.attributedTitle = Self.sloganStyled(slogans[sloganIndex])
        sloganIndex = (sloganIndex + 1) % slogans.count
        refreshUI()
    }

    // MARK: Temporary assertion actions

    @objc private func toggleSleep() {
        let wasActive = sleepController.isActive
        sleepController.toggle()
        if !sleepController.isActive { cancelTimer() } // manual off clears any schedule
        persistManualState()
        refreshUI()
        if !wasActive, sleepController.isActive { sparkleBurst() } // cast Lumos ✨
    }

    @objc private func scheduleSleep(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        startTimedPrevent(seconds: Double(minutes) * 60)
    }

    /// Enables the manual assertion and auto-releases after `seconds`.
    private func startTimedPrevent(seconds: TimeInterval) {
        cancelTimer()
        sleepController.enable()
        awakeUntil = Date().addingTimeInterval(seconds)
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.sleepController.disable()
            self?.cancelTimer()
            self?.persistManualState()
            self?.refreshUI()
        }
        // common modes so it still fires while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
        persistManualState()
        refreshUI()
        sparkleBurst() // cast Lumos ✨
    }

    private func cancelTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        awakeUntil = nil
    }

    /// Remembers whether manual Prevent Sleep is on (and any timer end time) so
    /// it can auto-resume on the next launch.
    private func persistManualState() {
        let d = UserDefaults.standard
        d.set(sleepController.isActive, forKey: "preventSleepActive")
        if sleepController.isActive, let until = awakeUntil {
            d.set(until.timeIntervalSinceReferenceDate, forKey: "preventSleepUntil")
        } else {
            d.removeObject(forKey: "preventSleepUntil")
        }
    }

    /// Restores manual Prevent Sleep saved by a previous session.
    private func restoreManualState() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "preventSleepActive") else { return }
        if let untilTI = d.object(forKey: "preventSleepUntil") as? Double {
            let remaining = Date(timeIntervalSinceReferenceDate: untilTI).timeIntervalSinceNow
            if remaining > 0 {
                startTimedPrevent(seconds: remaining) // resume with the time that was left
            } else {
                persistManualState() // timer had already expired; clear it
            }
        } else {
            sleepController.enable() // indefinite prevent
        }
    }

    // MARK: Launch at login

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Couldn't change Launch at Login",
                  "\(error.localizedDescription)\n\nThis works best when Vigilus is in your Applications folder.")
        }
        refreshUI()
    }

    @objc private func toggleDisplay() {
        sleepController.keepDisplayAwake.toggle()
        if sleepController.isActive { sleepController.disable(); sleepController.enable() }
        refreshUI()
    }

    // MARK: pmset actions

    @objc private func toggleAC() { toggleSource(.ac) }
    @objc private func toggleBattery() { toggleSource(.battery) }

    private func toggleSource(_ source: PowerSource) {
        guard let enabled = pmset.sleepEnabled(for: source) else { return }
        let ok = pmset.setSleep(enabled: !enabled, for: source)
        if !ok { alert("Authorization cancelled", "Sleep on \(source.rawValue) was not changed.") }
        refreshUI()
    }

    // MARK: UI

    private func refreshUI() {
        let manualActive = sleepController.isActive
        let awake = manualActive || scheduler.isKeepingAwakeNow
        if let button = statusItem.button {
            let symbol = awake ? "flame.fill" : "moon.stars.fill"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: awake ? "Keeping awake" : "Sleep allowed")
            button.image?.isTemplate = true
        }
        toggleItem.title = manualActive ? "Allow Sleep" : "Prevent Sleep"
        displayItem.state = sleepController.keepDisplayAwake ? .on : .off

        // Schedule status line.
        let ruleCount = scheduler.rules.count
        let scheduleText: String
        if scheduler.isKeepingAwakeNow {
            scheduleText = "Schedule: keeping awake now"
        } else if ruleCount == 0 {
            scheduleText = "Schedule: none set"
        } else {
            scheduleText = "Schedule: \(ruleCount) rule\(ruleCount == 1 ? "" : "s"), idle"
        }
        scheduleStatusItem.attributedTitle = NSAttributedString(
            string: scheduleText,
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor]
        )

        // Live countdown line, shown only while a timed schedule is running.
        if manualActive, let until = awakeUntil {
            let remaining = max(0, until.timeIntervalSinceNow)
            awakeStatusItem.isHidden = false
            awakeStatusItem.attributedTitle = NSAttributedString(
                string: "Awake for \(Self.formatRemaining(remaining)) more",
                attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor.secondaryLabelColor]
            )
        } else {
            awakeStatusItem.isHidden = true
        }

        // Per-source pmset toggles. Status starts at a fixed left-aligned
        // column far to the right, so the ✔ / ✘ marks line up vertically.
        func apply(_ item: NSMenuItem, label: String, source: PowerSource) {
            guard let enabled = pmset.sleepEnabled(for: source) else {
                item.isHidden = true // no such source (e.g. Battery on a desktop)
                return
            }
            item.isHidden = false
            // U+FE0E forces monochrome text presentation of the glyph.
            let status = enabled ? "\u{2714}\u{FE0E} Active" : "\u{2718}\u{FE0E} Disabled"
            item.attributedTitle = Self.columnTitle(label: "Sleep on \(label)", status: status)
        }
        apply(acItem, label: "AC", source: .ac)
        apply(batteryItem, label: "Battery", source: .battery)

        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    /// Formats a duration in seconds as "1h 23m", "45m", or "30s".
    private static func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// Builds a menu-item title with the label on the left and the status in a
    /// fixed left-aligned column pushed far right (via a left tab stop), so the
    /// status marks align vertically across rows.
    private static func columnTitle(label: String, status: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 170)]
        return NSAttributedString(
            string: "\(label)\t\(status)",
            attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style]
        )
    }

    /// A quick twinkle on the icon the moment Lumos is cast.
    private func sparkleBurst() {
        guard let layer = statusItem.button?.layer else { return }
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [1.0, 0.15, 1.0, 0.45, 1.0]
        flash.keyTimes = [0.0, 0.18, 0.42, 0.66, 1.0]
        flash.duration = 0.55
        flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(flash, forKey: "burst")
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleepController.disable()
    }
}

/// One-time copy of saved preferences from the old bundle id (local.sleepmac)
/// to the current one, so renaming doesn't lose the user's settings.
func migrateDefaultsFromOldBundle() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: "migratedFromSleepmac") else { return }
    if let old = UserDefaults().persistentDomain(forName: "local.sleepmac") {
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
    defaults.set(true, forKey: "migratedFromSleepmac")
}

migrateDefaultsFromOldBundle() // must run before AppDelegate loads its state

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
