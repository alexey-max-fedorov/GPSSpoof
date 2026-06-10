# GPS Location Simulation Tool

Simulate custom GPS coordinates on an iPhone using Xcode's built-in GPX location simulation. macOS only. Works with a free Apple ID. No jailbreak required.

## How it works

Xcode's debug Run action allows overriding the device's reported location with coordinates from a GPX file. This project includes a minimal iOS app that serves as a launchable target. The associated scheme enables location simulation and references a GPX file that is updated as needed.

While the active debug session is running, the simulated coordinates are provided system-wide to apps like Maps and others. You can disconnect the USB cable without ending the session, but the simulation is tied to the debug connection and will end under certain conditions (see below).

## Persistence

The simulation lasts exactly as long as the Xcode debug Run session. Everything below is about keeping that session alive.

### What the app does to help

The GPSSpoof app declares the `location` background mode and holds a continuous location session (`allowsBackgroundLocationUpdates`, no auto-pausing). This keeps the debuggee process running when the screen locks or the app is backgrounded — previously the most common session killer, since iOS suspends a foreground-only app within seconds of locking and the Run session ends with it. It also disables auto-lock while the app is frontmost.

This requires tapping **Allow While Using App** on the first run. It uses only plain Info.plist keys, so it remains fully compatible with free Apple ID signing — no special entitlements, no jailbreak, no private APIs.

The blue location-services indicator on the iPhone acts as a heartbeat: while it is visible, the keepalive (and therefore the session) is alive.

### What ends the session anyway

The debug connection itself has hard limits that no app or scheme setting can remove:

| Event | Session survives? |
| ----- | ----------------- |
| Screen locks / phone sleeps | **Yes** (background location keepalive) |
| USB cable unplugged after launch | Yes (session continues over WiFi) |
| WiFi network switched mid-session (incl. joining/leaving a hotspot) | No — the wireless debug tunnel tears down |
| Mac sleeps or Xcode quits | No |
| iOS terminates the app (force-quit, severe memory pressure) | No |
| iPhone reboots | No (always restores the real location) |

### Stability checklist, in order of impact

1. **Stay wired if you can.** A USB-connected session is immune to WiFi changes.
2. **If you unplug:** put the iPhone on a charger (prevents WiFi power-napping while locked), keep Mac and iPhone on the same network, and do not switch networks mid-session.
3. **Hotspot workflow:** connect the Mac to the iPhone's personal hotspot *before* pressing Cmd-R, then stay on it. That gives the debug tunnel a single direct link that works away from home WiFi — but switching off the hotspot later still drops the session.
4. **Keep the Mac awake:** `caffeinate -dis` in a terminal, or lid open and on power.
5. **Don't force-quit the GPSSpoof app** on the phone, and don't press Stop in Xcode.

Rebooting the iPhone will always restore the real location. There is no persistent daemon or profile installed.

Note for free Apple ID users: the provisioning profile expires after 7 days, after which the app won't launch until you run again from Xcode. This does not affect an already-running session.

## Prerequisites

| Requirement                              | Check                       |
| ---------------------------------------- | --------------------------- |
| macOS with full Xcode (not just CLI tools) | `xcode-select -p` ends in `Xcode.app/...` |
| `xcodegen` (recommended)                 | `brew install xcodegen`     |
| iPhone with iOS 15+, USB cable, trusted  | "Trust This Computer" tapped |
| Free Apple ID added to Xcode             | Xcode > Settings > Accounts |
| Location Services on iPhone              | Settings > Privacy > Location Services > On |

## First-time setup

```bash
./spoof.sh setup
```

Then open `GPSSpoof/GPSSpoof.xcodeproj` in Xcode once. Select your team under Signing & Capabilities to complete the device signing process. Copy the 10-character Team ID and run:

```bash
export TEAM_ID=XXXXXXXXXX
```

(Add this to your shell profile. Re-runs of `./spoof.sh setup` regenerate the Xcode project, and the signing team is only preserved when TEAM_ID is set.)

## Usage

```bash
./spoof.sh --lat 37.3861 --lon -122.0839 --name "Mountain View"
```

The script updates the GPX file and opens the project in Xcode. **In Xcode, select your iPhone as the run destination and press Cmd-R.** (Keep the scheme dropdown on `GPSSpoof` — `GPSSpoofHelper` is the Mac-side helper tool, not the app.) On the first run, tap **Allow While Using App** when the app requests location access — this arms the background keepalive that lets the session survive screen lock. Once the status bar shows the app is running on the device and the app displays the spoofed coordinates, you may unplug the USB cable. Do not stop the session in Xcode.

The simulation applies system-wide during the active debug session. See [Persistence](#persistence) for how to keep the session alive.

## Changing the location from the phone

Once the debug session is running, you can move the spoofed location from the
iPhone itself — no Mac interaction needed beyond initial setup.

Start the session with the helper:

```bash
./spoof.sh --lat 37.3861 --lon -122.0839 --listen
```

`--listen` opens Xcode as usual, then builds and runs `GPSSpoofHelper` — a
small Swift command-line tool that lives in the same Xcode project — in the
foreground. The helper prints a URL like `http://192.168.1.20:8755` — enter
it once in the GPSSpoof app on the phone (after the first save the field
tucks away behind the **helper address** button at the bottom of the
screen). Pan the embedded
map and tap **Set location to map center**, or type exact coordinates and tap
**Apply typed coordinates**: the helper writes them into one of two
alternating GPX slots (`live_a.gpx` / `live_b.gpx`) and clicks
**Debug ▸ Simulate Location** in Xcode for you, so the running session
re-reads the file. Two slots are used because Xcode caches a re-selected GPX
file.

One-time Mac setup: grant **Accessibility** permission to the terminal app
running the helper (System Settings ▸ Privacy & Security ▸ Accessibility).
The helper returns a clear error to the phone if the permission is missing.

Notes:
- Each Apply briefly brings Xcode to the front and opens its Debug menu on
  the Mac (the Simulate Location submenu only exists while the menu chain is
  open, so the helper clicks through it step by step).
- The first Apply triggers iOS's one-time **Local Network** permission prompt
  on the phone — allow it.
- Stopping the helper (Ctrl-C) does not end the spoof session; it only stops
  phone control. Run `./spoof.sh helper` to get it back.
- If the helper reports a missing menu item, run
  `./spoof.sh helper --probe-menu` to see the names Xcode actually shows,
  and check that a debug session is running.

## Restoring the real location

Reboot your iPhone to restore normal location reporting.

## Troubleshooting

- **"no iPhone detected"** — Connect via USB, trust the computer on the iPhone, unlock the device, and retry. Check with `xcrun xctrace list devices`.
- **Signing error** — Open the project in Xcode and set the team manually.
- **Location does not update** — Verify the scheme is set to `GPSSpoof`, iPhone is selected, and "Allow Location Simulation" is enabled with `target.gpx` in the scheme editor.
- **Spoof dies when the phone locks** — The location permission was probably denied or never requested. Tap the gold permission button in the app (it requests access, or deep-links to Settings if access was denied), then run again. The app shows its keepalive status on screen.
- **Simulation ends unexpectedly** — Usually a network event: the Mac or iPhone changed WiFi networks, or the Mac slept. See [Persistence](#persistence) for the stability checklist.
- **App won't launch after a week (free Apple ID)** — The 7-day provisioning profile expired. Press Cmd-R in Xcode to re-install.

## Tests

```bash
bash tests/test_gpx.sh           # GPX shell functions (sourced from spoof.sh)
bash tests/test_helper.sh        # Swift helper, black-box over loopback HTTP
bash tests/test_integration.sh   # end-to-end smoke checks
```

These tests run without a physical device. `test_helper.sh` builds the
`GPSSpoofHelper` target on first run; `test_integration.sh` delegates to it.

## Project layout

```
spoof.sh                                 # Single entry point: setup | spoof | helper
tests/                                   # Test scripts
GPSSpoof/project.yml                     # xcodegen configuration (both targets)
GPSSpoof/GPSSpoof.xcodeproj/             # Generated project
GPSSpoof/Helper/                         # GPSSpoofHelper: Mac-side phone-control
                                         #   helper (Swift command-line tool)
GPSSpoof/GPSSpoof/AppDelegate.swift      # Minimal iOS app
GPSSpoof/GPSSpoof/ControlViewController.swift  # Phone-side control UI
GPSSpoof/GPSSpoof/Info.plist
GPSSpoof/GPSSpoof/locations/target.gpx   # GPX file updated per run
GPSSpoof/GPSSpoof/locations/live_a.gpx   # Alternating live slots rewritten by
GPSSpoof/GPSSpoof/locations/live_b.gpx   #   the helper during phone control
```

## Important Notes

This tool is intended for legitimate development purposes such as testing location-aware applications. The simulation is temporary and tied to Xcode debug sessions. iOS updates may affect compatibility; improvements would involve changes to the scheme configuration.
