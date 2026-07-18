# Adopt Lidless features into Insomniac — design

Date: 2026-07-18

Goal: polish Insomniac for distribution by adopting the four Lidless features it
lacks: a thermal safety guard, a low-battery cutoff, an in-app update check, and
a crash watchdog. Insomniac already surpasses Lidless on every other axis
(triggers, cursor tools, URL scheme, import/export), so scope is limited to these
four gaps.

Decisions locked during brainstorming:
- Thermal and battery trips are **manual-recovery**: trip once, notify, stay off
  until the user re-enables. No auto re-enable, no hysteresis needed.
- Update repo is `Vatsal057/Insomniac`, releases tagged `vX.Y` (e.g. `v1.0`).
- No Sparkle (needs Developer ID + notarization the project doesn't have) and no
  Lidless-style root LaunchDaemon/XPC helper (the existing `sudoers.d` NOPASSWD
  `pmset` grant already lets any user process restore sleep).

---

## 1. Thermal guard

New file `Sources/Insomniac/ThermalMonitor.swift` (~40 lines).

- Wraps `ProcessInfo.processInfo.thermalState` and observes
  `ProcessInfo.thermalStateDidChangeNotification`.
- Exposes `currentState` and a `start(onHot:)` that fires when the state reaches
  or exceeds the configured threshold.

`SleepManager` additions:
- Settings (UserDefaults): `thermalGuardEnabled` (default `true`),
  `thermalGuardCritical` (`false` → trip at `.serious`, `true` → trip only at
  `.critical`). Default trips at `.serious`.
- `startThermalMonitor()` wired next to the other monitors in `init()`.
- Handler: if guard enabled, sleep is disabled, and state ≥ threshold →
  `clearSession()` + `setSleepDisabled(false)` + notify
  ("Sleep Prevention Disabled — Mac is running hot"). Manual recovery, so no
  re-enable path.

## 2. Low-battery cutoff

Extend `PowerMonitor` and `SleepManager` (no new file).

`PowerMonitor`:
- Add `var batteryPercent: Int?` reading `kIOPSCurrentCapacityKey` /
  `kIOPSMaxCapacityKey` from the same `IOPSCopyPowerSourcesInfo` snapshot already
  used for `isOnACPower`. Returns `nil` on desktops / when unavailable.

`SleepManager`:
- Settings: `batteryCutoffEnabled` (default `false`), `batteryCutoffPercent`
  (default `20`).
- Battery % drifts without firing an AC-state event, so checking only the
  `PowerMonitor` callback isn't enough. Add the cutoff check to the always-on 30s
  tooltip timer in `AppDelegate` (the same tick that beats the watchdog
  heartbeat) plus the `PowerMonitor` callback for instant response on unplug. No
  new timer. (The activity timer is unusable here — it only runs when
  activity-detection is enabled.)
- Handler: if enabled, on battery (`!isOnACPower`), `batteryPercent <= cutoff`,
  and sleep disabled → `clearSession()` + `setSleepDisabled(false)` + notify.
  Independent of the all-or-nothing `requireCharging` setting; this lets a user
  run on battery down to a floor instead of disabling the moment they unplug.

## 3. In-app update check

New file `Sources/Insomniac/UpdateChecker.swift` (~60 lines).

- `checkForUpdates(silent:)` GETs
  `https://api.github.com/repos/Vatsal057/Insomniac/releases/latest`, reads
  `tag_name` (strip leading `v`) and `html_url`.
- Compares against `CFBundleShortVersionString` with a small numeric
  dotted-version compare (`compareVersions("1.10","1.9") > 0`). Pure function,
  unit-testable.
- If newer: non-silent → `NSAlert` with "Download" (opens `html_url`) and
  "Later"; silent → a notification only. If not newer and non-silent → a brief
  "You're up to date" alert. Network failure in silent mode is swallowed.
- Setting `autoCheckUpdatesOnLaunch` (default `true`): `AppDelegate` fires one
  silent check ~5s after launch.
- Menu item "Check for Updates…" added to the status menu (non-silent).

## 4. Crash watchdog (lazy, no daemon)

Reuses the existing passwordless `sudo pmset` grant — a plain unprivileged
process can restore sleep, so no root helper is needed. On macOS a spawned child
is reparented to launchd (not killed) when its parent is SIGKILLed, so a detached
`/bin/sh` loop survives an app crash.

New file `Sources/Insomniac/Watchdog.swift` (~50 lines), a `@MainActor` helper.

- Heartbeat file: `~/Library/Application Support/Insomniac/heartbeat`
  (mtime = liveness).
- `start()` — called from `setSleepDisabled(true)` in **pmset mode only**
  (caffeinate mode holds only a soft assertion, no stuck hard flag, so it is
  skipped). Writes the heartbeat, then spawns one detached `/bin/sh -c` running:

  ```sh
  while sleep 30; do
    hb=$(stat -f %m "$HB" 2>/dev/null) || exit 0        # file gone = graceful stop
    now=$(date +%s)
    if [ $((now - hb)) -gt 90 ]; then
      /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0  # crash recovery
      exit 0
    fi
  done
  ```

  Only one watchdog at a time (guard on an existing `Process?` handle).
- `beat()` — touch the heartbeat mtime; called from the app's existing 30s tooltip
  timer while sleep is disabled.
- `stop()` — called from `setSleepDisabled(false)` and on graceful quit: delete
  the heartbeat file (watchdog exits on its next `stat`) and terminate the child
  handle. Restoring an already-restored flag is idempotent, so a race is harmless.

Stale-heartbeat threshold 90s > beat interval 30s, matching Lidless's watchdog
margin.

---

## Testing

Pure logic gets an assert-based self-check (no framework):
- `compareVersions` — ordering across `1.0`/`1.10`/`1.9`/equal/`v`-prefixed.
- Battery cutoff predicate (`onBattery && percent <= cutoff`).
- Thermal threshold predicate (state ≥ configured level).

Manual verification (documented in the plan):
- Thermal: no reliable synthetic trigger; verify the handler path with a forced
  state value.
- Watchdog: enable sleep in pmset mode, `kill -9` the app, confirm
  `pmset -g | grep disablesleep` returns to `0` within ~2 min; confirm graceful
  disable removes the heartbeat and the `sh` process exits.
- Update check: point at the real repo, confirm up-to-date and
  newer-release-available paths.

## Settings UI

Add to the existing Settings tabs (no new tab):
- General → new "Safety" section: Thermal guard (on/off + serious/critical),
  Low-battery cutoff (on/off + percent stepper).
- General → "Check for Updates…" button + "Check automatically on launch" toggle,
  near the existing About/version row.

## Files touched

- New: `ThermalMonitor.swift`, `UpdateChecker.swift`, `Watchdog.swift`.
- Edit: `PowerMonitor.swift` (battery %), `SleepManager.swift` (wire monitors,
  settings, watchdog calls), `InsomniacApp.swift` (menu item, launch update
  check, heartbeat beat in tooltip timer), `SettingsView.swift` (safety +
  updates UI).

## Explicitly skipped

- Sparkle auto-install / EdDSA appcast — no Developer ID + notarization infra.
- Lidless XPC / root LaunchDaemon helper — `sudoers.d` grant already suffices.
- Auto re-enable / hysteresis on safety trips — manual recovery chosen.
