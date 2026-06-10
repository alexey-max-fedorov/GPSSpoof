## What this is

macOS-only tool to simulate GPS coordinates on a physical iPhone via Xcode's GPX
location-simulation feature — free Apple ID, no jailbreak. The spoof lasts exactly
as long as the Xcode debug Run session; most of the design exists to keep that
session alive. See `README.md` for the user-facing persistence/stability rules.

## Commands

```bash
TEAM_ID=XXXXXXXXXX ./spoof.sh setup          # prereq check + regenerate Xcode project
./spoof.sh --lat 37.3861 --lon -122.0839 --name "Label"   # stage GPX, open Xcode
./spoof.sh --lat .. --lon .. --listen        # also build + run the phone-control helper
./spoof.sh helper [--port N] [--dry-run] [--probe-menu]   # run helper standalone

bash tests/test_gpx.sh           # GPX shell functions (sourced from spoof.sh)
bash tests/test_helper.sh        # Swift helper, black-box over loopback HTTP
bash tests/test_integration.sh   # end-to-end smoke checks
```

Tests run with **no physical device**. `test_helper.sh` builds `GPSSpoofHelper` on
first run. The helper is built via `xcodebuild -target GPSSpoofHelper` into `build/`.

**`TEAM_ID` must be set** when running `setup`, or xcodegen drops the signing team
from the pbxproj. Find it in Xcode > Settings > Accounts after picking a team.

## Architecture

**One `xcodegen` project, two targets** (`GPSSpoof/project.yml`):
- `GPSSpoof` — minimal iOS app. Its only job is to be a launchable debug target and
  to *keep the session alive*: it holds a continuous background-location session
  (`UIBackgroundModes: location`, plain Info.plist keys only — preserves free-Apple-ID
  signing) so the debuggee process survives screen lock. Also hosts the phone-side
  control UI (`ControlViewController.swift`) and POSTs coordinates to the helper.
- `GPSSpoofHelper` — macOS command-line tool (`GPSSpoof/Helper/`). Signing disabled;
  only ever runs on this Mac.

**The scheme is hand-managed, not generated.** `xcschemes: {}` / `scheme: ~` in
`project.yml` tell xcodegen to leave the scheme alone, because
`GPSSpoof.xcscheme` carries the custom GPX `LocationScenario` wiring (`target.gpx`).
`cmd_setup` stashes and restores the scheme around `xcodegen generate`, since
xcodegen wipes `xcshareddata/` on regenerate. The committed `project.pbxproj` is a
fallback for when xcodegen isn't installed.

**`spoof.sh`** is the single entry point — subcommands `setup` / `helper` / default
(`cmd_spoof`). The default path validates coords, writes `target.gpx`, and opens
Xcode for a manual Cmd-R. GPX writing (`write_gpx`, `validate_coords`, `xml_escape`)
is sourced and unit-tested by `tests/test_gpx.sh`.

**Phone-driven location changes (the helper loop):** once a session runs, the phone
app changes location without touching the Mac. `GPSSpoof/Helper/`:
- `HTTPServer.swift` — listens on LAN (default port 8755). Routes: `GET /health`,
  `POST /location`, `POST /stop`.
- `Applier.swift` — state machine. Writes coords into **alternating GPX slots**
  (`live_a.gpx` / `live_b.gpx`) because Xcode caches a re-selected GPX file; the slot
  only advances on full success. Selects `ApplyMode` per request from the `"mode"`
  field: **v2** (default, self-healing) checks session liveness and restarts a dead
  Run session via `target.gpx`; **v1** is a blind/faster menu click.
- `XcodeTrigger.swift` — drives Xcode's `Debug > Simulate Location` menu via
  `osascript`/Accessibility. The session check + clicks **must be one osascript call**
  (timing), and the submenu must be opened **step by step** (items don't exist in the
  AX tree until the chain is physically open). `Don't Simulate Location` lives in the
  same submenu, so `/stop` reuses the click path.

**macOS permissions the helper needs:** Accessibility (for the terminal running it)
and Automation for Xcode. Missing permissions return a clear error to the phone.

## Gotchas

- Editing the GPX-simulation wiring means editing `GPSSpoof.xcscheme` by hand — don't
  expect xcodegen to manage it.
- Changing helper↔Xcode automation: test against `--probe-menu` (prints the live menu
  item names) since Xcode menu titles can shift between versions.
- `docs/superpowers/plans/` holds the design plans behind each feature — useful
  context for *why* something works the way it does.
