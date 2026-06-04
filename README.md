# Insomniac

A lightweight macOS menu bar utility that keeps your Mac awake — even with the lid closed.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## What it does

Insomniac disables system sleep using `pmset`, so your Mac stays awake for downloads, builds, media playback, or any task that shouldn't be interrupted. When sleep prevention is enabled and you close the lid, the screen dims after 5 seconds while the system keeps running.

You choose how long to keep it on — indefinitely, for 30 minutes, or for a few hours.

## Features

- **One-click toggle** — left-click the menu bar icon to enable/disable
- **Timed duration** — pick 30 minutes, 1, 3, or 8 hours; auto-reverts when the timer expires
- **Global keyboard shortcut** — `⌘⌥I` by default, customizable in Settings
- **Lid-close support** — screen dims automatically, system stays awake
- **Auto-deactivate** — optionally re-enable sleep when the Mac goes to sleep normally
- **Launch at login** — start automatically on login
- **No dock icon** — lives entirely in the menu bar
- **Automatic cleanup** — sleep settings are restored on quit

## Requirements

- macOS 14.0 (Sonoma) or later
- One-time `sudo` configuration (the app will prompt you on first use)

## Installation

### Build from source

```bash
git clone https://github.com/Vatsal057/Insomniac.git
cd Insomniac
swift build -c release
.build/release/Insomniac
```

### Create app bundle

```bash
chmod +x build.sh
./build.sh
open Insomniac.app
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

| Setting | What it does |
|---------|-------------|
| Launch at login | Register Insomniac as a login item |
| Auto-deactivate when device sleeps | Re-enable sleep when the Mac sleeps normally |
| Default duration | How long sleep prevention stays on when you toggle via the icon or shortcut |
| Toggle shortcut | Record a custom global hotkey |

## How it works

| Component | Mechanism |
|-----------|-----------|
| Sleep prevention | `sudo pmset -a disablesleep 1` |
| Status check | `IORegistryEntryCreateCFProperty` on `IOPMrootDomain` |
| Lid detection | `IOServiceAddInterestNotification` on `IOPMrootDomain` |
| Screen dimming | Private `DisplayServices` framework |
| Permissions | One-time `sudoers.d` entry via AppleScript |
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
