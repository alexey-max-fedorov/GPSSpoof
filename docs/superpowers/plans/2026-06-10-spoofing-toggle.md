# Spoofing On/Off Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A toggle button in the iPhone app that turns location spoofing on (re-applies the saved target location) and off (clicks Xcode's "Don't Simulate Location" so the device returns to real GPS), with the initial state auto-detected by comparing the device's reported location to the saved target.

**Architecture:** The Mac helper gains a `POST /stop` endpoint that clicks **Don't Simulate Location** in Xcode's Debug ▸ Simulate Location submenu using the existing v2 one-script session-checked click (a dead session is vacuous success — nothing was being spoofed). The app gains a full-width toggle button: tapping ON re-applies the persisted last-applied coords through the existing `apply()` path; tapping OFF posts `/stop`. AppDelegate forwards each CoreLocation fix to the controller, which — until the user first interacts — mirrors reality: toggle gold/on when the device reports within 100 m of the saved target, gray/off otherwise.

**Tech Stack:** Swift (Foundation CLI helper + UIKit app), AppleScript via osascript, bash black-box tests over loopback HTTP.

---

## Repo constraints (read first)

- **NEVER modify** `GPSSpoof/GPSSpoof.xcodeproj/xcshareddata/xcschemes/GPSSpoof.xcscheme`.
- **NEVER run raw `xcodegen generate`** — only `TEAM_ID=ZV4B6559W7 ./spoof.sh setup`, and nothing in this plan requires regeneration (no `project.yml` changes; sources are directory-globbed).
- **NEVER run osascript, `--probe-menu`, or the helper without `--dry-run`** during implementation. All tests run headless via `--dry-run`.
- `tests/test_integration.sh` mutates `GPSSpoof/GPSSpoof/locations/*.gpx` by design — run `git checkout -- GPSSpoof/GPSSpoof/locations/` before every commit.
- SourceKit single-file diagnostics ("Cannot find 'GPX' in scope", "No such module 'UIKit'") are noise; only `xcodebuild` results are authoritative. The `_locationScenarioReference` stderr line from xcodebuild is harmless Xcode 26 noise.
- **THE APOSTROPHE:** the Xcode menu item is `Don’t Simulate Location` with a **typographic apostrophe U+2019**, NOT ASCII `'`. Verified live via `--probe-menu` on Xcode 26.5 (full item list: `Don’t Simulate Location, live_a, live_b, target, <cities>, Add GPS Exchange to Project…`). The Swift source spells it `Don\u{2019}t` so the invisible difference is explicit in code review.

## Existing behavior being built on

- Helper API (pinned by `tests/test_helper.sh`): `POST /location {"lat","lon","mode"?}` → `200 {"ok":true,"slot":"live_X"}` (slots alternate, advance only on success) or `200 {"ok":true,"relaunched":true}`; 400/403/409/502 errors; `GET /health` → `200 {"ok":true,"slot":…}`. After test 14 the slot pointer sits at `live_a`.
- `XcodeTrigger.applyScript(slot:)` is the v2 one-script sequence: open Product menu → read `enabled` of Stop (liveness) → Escape → if dead return `"dead"` → click Debug ▸ Simulate Location ▸ `<slot>` → return `"clicked"`. The stop item lives in the **same submenu**, so the same script works unchanged with the item name passed as `slot`.
- App persists the last successfully applied coords in `UserDefaults` keys `GPSSpoofLastLat` / `GPSSpoofLastLon` (`Self.lastLatKey` / `Self.lastLonKey`) — that *is* the "target loc" the toggle re-applies.
- `AppDelegate.locationManager(_:didUpdateLocations:)` already receives every keepalive fix; it currently only formats a status string.

### File structure

| File | Change |
|------|--------|
| `tests/test_helper.sh` | Append tests 15–16 (`POST /stop` contract) |
| `GPSSpoof/Helper/XcodeTrigger.swift` | `dontSimulateItem` constant, `mapMenuResult` refactor, `stopSimulateLocation()` |
| `GPSSpoof/Helper/Applier.swift` | `stop()` |
| `GPSSpoof/Helper/main.swift` | Route `POST /stop` |
| `GPSSpoof/GPSSpoof/AppDelegate.swift` | Forward fix coordinate to controller |
| `GPSSpoof/GPSSpoof/ControlViewController.swift` | Toggle button, state machine, `/stop` request, `helperEndpoint` refactor |
| `README.md` | Document the toggle + `/stop` |

---

### Task 1: Helper `POST /stop` endpoint

**Files:**
- Test: `tests/test_helper.sh` (append before `exit "$FAILED"`)
- Modify: `GPSSpoof/Helper/XcodeTrigger.swift`
- Modify: `GPSSpoof/Helper/Applier.swift`
- Modify: `GPSSpoof/Helper/main.swift:133` (the `default:` arm of the route switch)

- [ ] **Step 1: Create the feature branch**

```bash
cd /Users/alexey/Projects/gps-spoof
git checkout -b spoofing-toggle master
```

- [ ] **Step 2: Write the failing tests**

In `tests/test_helper.sh`, insert immediately before the final `exit "$FAILED"` line:

```bash
# 15. POST /stop in dry-run -> 200, spoofing reported off. Body is ignored.
req POST /stop '{}'
if [[ "$STATUS" == 200 ]] && has '"ok":true' && has '"spoofing":false'; then
  ok "POST /stop"
else fail "POST /stop -> $STATUS $(cat "$BODY" 2>/dev/null)"; fi

# 16. Stopping does not advance the slot pointer (still live_a after test 14).
req GET /health
if has '"slot":"live_a"'; then ok "slot unchanged after stop"
else fail "/health slot after stop: $(cat "$BODY" 2>/dev/null)"; fi
```

- [ ] **Step 3: Run the suite to verify it fails**

```bash
bash tests/test_helper.sh; echo "exit: $?"
```

Expected: `FAIL - POST /stop -> 404 {"ok":false,"error":"not found"}`, exit 1. Test 16 passes vacuously (slot genuinely unchanged) — the red signal is test 15.

- [ ] **Step 4: Implement the stop click in XcodeTrigger**

In `GPSSpoof/Helper/XcodeTrigger.swift`:

**4a.** Extend the doc comment of `applyScript(slot:)` — after the line `/// successful slot click.` add:

```swift
    /// Also reused for stopping: "Don't Simulate Location" sits in the same
    /// submenu, so passing it as the slot stops the simulation.
```

**4b.** Replace the body of `applySimulateLocation(slot:)` and add the constant, shared mapper, and `stopSimulateLocation()`. The existing `applySimulateLocation` (lines 151–171) becomes:

```swift
    /// Check the debug session and click Debug > Simulate Location > <slot>
    /// in Xcode, as a single deterministic UI-scripting sequence.
    static func applySimulateLocation(slot: String) -> MenuApplyResult {
        mapMenuResult(runOsascript(applyScript(slot: slot)), item: slot)
    }

    /// The exact stop item name Xcode shows. The apostrophe is typographic
    /// (U+2019) — an ASCII ' makes the click miss the item.
    static let dontSimulateItem = "Don\u{2019}t Simulate Location"

    /// Stop simulating: same submenu, same session-checked script. A dead
    /// session reports .sessionDead — for stopping that means there was
    /// nothing to stop.
    static func stopSimulateLocation() -> MenuApplyResult {
        mapMenuResult(runOsascript(applyScript(slot: dontSimulateItem)),
                      item: dontSimulateItem)
    }

    private static func mapMenuResult(
        _ result: (status: Int32, stdout: String, stderr: String),
        item: String
    ) -> MenuApplyResult {
        if result.status == 0 {
            let answer = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return answer == "dead" ? .sessionDead : .clicked
        }
        let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = error.lowercased()
        if permissionDenied(lowered) {
            return .failed(status: 403, message: permissionMessage)
        }
        if lowered.contains("menu item") {
            return .failed(status: 409, message:
                "Xcode has no 'Simulate Location > \(item)' menu item. Is the "
                + "debug session running? On the Mac, run "
                + "'./spoof.sh helper --probe-menu' to see what Xcode actually lists.")
        }
        return .failed(status: 502, message: "osascript failed: \(error)")
    }
```

(The 403/409/502 mapping moves verbatim into `mapMenuResult`; `applySimulateLocation`'s observable behavior is unchanged.)

- [ ] **Step 5: Implement `Applier.stop()`**

In `GPSSpoof/Helper/Applier.swift`, add after the `apply(lat:lon:mode:)` method (before `relaunch`):

```swift
    /// Stop simulating: click "Don't Simulate Location" so the device
    /// returns to its real GPS. The debug session stays alive. The slot
    /// pointer is untouched — after stopping, no slot is checked in the
    /// menu, so the next apply's alternation works regardless.
    func stop() -> (status: Int, json: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        if !dryRun {
            switch XcodeTrigger.stopSimulateLocation() {
            case .clicked:
                break
            case .sessionDead:
                // Nothing was being simulated over a dead session anyway.
                print("  ok   - stop requested; session already dead")
                return (200, ["ok": true, "spoofing": false, "sessionDead": true])
            case .failed(let status, let message):
                print("  FAIL - \(message)")
                return (status, ["ok": false, "error": message])
            }
        }
        print("  ok   - spoofing stopped (Don't Simulate Location)")
        return (200, ["ok": true, "spoofing": false])
    }
```

- [ ] **Step 6: Route `POST /stop`**

In `GPSSpoof/Helper/main.swift`, in the route switch inside the `HTTPServer` closure, add a case between the `("POST", "/location")` case and `default:`:

```swift
        case ("POST", "/stop"):
            return applier.stop()
```

- [ ] **Step 7: Build and run the suite to verify green**

```bash
xcodebuild -project GPSSpoof/GPSSpoof.xcodeproj -target GPSSpoofHelper \
  -configuration Release SYMROOT="$PWD/build" OBJROOT="$PWD/build/obj" build -quiet
bash tests/test_helper.sh; echo "exit: $?"
```

Expected: build exit 0; suite prints `ok - POST /stop` and `ok - slot unchanged after stop`, zero FAIL lines, exit 0.

- [ ] **Step 8: Commit**

```bash
git add tests/test_helper.sh GPSSpoof/Helper/XcodeTrigger.swift \
        GPSSpoof/Helper/Applier.swift GPSSpoof/Helper/main.swift
git commit -m "feat(helper): POST /stop clicks Don't Simulate Location"
```

---

### Task 2: App spoofing toggle

**Files:**
- Modify: `GPSSpoof/GPSSpoof/AppDelegate.swift:87-93` (`didUpdateLocations`)
- Modify: `GPSSpoof/GPSSpoof/ControlViewController.swift`

No automated UI tests exist for the app; verification is the simulator build plus the manual checklist in Task 3.

- [ ] **Step 1: Forward each fix to the controller**

In `GPSSpoof/GPSSpoof/AppDelegate.swift`, `locationManager(_:didUpdateLocations:)`, add one line after the `guard`:

```swift
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        controlVC.deviceLocationUpdated(fix.coordinate)
        setStatus(String(
            format: "reporting\n%.5f, %.5f\n\nkeep this app installed and running;\nthe blue location indicator means\nthe session is alive",
            fix.coordinate.latitude, fix.coordinate.longitude
        ))
    }
```

- [ ] **Step 2: Add the toggle button property and state**

In `GPSSpoof/GPSSpoof/ControlViewController.swift`, after the `modeControl` property declaration (line 37), add:

```swift
    private let spoofToggleButton = UIButton(type: .system)
    private var spoofingOn = false
    // Auto-detect drives the toggle only until the user (or an apply) takes
    // over; after that it reflects explicit actions, so a stale GPS fix
    // can't flip it back mid-session.
    private var spoofingStateLocked = false
    /// Simulated fixes land exactly on the target; real GPS practically
    /// never does unless you're physically there.
    private static let targetMatchMeters: CLLocationDistance = 100
```

- [ ] **Step 3: Configure the button and put it in the stack**

In `viewDidLoad`, after the `modeControl.addTarget(...)` line, add:

```swift
        spoofToggleButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        spoofToggleButton.layer.cornerRadius = 10
        spoofToggleButton.layer.borderWidth = 1
        spoofToggleButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        spoofToggleButton.addTarget(self, action: #selector(spoofToggleTapped), for: .touchUpInside)
        renderSpoofToggle()
```

Then change the stack creation so the toggle sits right under the status text:

```swift
        let stack = UIStackView(arrangedSubviews: [
            titleLabel, statusLabel, spoofToggleButton, permissionCard,
            mapView, mapCoordLabel, mapApplyButton,
            latLonRow, manualApplyButton, resultLabel,
            modeControl,
            urlToggleButton, urlField,
        ])
```

- [ ] **Step 4: Extract `helperEndpoint` and use it in `apply()`**

Replace the start of `apply(lat:lon:)` (the `var base` through `UserDefaults...set` lines) so the method begins:

```swift
    private func apply(lat: Double, lon: Double) {
        guard let url = helperEndpoint("/location") else {
            showResult("enter the helper URL the Mac printed, e.g. http://192.168.1.20:8755")
            setURLFieldRevealed(true)
            return
        }

        var request = URLRequest(url: url)
```

(everything from `var request = URLRequest(url: url)` down is unchanged), and add the helper right before `apply`:

```swift
    /// Normalizes the saved/typed base URL and appends an endpoint path.
    /// Persists the base so the field can stay tucked away next launch.
    private func helperEndpoint(_ path: String) -> URL? {
        var base = (urlField.text ?? "").trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path), url.scheme?.hasPrefix("http") == true else {
            return nil
        }
        UserDefaults.standard.set(base, forKey: Self.urlDefaultsKey)
        return url
    }
```

- [ ] **Step 5: Add the toggle section**

Add a new MARK section between `// MARK: switch method` and `// MARK: applying locations`:

```swift
    // MARK: spoofing toggle

    private func renderSpoofToggle() {
        if spoofingOn {
            spoofToggleButton.setTitle("spoofing · on", for: .normal)
            spoofToggleButton.setTitleColor(.black, for: .normal)
            spoofToggleButton.backgroundColor = Theme.gold
            spoofToggleButton.layer.borderColor = Theme.gold.cgColor
        } else {
            spoofToggleButton.setTitle("spoofing · off", for: .normal)
            spoofToggleButton.setTitleColor(Theme.textSecondary, for: .normal)
            spoofToggleButton.backgroundColor = Theme.fieldSurface
            spoofToggleButton.layer.borderColor = Theme.surfaceBorder.cgColor
        }
    }

    private func setSpoofing(on: Bool) {
        spoofingOn = on
        renderSpoofToggle()
    }

    /// The last successfully applied coords — what "spoofing on" re-applies.
    private func storedTarget() -> (lat: Double, lon: Double)? {
        let defaults = UserDefaults.standard
        guard let lat = defaults.object(forKey: Self.lastLatKey) as? Double,
              let lon = defaults.object(forKey: Self.lastLonKey) as? Double else {
            return nil
        }
        return (lat, lon)
    }

    /// Called by AppDelegate with every keepalive fix. Until the user
    /// touches the toggle (or applies a location), the toggle mirrors
    /// reality: on when the device reports the saved target, off otherwise.
    func deviceLocationUpdated(_ coordinate: CLLocationCoordinate2D) {
        DispatchQueue.main.async {
            guard !self.spoofingStateLocked, let target = self.storedTarget() else { return }
            let fix = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let goal = CLLocation(latitude: target.lat, longitude: target.lon)
            self.setSpoofing(on: fix.distance(from: goal) <= Self.targetMatchMeters)
        }
    }

    @objc private func spoofToggleTapped() {
        view.endEditing(true)
        spoofingStateLocked = true
        if spoofingOn {
            stopSpoofing()
        } else if let target = storedTarget() {
            apply(lat: target.lat, lon: target.lon)
        } else {
            showResult("no target location saved yet —\napply a location once first")
        }
    }

    private func stopSpoofing() {
        guard let url = helperEndpoint("/stop") else {
            showResult("enter the helper URL the Mac printed, e.g. http://192.168.1.20:8755")
            setURLFieldRevealed(true)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        setApplying(true)
        showResult("stopping…")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async { self?.setApplying(false) }
            if let error = error {
                self?.showResult("could not reach helper: \(error.localizedDescription)\nIs spoof.sh --listen running on the Mac?")
                return
            }
            guard let data = data,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self?.showResult("helper sent an unreadable reply")
                return
            }
            if body["ok"] as? Bool == true {
                DispatchQueue.main.async { self?.setSpoofing(on: false) }
                if body["sessionDead"] as? Bool == true {
                    self?.showResult("the Mac session wasn't running —\nnothing was being spoofed")
                } else {
                    self?.showResult("spoofing off — the device is back\non its real GPS location")
                }
            } else {
                self?.showResult(body["error"] as? String ?? "helper reported an error")
            }
        }.resume()
    }
```

- [ ] **Step 6: Flip the toggle on after any successful apply, and disable it in flight**

Replace `setApplying` and `locationApplied`:

```swift
    private func setApplying(_ inFlight: Bool) {
        for button in [mapApplyButton, manualApplyButton, spoofToggleButton] {
            button.isEnabled = !inFlight
            button.alpha = inFlight ? 0.5 : 1
        }
    }

    private func locationApplied(lat: Double, lon: Double) {
        DispatchQueue.main.async {
            UserDefaults.standard.set(lat, forKey: Self.lastLatKey)
            UserDefaults.standard.set(lon, forKey: Self.lastLonKey)
            self.spoofingStateLocked = true
            self.setSpoofing(on: true)
            self.latField.text = String(format: "%.5f", lat)
            self.lonField.text = String(format: "%.5f", lon)
            let target = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            self.mapView.setCenter(target, animated: true)
        }
    }
```

- [ ] **Step 7: Build for the simulator**

```bash
xcodebuild -project GPSSpoof/GPSSpoof.xcodeproj -target GPSSpoof -sdk iphonesimulator \
  SYMROOT="$PWD/build/sim" OBJROOT="$PWD/build/sim/obj" \
  ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build -quiet
echo "exit: $?"
```

Expected: exit 0. (SourceKit per-file noise like "No such module 'UIKit'" is irrelevant — only this build result counts.)

- [ ] **Step 8: Commit**

```bash
git add GPSSpoof/GPSSpoof/AppDelegate.swift GPSSpoof/GPSSpoof/ControlViewController.swift
git commit -m "feat(app): spoofing on/off toggle with auto-detected initial state"
```

---

### Task 3: Documentation

**Files:**
- Modify: `README.md` (Notes bullet list in "Changing the location from the phone")

- [ ] **Step 1: Add the toggle bullet**

In `README.md`, in the Notes list, insert after the "switch method" bullet (the one ending `(missing = v2).`):

```markdown
- The **spoofing** toggle under the status text turns the simulation on
  and off without ending the session: **on** (gold) re-applies the last
  applied location, **off** (gray) clicks Xcode's *Don't Simulate
  Location* so the device returns to its real GPS. On launch the app sets
  the toggle by comparing the device's reported location to that saved
  target — within 100 m reads as on. Stopping is `POST /stop` on the
  helper; a dead session counts as already stopped.
```

- [ ] **Step 2: Run all three suites and restore mutated GPX files**

```bash
bash tests/test_gpx.sh; echo "gpx: $?"
bash tests/test_helper.sh; echo "helper: $?"
bash tests/test_integration.sh; echo "integration: $?"
git checkout -- GPSSpoof/GPSSpoof/locations/
git status --short
```

Expected: all three exit 0, zero FAIL lines; status shows only `README.md` modified (plus untracked `docs/`).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: spoofing on/off toggle"
```

---

## Manual verification (USER — needs the iPhone)

1. Restart the helper (`Ctrl-C`, then `./spoof.sh helper`) and press Cmd-R in Xcode (scheme `GPSSpoof`) to install the updated app.
2. Launch with spoofing active → toggle should auto-show **gold/on** once fixes arrive.
3. Tap toggle off → Xcode clicks *Don't Simulate Location*; Maps shows the real location; toggle goes gray; message "spoofing off — the device is back on its real GPS location".
4. Tap toggle on → re-applies the saved target; Maps jumps back; toggle gold.
5. Quit + reopen the app while spoofing is off → toggle should auto-start **gray/off** (real GPS ≠ target).
6. Toggle on with a dead session (v2 mode) → relaunch flow kicks in as before.
7. Tap toggle off with a dead session → "the Mac session wasn't running — nothing was being spoofed", no rebuild.
