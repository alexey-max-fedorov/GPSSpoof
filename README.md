# gps-spoof

Spoof an iPhone's GPS location via Xcode's native GPX simulation. macOS only. Free Apple ID works. No jailbreak.

## How it works

Xcode's debug Run action can replace device GPS with coordinates from a GPX file. We ship a minimal iOS app whose only purpose is to provide a launchable target; the scheme carries `allowLocationSimulation="YES"` and points at a GPX file we rewrite on every run. While the debug session is attached, iOS reports the spoofed coordinates system-wide (Maps, Find My, third-party apps). Disconnecting USB does not end the debug session — iOS keeps the spoof until reboot.

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
./setup.sh
```

Then open `GPSSpoof/GPSSpoof.xcodeproj` in Xcode once. Pick your team under Signing & Capabilities so the device-signing handshake completes. Copy the 10-character Team ID from the dropdown and:

```bash
export TEAM_ID=XXXXXXXXXX
```

(Add to your shell profile if you'll use this often.)

## Usage

```bash
./spoof.sh --lat 37.3861 --lon -122.0839 --name "Mountain View"
```

Wait until the terminal prints that the debug session is attached, **then unplug the USB cable**. Do not press Ctrl-C. Your iPhone now reports the fake coordinates to every app.

## Restoring the real location

Reboot the iPhone. That's the entire reset — there is no daemon, no profile, nothing installed.

## Troubleshooting

- **"no iPhone detected"** — plug in via USB, tap "Trust This Computer" on the phone, unlock it, then re-run. Verify with `xcrun xctrace list devices`.
- **Signing error** — open `GPSSpoof/GPSSpoof.xcodeproj` in Xcode and set the team manually. `spoof.sh` prints the exact steps when this is the failure.
- **`lldb` attach fails or location does not change** — fallback: open the project in Xcode (`open GPSSpoof/GPSSpoof.xcodeproj`) and press Cmd-R once. Then unplug USB. Same end result.
- **iPhone reboots and location is real again** — that's by design.

## Tests

```bash
bash tests/test_gpx.sh
bash tests/test_integration.sh
```

Both run without a device.

## Project layout

```
spoof.sh                                 # CLI entrypoint
setup.sh                                 # one-time prereq check
lib/gpx.sh                               # GPX writer + coord validator
tests/                                   # bash assertion tests
GPSSpoof/project.yml                     # xcodegen source of truth
GPSSpoof/GPSSpoof.xcodeproj/             # generated; committed for fallback
GPSSpoof/GPSSpoof/AppDelegate.swift      # minimal iOS app
GPSSpoof/GPSSpoof/Info.plist
GPSSpoof/GPSSpoof/locations/target.gpx   # rewritten on every spoof.sh run
```

## Caveats

- This tool exists for legitimate purposes (location-dependent app testing, privacy demos). Spoofing GPS to defeat fraud detection, evade legal monitoring, or violate the terms of services is your problem, not the tool's.
- iOS occasionally tightens the debug-location mechanism in major releases; if a future iOS breaks this, the fix lives in `GPSSpoof.xcscheme` and the lldb invocation in `spoof.sh`.
