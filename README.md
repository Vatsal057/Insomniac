# Insomniac ☕️

A simple macOS menu bar app that keeps your Mac awake, even with the lid closed.

## Features
- Toggle system-wide sleep prevention with one click.
- "Lid-close" sleep prevention using `pmset disablesleep`.
- No dock icon (lives entirely in the menu bar).
- Password-less operation (after one-time setup).

## One-Time Setup (Important)

To allow the app to toggle the sleep setting without asking for your password every time, you need to grant password-less `sudo` access specifically for the `pmset` command.

Run this command in your terminal:

```bash
echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/pmset" | sudo tee /etc/sudoers.d/insomniac
```

## How to Build and Run

1. **Build the app:**
   ```bash
   swift build -c release
   ```

2. **Run the app:**
   ```bash
   .build/release/Insomniac &
   ```

## Usage
- Click the icon in the menu bar (Sun ☀️ for Awake, Moon 🌙 for Normal).
- Select **Disable Sleep** to keep your Mac awake.
- Select **Enable Sleep** to return to normal behavior.
- Use `Cmd+Shift+T` to toggle via keyboard.
- Use `Cmd+Q` to quit.
