import AppKit
import Foundation

// Recurring weekly keep-awake schedule. A rule says: on these weekdays, between
// this start and end time, keep the Mac awake. A background timer evaluates the
// rules every half-minute and holds/releases a power assertion accordingly.

// MARK: - Model

struct ScheduleRule: Codable, Equatable {
    var enabled: Bool = true
    var days: Set<Int> = [2, 3, 4, 5, 6]   // Calendar weekday: 1=Sun … 7=Sat (default Mon–Fri)
    var startMinutes: Int = 9 * 60          // minutes from midnight
    var endMinutes: Int = 18 * 60

    /// Same-day ranges only (start < end); an empty/inverted range never matches.
    func matches(weekday: Int, minutes: Int) -> Bool {
        guard enabled, days.contains(weekday), startMinutes < endMinutes else { return false }
        return minutes >= startMinutes && minutes < endMinutes
    }

    /// Identity for duplicate detection (ignores the enabled flag).
    var signature: String { "\(days.sorted())-\(startMinutes)-\(endMinutes)" }

    var isValidRange: Bool { startMinutes < endMinutes }

    /// True if this rule shares a day with `other` and their time ranges overlap.
    func overlaps(_ other: ScheduleRule) -> Bool {
        guard isValidRange, other.isValidRange, !days.isDisjoint(with: other.days) else { return false }
        return startMinutes < other.endMinutes && other.startMinutes < endMinutes
    }
}

/// Collapses overlapping/adjacent windows on shared days into the minimum set of
/// rules. Enabled rules are merged per weekday; disabled or invalid rules pass
/// through untouched.
func mergeOverlappingRules(_ rules: [ScheduleRule]) -> [ScheduleRule] {
    let mergeable = rules.filter { $0.enabled && $0.isValidRange }
    let passthrough = rules.filter { !($0.enabled && $0.isValidRange) }

    // Per weekday, merge sorted intervals that overlap or touch.
    var perDay: [Int: [(start: Int, end: Int)]] = [:]
    for day in 1...7 {
        let intervals = mergeable.filter { $0.days.contains(day) }
            .map { (start: $0.startMinutes, end: $0.endMinutes) }
            .sorted { $0.start < $1.start }
        var merged: [(start: Int, end: Int)] = []
        for iv in intervals {
            if let last = merged.last, iv.start <= last.end {
                merged[merged.count - 1].end = max(last.end, iv.end)
            } else {
                merged.append(iv)
            }
        }
        if !merged.isEmpty { perDay[day] = merged }
    }

    // Recombine: group the days that share each identical merged interval.
    var byInterval: [String: (start: Int, end: Int, days: Set<Int>)] = [:]
    for (day, intervals) in perDay {
        for iv in intervals {
            byInterval["\(iv.start)-\(iv.end)", default: (iv.start, iv.end, [])].days.insert(day)
        }
    }

    let mergedRules = byInterval.values
        .map { ScheduleRule(enabled: true, days: $0.days, startMinutes: $0.start, endMinutes: $0.end) }
        .sorted { ($0.startMinutes, $0.days.min() ?? 0) < ($1.startMinutes, $1.days.min() ?? 0) }

    return mergedRules + passthrough
}

enum ScheduleStore {
    private static let key = "scheduleRules"

    static func load() -> [ScheduleRule] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rules = try? JSONDecoder().decode([ScheduleRule].self, from: data) else { return [] }
        return rules
    }

    static func save(_ rules: [ScheduleRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Evaluator

final class Scheduler {
    private let controller = SleepController()
    private var timer: Timer?

    /// Called whenever the scheduled assertion turns on or off.
    var onChange: (() -> Void)?

    var rules: [ScheduleRule] = ScheduleStore.load()
    var isKeepingAwakeNow: Bool { controller.isActive }

    func start() {
        evaluate()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.evaluate() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func saveRules(_ newRules: [ScheduleRule]) {
        rules = newRules
        ScheduleStore.save(newRules)
        evaluate()
    }

    private func evaluate() {
        let comps = Calendar.current.dateComponents([.weekday, .hour, .minute], from: Date())
        let weekday = comps.weekday ?? 1
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let want = rules.contains { $0.matches(weekday: weekday, minutes: minutes) }

        if want, !controller.isActive {
            controller.enable()
            onChange?()
        } else if !want, controller.isActive {
            controller.disable()
            onChange?()
        }
    }
}

// MARK: - One editable rule row

final class RuleRowView: NSStackView {
    private let enabledBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var dayButtons: [NSButton] = []
    private let fromPicker = NSDatePicker()
    private let toPicker = NSDatePicker()

    private let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]
    private let weekdayValues = [2, 3, 4, 5, 6, 7, 1] // Calendar weekday, Monday first

    var onChange: (() -> Void)?
    var onDelete: (() -> Void)?

    init(rule: ScheduleRule) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 4
        alignment = .centerY

        enabledBox.state = rule.enabled ? .on : .off
        enabledBox.target = self
        enabledBox.action = #selector(changed)
        addArrangedSubview(enabledBox)

        for (i, label) in dayLabels.enumerated() {
            let b = NSButton(title: label, target: self, action: #selector(changed))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .rounded
            b.state = rule.days.contains(weekdayValues[i]) ? .on : .off
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            dayButtons.append(b)
            addArrangedSubview(b)
        }

        addArrangedSubview(NSTextField(labelWithString: "  from"))
        configure(fromPicker, minutes: rule.startMinutes)
        addArrangedSubview(fromPicker)
        addArrangedSubview(NSTextField(labelWithString: "to"))
        configure(toPicker, minutes: rule.endMinutes)
        addArrangedSubview(toPicker)

        let del = NSButton(title: "✕", target: self, action: #selector(deleteTapped))
        del.bezelStyle = .circular
        addArrangedSubview(del)

        warnLabel.toolTip = "Overlaps or duplicates another rule"
        warnLabel.isHidden = true
        addArrangedSubview(warnLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private let warnLabel = NSTextField(labelWithString: "⚠︎")

    func markConflict(_ hasConflict: Bool) {
        warnLabel.isHidden = !hasConflict
    }

    private func configure(_ picker: NSDatePicker, minutes: Int) {
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = Self.date(fromMinutes: minutes)
        picker.target = self
        picker.action = #selector(changed)
    }

    var rule: ScheduleRule {
        var days = Set<Int>()
        for (i, b) in dayButtons.enumerated() where b.state == .on { days.insert(weekdayValues[i]) }
        return ScheduleRule(
            enabled: enabledBox.state == .on,
            days: days,
            startMinutes: Self.minutes(from: fromPicker.dateValue),
            endMinutes: Self.minutes(from: toPicker.dateValue)
        )
    }

    @objc private func changed() { onChange?() }
    @objc private func deleteTapped() { onDelete?() }

    static func date(fromMinutes m: Int) -> Date {
        var c = DateComponents()
        c.year = 2000; c.month = 1; c.day = 1
        c.hour = m / 60; c.minute = m % 60
        return Calendar.current.date(from: c) ?? Date()
    }

    static func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

/// Top-left origin so scroll content stacks from the top, not the bottom.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Settings window

final class ScheduleWindowController: NSWindowController {
    private let scheduler: Scheduler
    private let rulesStack = NSStackView()
    private var rows: [RuleRowView] = []

    init(scheduler: Scheduler) {
        self.scheduler = scheduler
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Keep-Awake Schedule"
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        guard let window = window else { return }

        let header = NSTextField(labelWithString: "The Mac will stay awake during these times:")
        header.font = .boldSystemFont(ofSize: 13)

        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 8

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rulesStack)
        rulesStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rulesStack.topAnchor.constraint(equalTo: doc.topAnchor),
            rulesStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            rulesStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            rulesStack.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor),
        ])
        scroll.documentView = doc

        let addButton = NSButton(title: "+ Add Rule", target: self, action: #selector(addRule))
        addButton.bezelStyle = .rounded
        let dedupButton = NSButton(title: "Remove Duplicates", target: self, action: #selector(removeDuplicates))
        dedupButton.bezelStyle = .rounded
        let mergeButton = NSButton(title: "Merge Overlaps", target: self, action: #selector(mergeOverlaps))
        mergeButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [addButton, dedupButton, mergeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let footer = NSTextField(labelWithString: "Times are same-day (end must be after start). Changes apply immediately.")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor

        let outer = NSStackView(views: [header, scroll, buttonRow, footer])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 12
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let content = window.contentView!
        content.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -32),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    private func rebuild() {
        // Clear everything (rule rows AND any "no rules" placeholder).
        rulesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = scheduler.rules.map { rule in
            let row = RuleRowView(rule: rule)
            row.onChange = { [weak self] in self?.persist() }
            row.onDelete = { [weak self, weak row] in
                guard let self, let row, let i = self.rows.firstIndex(of: row) else { return }
                self.scheduler.rules.remove(at: i)
                self.scheduler.saveRules(self.scheduler.rules)
                self.rebuild()
            }
            return row
        }
        rows.forEach { rulesStack.addArrangedSubview($0) }

        updateConflictMarks()

        if rows.isEmpty {
            let empty = NSTextField(labelWithString: "No rules yet — click “Add Rule”.")
            empty.textColor = .tertiaryLabelColor
            rulesStack.addArrangedSubview(empty)
        }
    }

    @objc private func removeDuplicates() {
        var seen = Set<String>()
        let unique = scheduler.rules.filter { seen.insert($0.signature).inserted }
        scheduler.saveRules(unique)
        rebuild()
    }

    @objc private func mergeOverlaps() {
        scheduler.saveRules(mergeOverlappingRules(scheduler.rules))
        rebuild()
    }

    private func persist() {
        scheduler.saveRules(rows.map { $0.rule })
        updateConflictMarks() // refresh ⚠︎ live, without rebuilding (keeps edit focus)
    }

    /// Recomputes the overlap/duplicate warning on each row from current values.
    private func updateConflictMarks() {
        let current = rows.map { $0.rule }
        for (i, row) in rows.enumerated() {
            let rule = current[i]
            let conflict = rule.enabled && current.indices.contains { j in
                j != i && current[j].enabled && rule.overlaps(current[j])
            }
            row.markConflict(conflict)
        }
    }

    @objc private func addRule() {
        scheduler.rules.append(ScheduleRule())
        scheduler.saveRules(scheduler.rules)
        rebuild()
    }

    func show() {
        rebuild()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
