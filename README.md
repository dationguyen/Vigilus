# Vigilus

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift&logoColor=white)](https://swift.org)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-dationguyen-FFDD00?logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/dationguyen)

A tiny macOS menu bar app that keeps your Mac awake — on your terms. Flip sleep
on or off in a click, prevent sleep for a set time, or set a recurring weekly
schedule. No dependencies, no background daemons, just a single Swift binary.

🦉 *Constant vigilance.*

## Why

`caffeinate` and `pmset` already do this from the terminal, but you have to
remember the flags, and `caffeinate` dies when you close the shell. Vigilus puts
both in the menu bar with sane defaults and remembers your state across launches.

## Features

- **Prevent / Allow Sleep** — a one-click power assertion (like `caffeinate`),
  no admin password needed. Optionally keep the display awake too.
- **Prevent Sleep for…** — a timed window (15 min → 4 hours) with a live
  countdown in the menu. Auto-resumes if you quit and relaunch mid-timer.
- **Weekly schedule** — recurring rules ("keep awake Mon–Fri, 9am–6pm").
  Overlapping windows are merged automatically.
- **System sleep settings** — toggle idle sleep permanently per power source
  (AC / Battery) via `pmset`. Remembers and restores your real timer instead of
  leaving it at "Never". Requires admin auth (native macOS dialog).
- **Launch at Login** — register via `SMAppService`, no helper bundle.
- Menu bar icon reflects state at a glance: 🔥 awake / 🌙 sleep allowed.

## Install

### Download (recommended)

Grab the latest `Vigilus-*.zip` from the
[**Releases**](https://github.com/dationguyen/Vigilus/releases/latest) page. It's
a universal build that runs natively on both Apple Silicon and Intel Macs
(macOS 13+).

1. Unzip it — you'll get `Vigilus.app`.
2. Drag `Vigilus.app` into your `/Applications` folder.
3. Launch it. Because the app is ad-hoc signed (not notarized), the first launch
   may be blocked by Gatekeeper — **right-click → Open**, then confirm, or allow
   it under **System Settings → Privacy & Security**.

Vigilus runs as a menu bar accessory (`LSUIElement`) — no Dock icon.

### Build from source

Requires **macOS 13+** and the **Swift toolchain** (Xcode or Command Line Tools —
verify with `swift --version`).

```bash
git clone git@github.com:dationguyen/Vigilus.git
cd Vigilus
./build.sh
```

This compiles `Sources/*.swift` into a universal binary, assembles
`build/Vigilus.app`, and ad-hoc code-signs it.

```bash
open build/Vigilus.app          # run it
cp -r build/Vigilus.app /Applications/   # install it
```

## Usage

Click the menu bar icon:

| Action | What it does | Admin? |
|--------|--------------|--------|
| **Prevent / Allow Sleep** | Toggle a power assertion now | No |
| **Prevent Sleep for ▸** | Keep awake for a fixed duration | No |
| **Also Keep Display Awake** | Hold the display on as well as the system | No |
| **Edit Schedule…** | Manage recurring weekly keep-awake rules | No |
| **Sleep on AC / Battery** | Permanently enable/disable idle sleep per source | Yes |
| **Launch at Login** | Start Vigilus automatically | No |

The temporary and permanent controls are independent: power assertions stop when
the app quits, while `pmset` changes persist system-wide until you flip them back.

## How it works

- **Temporary** sleep prevention uses IOKit power assertions
  (`kIOPMAssertionTypePreventUserIdleSystemSleep` /
  `kIOPMAssertionTypeNoDisplaySleep`) — no privileges required.
- **Permanent** changes shell out to `/usr/bin/pmset` via the native admin
  authorization dialog, and read configured timers back from `pmset -g custom`.
- Preferences (display-awake choice, schedule rules, saved sleep timers, current
  manual state) persist in `UserDefaults`.

## Project layout

```
Sources/main.swift        Menu bar app, power assertions, pmset, login item
Sources/Scheduler.swift   Recurring weekly schedule engine + editor window
build.sh                  Compiles, bundles, and signs Vigilus.app
```

## Support

If Vigilus saves you a few trips to the terminal, you can
[buy me a coffee](https://buymeacoffee.com/dationguyen) ☕

## License

[MIT](LICENSE) © 2026 Thanh Dat Nguyen
