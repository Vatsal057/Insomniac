# Insomniac

A lightweight macOS menu bar utility that prevents your Mac from sleeping — even with the lid closed.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## What it does

Insomniac disables system sleep using `pmset`, so your Mac stays awake for downloads, builds, media playback, or any task that shouldn't be interrupted. When sleep prevention is enabled and you close the lid, the screen dims after 5 seconds while the system keeps running.

## Features

- **One-click toggle** — left-click the menu bar icon to enable/disable
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

## How it works

| Component | Mechanism |
|-----------|-----------|
| Sleep prevention | `sudo pmset -a disablesleep 1` |
| Status check | `IORegistryEntryCreateCFProperty` on `IOPMrootDomain` |
| Lid detection | `IOServiceAddInterestNotification` on `IOPMrootDomain` |
| Screen dimming | Private `DisplayServices` framework |
| Permissions | One-time `sudoers.d` entry via AppleScript |

All `pmset` calls run asynchronously on background threads. The UI stays responsive and the main thread is never blocked.

## Menu bar

| Icon | State |
|------|-------|
| 👁 `eye.fill` | Sleep prevention is **ON** — wide awake |
| 🚫👁 `eye.slash.fill` | Sleep prevention is **OFF** — resting |

- **Left-click** — toggle sleep prevention
- **Right-click** (or Ctrl+click) — open context menu

## Context menu

- Toggle sleep prevention
- Auto-deactivate on sleep (on/off)
- Current keyboard shortcut
- Settings
- About (version info)
- Quit

## Settings

Accessible from the context menu or with `⌘,`.

- **Launch at login** — register as a login item via `SMAppService`
- **Keyboard shortcut** — record a custom global hotkey
- **Version** — current build info

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
