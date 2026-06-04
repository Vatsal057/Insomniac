# Insomniac

A macOS menu bar app that keeps your Mac awake, even with the lid closed.

## Features
- Toggle system-wide sleep prevention from the menu bar.
- Lid-close sleep prevention via `pmset disablesleep`.
- Screen dims automatically 5 seconds after closing the lid (when sleep prevention is on).
- Left-click the menu bar icon to toggle, right-click to open the menu.
- Auto-deactivate when the device goes to sleep manually (optional, via context menu).
- Launch at login support.
- No dock icon — lives entirely in the menu bar.
- Password-less operation (after one-time sudo setup).

## One-Time Setup

Grant password-less `sudo` access for `pmset` so the app can toggle sleep without prompting for a password each time:

```bash
echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/pmset" | sudo tee /etc/sudoers.d/insomniac
```

The app will also offer to set this up automatically on first use.

## Build & Run

```bash
# Build
swift build -c release

# Run
.build/release/Insomniac &
```

Or use the build script to create an app bundle:

```bash
chmod +x build.sh
./build.sh
open Insomniac.app
```

## Usage
- **Left-click** the menu bar icon to toggle sleep prevention on/off.
- **Right-click** (or Ctrl+click) the icon to open the context menu.
- Use `⌘⌥I` to toggle via keyboard (customizable in Settings).
- The icon changes to show the current state: ⚡ (bolt) = sleep prevention ON, 🌙 (moon) = normal.

## Settings
Open from the context menu or with `⌘,`. Options:
- **Launch at login** — start Insomniac automatically when you log in.
- **Toggle shortcut** — record a custom global keyboard shortcut.

## How It Works
- Uses `pmset disablesleep` via `sudo` to prevent system sleep.
- Reads sleep state from `IORegistry` (IOPMrootDomain) for fast status checks.
- Monitors lid close events via `IOKit` interest notifications.
- Dims the display using the private `DisplayServices` framework after a 5-second debounce.
- Restores all original display sleep settings on quit or when sleep is re-enabled.
