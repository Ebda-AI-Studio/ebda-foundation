# Force AI Ops (native command center) — runbook

Native SwiftUI macOS command center for the Whisky AI OS. Thin client over the `:7717` Node aggregator — it renders fleet state and issues actions, it holds no state of its own.

## Source
`ops/command-center-app/` (Swift Package Manager, SwiftUI, macOS 13+).

## Build / install
```bash
cd ops/command-center-app
make app      # builds bin/Force AI Ops.app
make dmg      # builds bin/Force AI Ops.dmg
make install  # builds + copies to /Applications, refreshes icon cache (LaunchServices + Dock)
```
Ad-hoc signed, not notarized — first launch may need System Settings → Privacy & Security → Open Anyway, or `xattr -dr com.apple.quarantine "/Applications/Force AI Ops.app"`.

## Backend requirement
The app is read/act-only against the Node aggregator — it does nothing without it. The aggregator (`ops/dashboard/`, launchd `com.ebda.os.dashboard`) must be running on `:7717` before launching the app:
```bash
launchctl list | grep com.ebda.os.dashboard
curl -s http://localhost:7717/api/state | head -c 200
```
If it's not running, `ops/install.sh` (re)installs the launchd job.

## The four enhancements
1. **Native push notifications** — `UNUserNotificationCenter`; fires on a subsystem transition `ok → down`, a new Decision-Inbox item, or a CI break. De-duped per subsystem, gated by per-category Settings toggles.
2. **Launch at login** — `SMAppService.mainApp`, toggled in Settings.
3. **Menu-bar status glyph** — `MenuBarExtra`, tinted by worst subsystem status, running once launched.
4. **Zero built in** — native Start/status controls over `/api/zero/*`, with the live voice HUD (`localhost:9911`) shown in a small contained `WKWebView` island inside the Zero panel.

## Retiring the old browser wrapper
Once the native app is adopted:
```bash
rm -rf ~/Applications/"Ops Command-Center.app"
```
The old Chrome app-mode shortcut is superseded — no functionality is lost, since the native app talks to the same `:7717` aggregator. Optionally retire the web index (`ops/dashboard/public/index.html`) once nothing else depends on it; the aggregator's HTTP API stays as the backend either way.
