# Apply-Mode Toggle (v1 menu clicks / v2 self-healing) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A control in the iPhone app that switches how location applies are executed: **v1** — the original blind Debug ▸ Simulate Location menu click, or **v2** — the current session-checked, self-healing flow (default).

**Architecture:** The mode travels with every request as a new optional `mode` field in `POST /location` (`"v1"` or `"v2"`; missing → `"v2"` so older app builds keep working; unknown values → 400). The Mac helper (`GPSSpoofHelper`) branches per request: v1 runs the original click-only AppleScript with no session check and no auto-relaunch; v2 runs the existing merged check+click script and relaunches dead sessions. The iOS app adds a persisted `UISegmentedControl` and includes the mode in the POST body.

**Tech Stack:** Swift (macOS command-line helper + UIKit iOS app), AppleScript via `osascript`, bash black-box tests over loopback HTTP.

---

## Context for an engineer new to this repo

- **Repo root:** `/Users/alexey/Projects/gps-spoof`, branch `phone-location-control`.
- **What the product does:** an Xcode debug Run session simulates GPS on an iPhone. The `GPSSpoofHelper` Mac tool listens for HTTP POSTs from the phone app and re-points the running simulation, either by clicking Xcode's Debug ▸ Simulate Location menu (slot files `live_a.gpx`/`live_b.gpx` alternate because Xcode caches a re-selected GPX) or — when the session is dead — by writing `target.gpx` and telling Xcode to run again.
- **Hard rules:**
  - Do NOT touch `GPSSpoof/GPSSpoof.xcodeproj/xcshareddata/xcschemes/GPSSpoof.xcscheme` or `GPSSpoof/project.yml` (this plan needs neither; sources are directory-globbed, no project regeneration required).
  - Never run `xcodegen` directly, never run the helper without `--dry-run` outside the test scripts, never run `osascript` or `--probe-menu` (they drive the user's real Xcode UI).
  - `tests/test_integration.sh` mutates `GPSSpoof/GPSSpoof/locations/*.gpx` by design. Before every commit run `git checkout -- GPSSpoof/GPSSpoof/locations/`.
  - Your editor's SourceKit will show "Cannot find 'GPX' in scope" / "No such module 'UIKit'" on these files. That is known single-file-analysis noise; only `xcodebuild` results count.
- **Existing helper API contract** (pinned by `tests/test_helper.sh`): `POST /location {"lat","lon"}` → `200 {"ok":true,"slot":"live_a"}` (slots alternate, advance only on success) or `200 {"ok":true,"relaunched":true}` when v2 restarted a dead session; `400` invalid input; `GET /health` → `200 {"ok":true,"slot":…}`.
- **Key existing symbols** (read these files first):
  - `GPSSpoof/Helper/XcodeTrigger.swift` — `applyScript(slot:)` (v2 merged check+click script), `MenuApplyResult` enum, `applySimulateLocation(slot:) -> MenuApplyResult`, `relaunchDebugSession()`, `runOsascript(_:)`, private `permissionDenied(_:)` and `permissionMessage`.
  - `GPSSpoof/Helper/Applier.swift` — `final class Applier`, `apply(lat:lon:)`, private `relaunch(lat:lon:)`, `slot` state, `dryRun` flag.
  - `GPSSpoof/Helper/main.swift` — CLI parsing and the HTTP route closure that calls `applier.apply`.
  - `GPSSpoof/GPSSpoof/ControlViewController.swift` — phone UI; `apply(lat:lon:)` builds the POST.
  - `GPSSpoof/GPSSpoof/Theme.swift` — palette: `Theme.gold`, `Theme.fieldSurface`, `Theme.textSecondary`, etc.

## File structure (all modifications, no new source files)

| File | Responsibility in this plan |
| ---- | --------------------------- |
| `GPSSpoof/Helper/XcodeTrigger.swift` | Re-add the original v1 click-only script + `clickSimulateLocation(slot:)` |
| `GPSSpoof/Helper/Applier.swift` | `ApplyMode` enum; `apply(lat:lon:mode:)` branches v1/v2 |
| `GPSSpoof/Helper/main.swift` | Parse/validate the `mode` JSON field |
| `tests/test_helper.sh` | New black-box tests 12–14 for the `mode` field |
| `GPSSpoof/GPSSpoof/ControlViewController.swift` | Segmented control, persistence, `mode` in POST body |
| `README.md` | Document the switch-method control and the `mode` field |

---

### Task 1: Helper — `mode` field, v1 click path

**Files:**
- Test: `tests/test_helper.sh` (append after test 11, before the final `exit "$FAILED"`)
- Modify: `GPSSpoof/Helper/XcodeTrigger.swift`
- Modify: `GPSSpoof/Helper/Applier.swift`
- Modify: `GPSSpoof/Helper/main.swift`

- [ ] **Step 1: Write the failing tests**

In `tests/test_helper.sh`, insert immediately before the final line `exit "$FAILED"`:

```bash
# 12. mode=v1 accepted; slot still alternates (applies so far: a,b,a,b,a -> next b).
req POST /location '{"lat": 1, "lon": 2, "mode": "v1"}'
if [[ "$STATUS" == 200 ]] && has '"slot":"live_b"'; then ok "mode v1 accepted"
else fail "mode v1 -> $STATUS $(cat "$BODY" 2>/dev/null)"; fi

# 13. mode=v2 accepted explicitly (same behavior as omitting it).
req POST /location '{"lat": 1, "lon": 2, "mode": "v2"}'
if [[ "$STATUS" == 200 ]] && has '"slot":"live_a"'; then ok "mode v2 accepted"
else fail "mode v2 -> $STATUS $(cat "$BODY" 2>/dev/null)"; fi

# 14. Unknown mode -> 400, and the slot pointer does not advance.
req POST /location '{"lat": 1, "lon": 2, "mode": "v3"}'
if [[ "$STATUS" == 400 ]] && has '"ok":false'; then ok "400 on unknown mode"
else fail "mode v3 -> $STATUS"; fi
req GET /health
if has '"slot":"live_a"'; then ok "slot unchanged after rejected mode"
else fail "/health slot after bad mode: $(cat "$BODY" 2>/dev/null)"; fi
```

- [ ] **Step 2: Run the suite to verify the new tests fail**

Run: `bash tests/test_helper.sh`

Expected: tests 12 and 13 already pass (unknown JSON fields are ignored today), but test 14 fails twice — the unknown mode is accepted and therefore also advances the slot:

```
  FAIL - mode v3 -> 200
  FAIL - /health slot after bad mode: {"ok":true,"slot":"live_b"}
```

and exit status 1 (`echo $?` → `1`). If everything passes, the helper is already validating `mode` — stop and re-read the code.

- [ ] **Step 3: Re-add the v1 click-only script to XcodeTrigger**

In `GPSSpoof/Helper/XcodeTrigger.swift`, after the closing brace of `applyScript(slot:)`, insert:

```swift
    /// v1: the original method — blindly click the slot with no session
    /// check and no auto-relaunch. One menu flash fewer and ~1s faster than
    /// v2, but if the debug session has died, Xcode's stale Simulate
    /// Location menu accepts the click and silently does nothing.
    static func clickScript(slot: String) -> String {
        """
        tell application "System Events"
          tell process "Xcode"
            set frontmost to true
            try
              click menu bar item "Debug" of menu bar 1
              delay 0.4
              click menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
              delay 0.4
              click menu item "\(slot)" of menu 1 of menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
            on error errMsg number errNum
              key code 53
              key code 53
              error errMsg number errNum
            end try
          end tell
        end tell
        """
    }
```

(This is byte-for-byte the script that shipped before the v2 merge — it was verified live on Xcode 26.5.)

Then, after the closing brace of `applySimulateLocation(slot:)`, insert:

```swift
    /// v1 click. Returns nil on success, or (httpStatus, message) mapping
    /// the osascript failure onto the helper's API error contract.
    static func clickSimulateLocation(slot: String) -> (status: Int, message: String)? {
        let result = runOsascript(clickScript(slot: slot))
        if result.status == 0 { return nil }
        let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = error.lowercased()
        if permissionDenied(lowered) {
            return (403, permissionMessage)
        }
        if lowered.contains("menu item") {
            return (409, "Xcode has no 'Simulate Location > \(slot)' menu item. Is the "
                + "debug session running? On the Mac, run "
                + "'./spoof.sh helper --probe-menu' to see what Xcode actually lists.")
        }
        return (502, "osascript failed: \(error)")
    }
```

- [ ] **Step 4: Add `ApplyMode` and the v1 branch to Applier**

In `GPSSpoof/Helper/Applier.swift`, insert above the `Applier` class doc comment:

```swift
/// How an apply re-points the running simulation. Selected per request by
/// the phone app via the "mode" field of POST /location.
enum ApplyMode: String {
    /// Original method: blind menu click. Fast, but silently a no-op when
    /// the debug session has died.
    case v1
    /// Session-checked click that restarts a dead Run session via
    /// target.gpx. The default.
    case v2
}
```

Replace the whole existing `func apply(lat: Double, lon: Double) -> (status: Int, json: [String: Any])` with:

```swift
    func apply(lat: Double, lon: Double, mode: ApplyMode) -> (status: Int, json: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        let next = GPX.nextSlot(after: slot)
        let file = locationsDir.appendingPathComponent("\(next).gpx")
        do {
            try GPX.make(lat: lat, lon: lon, name: next)
                .write(to: file, atomically: true, encoding: .utf8)
        } catch {
            let message = "cannot write \(file.path): \(error.localizedDescription)"
            print("  FAIL - \(message)")
            return (500, ["ok": false, "error": message])
        }
        if !dryRun {
            switch mode {
            case .v1:
                if let failure = XcodeTrigger.clickSimulateLocation(slot: next) {
                    print("  FAIL - \(failure.message)")
                    return (failure.status, ["ok": false, "error": failure.message])
                }
            case .v2:
                switch XcodeTrigger.applySimulateLocation(slot: next) {
                case .clicked:
                    break
                case .sessionDead:
                    return relaunch(lat: lat, lon: lon)
                case .failed(let status, let message):
                    print("  FAIL - \(message)")
                    return (status, ["ok": false, "error": message])
                }
            }
        }
        slot = next
        print("  ok   - applied \(GPX.formatCoord(lat)), \(GPX.formatCoord(lon)) via \(next) (\(mode.rawValue))")
        return (200, ["ok": true, "slot": next])
    }
```

(Everything except the `mode` parameter, the `switch mode` wrapper around the
osascript step, and the `(\(mode.rawValue))` suffix in the log line is
unchanged from the current implementation.)

- [ ] **Step 5: Parse the `mode` field in main.swift**

In `GPSSpoof/Helper/main.swift`, replace:

```swift
            guard GPX.validate(lat: lat, lon: lon) else {
                return (400, ["ok": false, "error": "lat must be -90..90, lon -180..180"])
            }
            return applier.apply(lat: lat, lon: lon)
```

with:

```swift
            guard GPX.validate(lat: lat, lon: lon) else {
                return (400, ["ok": false, "error": "lat must be -90..90, lon -180..180"])
            }
            // Missing mode means v2 so app builds predating the toggle keep
            // working; an unrecognized value is a client bug, reject it.
            guard let mode = ApplyMode(rawValue: (object["mode"] as? String) ?? "v2") else {
                return (400, ["ok": false, "error": "mode must be \"v1\" or \"v2\""])
            }
            return applier.apply(lat: lat, lon: lon, mode: mode)
```

- [ ] **Step 6: Run the suite to verify all tests pass**

Run: `bash tests/test_helper.sh`

Expected: the script rebuilds the helper itself (first line `ok   - helper builds`), then every line starts with `ok`, including:

```
  ok   - mode v1 accepted
  ok   - mode v2 accepted
  ok   - 400 on unknown mode
  ok   - slot unchanged after rejected mode
```

`echo $?` → `0`. If the build fails, read the xcodebuild error by re-running without `-quiet`: `xcodebuild -project GPSSpoof/GPSSpoof.xcodeproj -target GPSSpoofHelper -configuration Release SYMROOT="$PWD/build" OBJROOT="$PWD/build/obj" build` (ignore the harmless `_locationScenarioReference` stderr line).

- [ ] **Step 7: Commit**

```bash
git checkout -- GPSSpoof/GPSSpoof/locations/
git add tests/test_helper.sh GPSSpoof/Helper/XcodeTrigger.swift GPSSpoof/Helper/Applier.swift GPSSpoof/Helper/main.swift
git commit -m "feat(helper): per-request apply mode — v1 blind click or v2 self-healing

POST /location accepts an optional \"mode\" field: \"v1\" runs the original
click-only AppleScript (no session check, no auto-relaunch), \"v2\" (the
default, also used when the field is missing) keeps the session-checked
self-healing flow. Unknown values return 400 without advancing the slot.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: iPhone app — switch-method control

**Files:**
- Modify: `GPSSpoof/GPSSpoof/ControlViewController.swift`

There are no automated UI tests in this project; the verification step is a simulator build (the device run is the user's manual task).

- [ ] **Step 1: Add the segmented control property and defaults key**

In `GPSSpoof/GPSSpoof/ControlViewController.swift`, below the line
`private let resultLabel = UILabel()`, insert:

```swift
    // Index 0 = v2 (default). v1 is the escape hatch if the session check
    // ever misfires — it never triggers a rebuild.
    private let modeControl = UISegmentedControl(items: ["v2 · self-healing", "v1 · raw clicks"])
```

Below the line `private static let lastLonKey = "GPSSpoofLastLon"`, insert:

```swift
    private static let modeDefaultsKey = "GPSSpoofApplyMode"
```

- [ ] **Step 2: Configure the control in viewDidLoad**

In `viewDidLoad`, immediately after the four `resultLabel` configuration lines (`resultLabel.textColor = Theme.textSecondary` is the last one), insert:

```swift
        modeControl.selectedSegmentIndex =
            UserDefaults.standard.string(forKey: Self.modeDefaultsKey) == "v1" ? 1 : 0
        modeControl.backgroundColor = Theme.fieldSurface
        modeControl.selectedSegmentTintColor = Theme.gold
        modeControl.setTitleTextAttributes([
            .foregroundColor: Theme.textSecondary,
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        ], for: .normal)
        modeControl.setTitleTextAttributes([
            .foregroundColor: UIColor.black,
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .medium),
        ], for: .selected)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
```

- [ ] **Step 3: Add the control to the layout stack**

Still in `viewDidLoad`, replace:

```swift
        let stack = UIStackView(arrangedSubviews: [
            titleLabel, statusLabel, permissionCard,
            mapView, mapCoordLabel, mapApplyButton,
            latLonRow, manualApplyButton, resultLabel,
            urlToggleButton, urlField,
        ])
```

with:

```swift
        let stack = UIStackView(arrangedSubviews: [
            titleLabel, statusLabel, permissionCard,
            mapView, mapCoordLabel, mapApplyButton,
            latLonRow, manualApplyButton, resultLabel,
            modeControl,
            urlToggleButton, urlField,
        ])
```

- [ ] **Step 4: Persist changes and send the mode with every apply**

After the closing brace of `urlToggleTapped()` (just before the
`// MARK: applying locations` comment), insert:

```swift
    // MARK: switch method

    /// "v1" = blind menu clicks (original), "v2" = session check + self-heal.
    private var applyMode: String {
        modeControl.selectedSegmentIndex == 1 ? "v1" : "v2"
    }

    @objc private func modeChanged() {
        UserDefaults.standard.set(applyMode, forKey: Self.modeDefaultsKey)
    }
```

In `apply(lat:lon:)`, replace:

```swift
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["lat": lat, "lon": lon])
```

with:

```swift
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["lat": lat, "lon": lon, "mode": applyMode])
```

- [ ] **Step 5: Build for the simulator to verify it compiles**

Run:

```bash
xcodebuild -project GPSSpoof/GPSSpoof.xcodeproj -target GPSSpoof -sdk iphonesimulator SYMROOT="$PWD/build/sim" OBJROOT="$PWD/build/sim/obj" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build -quiet
```

Expected: exit 0 (one harmless `_locationScenarioReference` stderr line is fine). SourceKit module errors in the editor do not matter.

- [ ] **Step 6: Commit**

```bash
git checkout -- GPSSpoof/GPSSpoof/locations/
git add GPSSpoof/GPSSpoof/ControlViewController.swift
git commit -m "feat(app): switch-method control — v2 self-healing or v1 raw clicks

A persisted segmented control above the helper-address button picks how
applies run; the choice is sent as the \"mode\" field of POST /location.
v2 (default) keeps the session-checked self-healing flow; v1 is the
original blind menu click for when a rebuild must never be triggered.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Documentation + full verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the switch-method control**

In `README.md`, section "Changing the location from the phone", the Notes list currently ends with the bullet about Apply restarting dead sessions ("…wait for that before applying again."). Append one more bullet after it:

```markdown
- The control above the **helper address** button picks the switch method
  and is remembered: **v2 · self-healing** (default) checks the session
  before clicking and restarts it when dead, as described above;
  **v1 · raw clicks** is the original blind menu click — about a second
  faster and never triggers a rebuild, but if the session has died it
  silently does nothing. The choice is sent per request as the `"mode"`
  field of `POST /location` (missing = v2).
```

- [ ] **Step 2: Run all three test suites**

```bash
bash tests/test_gpx.sh; echo "gpx: $?"
bash tests/test_helper.sh; echo "helper: $?"
bash tests/test_integration.sh; echo "integration: $?"
```

Expected: all three echo `0`, no `FAIL` lines in any output.

- [ ] **Step 3: Restore test-mutated GPX files and confirm a clean tree**

```bash
git checkout -- GPSSpoof/GPSSpoof/locations/
git status --short
```

Expected: only `README.md` modified (plus the untracked `docs/` directory).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: switch-method control (v1 raw clicks / v2 self-healing)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Manual verification (user, needs the iPhone — not part of automated execution)

1. Restart the helper (`Ctrl-C`, then `./spoof.sh helper`) and press Cmd-R in Xcode (scheme `GPSSpoof`) to install the updated app.
2. With the session running: apply in **v2** (normal slot line), switch to **v1**, apply again (slot line, one less menu flash on the Mac).
3. Quit the app on the phone, reopen: apply in **v2** → "the Mac session had ended — restarting it…", app relaunches in ~30 s at the chosen spot.
4. Kill the session again, switch to **v1**, apply → expect the honest old-style behavior: a 409 menu error or a silent no-op (no rebuild). Switch back to v2 to recover from the phone.
5. Confirm the selected mode survives an app relaunch.
