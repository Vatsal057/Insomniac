# Insomniac

A lightweight macOS menu bar utility that keeps your Mac awake — even with the lid closed.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## What it does

Insomniac disables system sleep using `pmset`, so your Mac stays awake for downloads, builds, media playback, or any task that shouldn't be interrupted. When sleep prevention is enabled and you close the lid, the screen dims after 5 seconds while the system keeps running.

You choose how long to keep it on — indefinitely, for 30 minutes, or for a few hours.

## Features

### Core
- **One-click toggle** — left-click the menu bar icon to enable/disable
- **Timed duration** — pick 30 minutes, 1, 3, or 8 hours; auto-reverts when the timer expires
- **Menu-bar timer** — monospaced remaining time next to the icon, updates every 30s
- **Global keyboard shortcut** — `⌘⌥I` by default, customizable in Settings
- **Lid-close support** — screen dims automatically, system stays awake
- **Launch at login** — start automatically on login
- **No dock icon** — lives entirely in the menu bar
- **Automatic cleanup** — sleep settings are restored on quit

### Modes
- **While charging only** — automatically disable sleep prevention on battery
- **Caffeinate mode** — use `caffeinate` instead of `pmset` (no `sudo` required)

### Safety
- **Thermal guard** — auto-pause sleep prevention when the Mac runs hot (trip at serious or critical heat); important for lid-closed sessions under load
- **Low-battery cutoff** — on battery, disable at a chosen percent (5–50%) so a session can't drain the battery flat
- **Crash watchdog** — a detached process restores normal sleep if Insomniac is force-quit or crashes, so the Mac can't get stuck awake (pmset mode)
- **Automatic update check** — checks GitHub Releases on launch and from the menu; points you at the download, no background installer

### Cursor tools
- **Mouse jiggler** — subtly moves the cursor while a sleep-prevention session is active, keeping presence/status apps green
- **Auto clicker** — periodically clicks a chosen screen location (left/right/middle/double), with smooth human-like motion and optional cursor return
- Both run **only while sleep prevention is on** — they start and stop with your session, and can be limited to when the system is idle

### Triggers
- **Watched apps** — auto-enable when a specific app launches, auto-disable when it quits
- **Schedule** — pick days of the week and a time window; auto-enable and auto-disable on the schedule
- **Activity-based** — keep the Mac awake when CPU usage exceeds a threshold or the system has been active recently, and let it sleep when idle
- **Specific networks** — auto-enable only when connected to a user-configured SSID
- **Download watcher** — keep awake while in-progress downloads (`.crdownload`, `.part`, …) exist in a watched folder

### Power events
- **Dim on battery only** — skip dimming the screen on lid close when connected to AC
- **Skip dim on external display** — don't dim the built-in display if an external monitor is attached

### System
- **URL scheme** — control Insomniac from any scripting context: `insomniac://toggle`, `enable`, `disable`, `status` (with optional `?duration=N`)
- **Export / import settings** — back up and restore your entire config as a `.plist`

## Requirements

- macOS 14.0 (Sonoma) or later
- One-time `sudo` configuration (the app will prompt you on first use; not needed in caffeinate mode)
- Accessibility permission — only if you use the cursor jiggler/clicker

## Installation

### Download (recommended)

1. Grab `Insomniac.dmg` from the [latest release](https://github.com/Vatsal057/Insomniac/releases/latest)
2. Open the DMG and drag **Insomniac** into **Applications**
3. Launch Insomniac — a short welcome guide walks you through setup

> **Note:** The app is ad-hoc signed (not notarized). If macOS blocks the first
> launch, right-click the app → **Open**, or run:
> `xattr -cr /Applications/Insomniac.app`

### Build from source

```bash
git clone https://github.com/Vatsal057/Insomniac.git
cd Insomniac
chmod +x build.sh
./build.sh          # builds Insomniac.app
open Insomniac.app
```

### Package a DMG yourself

```bash
./build.sh dmg      # builds Insomniac.app and Insomniac.dmg
```

## Usage

| Action | Result |
|--------|--------|
| **Left-click** the icon | Toggle sleep prevention (uses your default duration) |
| **Right-click** (or Ctrl+click) | Open the context menu |
| **`⌘⌥I`** | Toggle from anywhere |
| **Right-click → Enable →** | Pick a specific duration (30m, 1h, 3h, 8h, or indefinite) |

When a duration is active, the menu bar tooltip shows the remaining time and a notification fires when the timer expires.

## Menu bar

| Icon | State |
|------|-------|
| ⚡ (bolt) | Sleep prevention is **ON** |
| 🌙 (moon) | Sleep prevention is **OFF** |

Hover the icon to see the current state and remaining time.

## Context menu

### When sleep prevention is OFF

```
Sleep Prevention: OFF
─────────────────
Enable Sleep Prevention  ▸  30 minutes
                            1 hour
                            3 hours
                            8 hours
                          ───
                            Indefinitely
─────────────────
Settings…
─────────────────
About Insomniac v1.0 (5)
─────────────────
Quit Insomniac
```

### When sleep prevention is ON

```
Sleep Prevention: ON · 2h 35m left
─────────────────
Disable Sleep Prevention    ⌘T
─────────────────
Settings…
─────────────────
About Insomniac v1.0 (5)
─────────────────
Quit Insomniac
```

## Settings

Accessible from the context menu or with `⌘,`.

| Tab | Setting | What it does |
|-----|---------|-------------|
| **General** | Launch at login | Register Insomniac as a login item |
| **General** | Start session on launch | Begin a sleep-prevention session as soon as the app starts |
| **General** | Quick-start toggle style | Choose whether left-click toggles or opens the menu |
| **General** | Only while on AC power | Auto-disable on battery |
| **General** | Use caffeinate mode | Use `caffeinate` instead of `pmset` (skips the `sudo` prompt) |
| **General** | Safety | Thermal guard (serious/critical) + low-battery cutoff percent |
| **General** | Updates | Check for updates now / check automatically on launch |
| **General** | Lid & Display | Dim only on battery / skip dim when an external display is connected |
| **General** | Welcome Guide / Export / Import | Re-open onboarding, back up or restore settings as a `.plist` |
| **Session Defaults** | Default duration | 30m / 1h / 3h / 8h / Indefinite |
| **Session Defaults** | Keyboard shortcut | Record a custom global hotkey |
| **Cursor** | Jiggler & clicker | Cursor motion, click target, interval, idle gating, speed |
| **Triggers** | Schedule | Days of week + time window; auto-enable/disable |
| **Triggers** | Activity detection | Keep awake while CPU > threshold or system is in use |
| **Triggers** | Download watcher | Keep awake while downloads are in progress in a folder |
| **Triggers** | Watched apps | Auto-enable when a specific app launches |
| **Triggers** | Wi-Fi networks | Only auto-enable on the configured SSIDs |

## URL scheme

Insomniac registers the `insomniac://` URL scheme. Use it from Terminal, AppleScript, or any other app:

```bash
open "insomniac://toggle"           # toggle on/off
open "insomniac://enable"           # enable indefinitely
open "insomniac://enable?duration=3600"  # enable for 1 hour
open "insomniac://disable"          # disable
open "insomniac://status"           # print current state
```

AppleScript example:

```applescript
tell application "System Events"
    set statusURL to "insomniac://status"
end tell
open location statusURL
```

## How it works

| Component | Mechanism |
|-----------|-----------|
| Sleep prevention | `sudo pmset -a disablesleep 1` (or `caffeinate -di` in caffeinate mode) |
| Status check | `IORegistryEntryCreateCFProperty` on `IOPMrootDomain` |
| Lid detection | `IOServiceAddInterestNotification` on `IOPMrootDomain` |
| Screen dimming | Private `DisplayServices` framework |
| Power source | `IOPSCopyPowerSourcesInfo` + `IOPSNotificationCreateRunLoopSource` |
| App watching | `NSWorkspace.didLaunchApplicationNotification` |
| Network / SSID | `networksetup -getairportnetwork` polled via `NWPathMonitor` |
| CPU usage | `host_processor_info` (`PROCESSOR_CPU_LOAD_INFO`) |
| User idle | `CGEventSource.secondsSinceLastEventType` |
| Permissions | One-time `sudoers.d` entry via AppleScript (skipped in caffeinate mode) |
| Duration timer | In-process `Task` with cancellable sleep |

All `pmset` calls run asynchronously on background threads. The UI stays responsive and the main thread is never blocked.

## Privacy

Insomniac requires `sudo` access to run `pmset`. It creates a single `sudoers` entry:

```
<username> ALL=(ALL) NOPASSWD: /usr/bin/pmset
```

This grants password-less `sudo` access **only** to `pmset` — nothing else. The entry is stored in `/etc/sudoers.d/insomniac` and can be removed at any time:

```bash
sudo rm /etc/sudoers.d/insomniac
```

No data is collected, transmitted, or stored outside of standard macOS `UserDefaults`.

## License

MIT
