# Menu-Click Fix, Permission Button & Phone UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the phone-control Apply path (Xcode's Simulate Location submenu is lazily populated, so the helper's one-shot nested AppleScript click fails with 409), add an in-app button to request/repair location permission, and redesign the iPhone control UI in the headliner.studio palette with an embedded Apple Maps view and a "set location to map center" button.

**Architecture:** The Mac-side fix is confined to `GPSSpoof/Helper/XcodeTrigger.swift` — both AppleScripts open the menu chain step by step (click Debug, delay, click Simulate Location, delay, click/enumerate) instead of resolving a nested path in one shot. The phone side gets a new `Theme.swift` (palette + styled-control factories), an `AppDelegate` that routes CLAuthorizationStatus changes into the view controller and exposes a request-permission closure, and a rewritten `ControlViewController` (dark UI, MKMapView with gold crosshair, map-center apply button, manual lat/lon entry, permission card). The helper HTTP API contract is untouched.

**Tech Stack:** Swift (UIKit + MapKit + CoreLocation on iOS; Foundation + osascript on macOS), bash black-box tests, xcodegen project regeneration via `TEAM_ID=ZV4B6559W7 ./spoof.sh setup`.

---

## Verified root cause (do not re-litigate)

Live-debugged on the user's Mac with Xcode 26.5 and a running debug session:

- `live_a.gpx` / `live_b.gpx` are tracked, in the pbxproj, and DO appear in Debug ▸ Simulate Location — but **only after the menu chain is physically opened on screen**. Enumerating the submenu without opening it returns an **empty list** (lazy population).
- Therefore the current one-shot script `click menu item "live_a" of menu 1 of menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1` fails with `Can't get menu item …` → helper maps it to 409.
- The sequential variant (click Debug → delay 0.4 → click Simulate Location → delay 0.4 → click slot) was executed live and returned exit 0; Xcode applied the slot.

## Hard constraints (carry over from the project)

- **NEVER modify** `GPSSpoof/GPSSpoof.xcodeproj/xcshareddata/xcschemes/GPSSpoof.xcscheme`. After any project regen, `git diff` on that file must be empty.
- **Never run raw `xcodegen generate`.** Regenerate only via `TEAM_ID=ZV4B6559W7 ./spoof.sh setup`, then verify `grep -c 'ZV4B6559W7' GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj` ≥ 1.
- **Never run osascript / `--probe-menu` / the helper without `--dry-run`** during your task. The real click path is verified by the controller separately.
- `tests/test_integration.sh` mutates `GPSSpoof/GPSSpoof/locations/target.gpx` by design. Before committing, run `git checkout -- GPSSpoof/GPSSpoof/locations/` and stage only your own files (the working tree may carry unrelated runtime mutations of `live_a.gpx`/`target.gpx` from the user's live session — never commit those).
- Helper API contract (unchanged, do not break): `POST /location {"lat","lon"}` → `200 {"ok":true,"slot":"live_a"}`; 400 invalid; 409 menu item missing; 403 Accessibility missing; 502 other osascript failure; `GET /health` → `200 {"ok":true,"slot":…}`.

## headliner.studio palette (source of truth for Theme.swift)

| Token | Hex |
|---|---|
| background | `#000000` |
| card surface | `#0A0A0A` |
| field surface | `#111111` |
| border | `#1A1A1A` |
| gold accent | `#C9A84C` |
| gold bright (hover) | `#D4B65E` |
| text primary | `#FFFFFF` |
| text secondary | `#A0A0A0` |
| text tertiary | `#666666` |

Typography: serif display for the wordmark (use the system serif design — New York — via `UIFontDescriptor.withDesign(.serif)`; do NOT bundle font files), system/monospaced for everything else. Corner radii 10–12. Dark mode forced on the window (also keeps MKMapView dark).

---

### Task 1: Sequential menu-chain clicks in XcodeTrigger

**Files:**
- Modify: `GPSSpoof/Helper/XcodeTrigger.swift`

- [ ] **Step 1: Replace `clickScript(slot:)` and `probeScript`**

Replace the two script builders in `GPSSpoof/Helper/XcodeTrigger.swift` so the file's script section reads exactly:

```swift
/// UI-scripts Xcode (Debug > Simulate Location > <slot>) via osascript.
/// Requires macOS Accessibility permission for the terminal app running the
/// helper. Each click briefly opens the Debug menu on the Mac's screen.
///
/// The Simulate Location submenu is populated lazily: its items do not exist
/// in the accessibility tree until the menu chain is physically opened, so a
/// one-shot nested click ("click menu item X of menu 1 of menu item Y ...")
/// fails with "Can't get menu item". Open the chain step by step instead.
/// Verified live on Xcode 26.5.
enum XcodeTrigger {
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

    static let probeScript = """
        tell application "System Events"
          tell process "Xcode"
            set frontmost to true
            try
              click menu bar item "Debug" of menu bar 1
              delay 0.4
              click menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
              delay 0.4
              set itemNames to name of every menu item of menu 1 of menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
              key code 53
              key code 53
              return itemNames
            on error errMsg number errNum
              key code 53
              key code 53
              error errMsg number errNum
            end try
          end tell
        end tell
        """
```

Notes:
- `key code 53` is Escape — closes the opened menus when the chain fails partway (on success the final click closes them itself). The `error errMsg number errNum` re-raise preserves the original osascript error text, so the existing 403/409/502 mapping in `clickSimulateLocation(slot:)` keeps working unchanged (a missing slot still produces "Can't get menu item …" → contains "menu item" → 409).
- Do NOT change `runOsascript` or `clickSimulateLocation` — only the two script strings and the doc comment.

- [ ] **Step 2: Rebuild the helper**

Run:
```bash
xcodebuild -project GPSSpoof/GPSSpoof.xcodeproj -target GPSSpoofHelper -configuration Release SYMROOT="$PWD/build" OBJROOT="$PWD/build/obj" build -quiet
```
Expected: exit 0 (an `ivar '_locationScenarioReference'` warning line is harmless Xcode 26 noise).

- [ ] **Step 3: Run the helper black-box suite**

Run: `bash tests/test_helper.sh`
Expected: all 18 checks `ok`, exit 0. (The suite is dry-run only — it cannot exercise the osascript path; the controller live-verifies the real click separately.)

- [ ] **Step 4: Commit**

```bash
git add GPSSpoof/Helper/XcodeTrigger.swift
git commit -m "fix(helper): open the Simulate Location menu chain step by step

Xcode populates the submenu lazily; a one-shot nested AppleScript click
cannot resolve the slot item and 409s. Click Debug, then Simulate
Location, then the slot, with short delays. Verified on Xcode 26.5."
```

---

### Task 2: Simulator build check in the integration suite

**Files:**
- Modify: `tests/test_integration.sh` (append a new check before the final `exit "$FAILED"`)

- [ ] **Step 1: Append check #12**

Insert before the `exit "$FAILED"` line at the end of `tests/test_integration.sh`:

```bash
# 12. The iOS app target compiles standalone (simulator SDK, no signing, no
# scheme involvement). Guards the phone-side UI code.
xcodebuild -project "$ROOT/GPSSpoof/GPSSpoof.xcodeproj" -target GPSSpoof \
  -configuration Debug -sdk iphonesimulator \
  SYMROOT="$ROOT/build/sim" OBJROOT="$ROOT/build/sim/obj" \
  CODE_SIGNING_ALLOWED=NO build -quiet >/dev/null 2>&1 \
  && echo "  ok   - iOS app builds (simulator)" || { echo "  FAIL - iOS app build failed (run the xcodebuild line in check 12 without -quiet to see why)"; FAILED=1; }
```

- [ ] **Step 2: Run the integration suite**

Run: `bash tests/test_integration.sh`
Expected: all checks `ok` including the new `iOS app builds (simulator)`, exit 0.

- [ ] **Step 3: Restore the mutated GPX and commit**

```bash
git checkout -- GPSSpoof/GPSSpoof/locations/
git add tests/test_integration.sh
git commit -m "test: compile the iOS app for the simulator in the integration suite"
```

---

### Task 3: Theme.swift + permission plumbing in AppDelegate

**Files:**
- Create: `GPSSpoof/GPSSpoof/Theme.swift`
- Modify: `GPSSpoof/GPSSpoof/AppDelegate.swift`
- Modify: `GPSSpoof/GPSSpoof/ControlViewController.swift` (two small additions only)
- Regenerate: `GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj` (new file must enter the project graph)

- [ ] **Step 1: Create `GPSSpoof/GPSSpoof/Theme.swift`**

```swift
import UIKit

/// headliner.studio palette: pure black surfaces with a single gold accent.
enum Theme {
    static let background = UIColor(hex: 0x000000)
    static let cardSurface = UIColor(hex: 0x0A0A0A)
    static let fieldSurface = UIColor(hex: 0x111111)
    static let surfaceBorder = UIColor(hex: 0x1A1A1A)
    static let gold = UIColor(hex: 0xC9A84C)
    static let goldBright = UIColor(hex: 0xD4B65E)
    static let textPrimary = UIColor(hex: 0xFFFFFF)
    static let textSecondary = UIColor(hex: 0xA0A0A0)
    static let textTertiary = UIColor(hex: 0x666666)

    /// Serif display font (the system New York face) for the wordmark.
    static func serifFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func goldButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.setTitleColor(.black, for: .normal)
        button.backgroundColor = gold
        button.layer.cornerRadius = 10
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        return button
    }

    static func outlineButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.setTitleColor(gold, for: .normal)
        button.backgroundColor = .clear
        button.layer.cornerRadius = 10
        button.layer.borderWidth = 1
        button.layer.borderColor = gold.withAlphaComponent(0.6).cgColor
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    static func field(placeholder: String, keyboard: UIKeyboardType) -> UITextField {
        let field = UITextField()
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: textTertiary])
        field.textColor = textPrimary
        field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        field.keyboardType = keyboard
        field.backgroundColor = fieldSurface
        field.layer.cornerRadius = 10
        field.layer.borderWidth = 1
        field.layer.borderColor = surfaceBorder.cgColor
        field.heightAnchor.constraint(equalToConstant: 44).isActive = true
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 44))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 44))
        field.rightViewMode = .always
        return field
    }

    static func card() -> UIView {
        let view = UIView()
        view.backgroundColor = cardSurface
        view.layer.cornerRadius = 12
        view.layer.borderWidth = 1
        view.layer.borderColor = surfaceBorder.cgColor
        return view
    }
}

extension UIColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0)
    }
}
```

- [ ] **Step 2: Wire permission plumbing in `AppDelegate.swift`**

Three edits (keep everything else, including the file-top comment, `didUpdateLocations`, `didFailWithError`, `setStatus`):

1. In `application(_:didFinishLaunchingWithOptions:)`, right after `window = UIWindow(frame: UIScreen.main.bounds)`, add:
```swift
        // The control UI is a fixed dark design (headliner palette); forcing
        // dark also keeps MKMapView in its dark appearance.
        window?.overrideUserInterfaceStyle = .dark
```
2. In the same method, right after `application.isIdleTimerDisabled = true`, add:
```swift
        controlVC.onRequestPermission = { [weak self] in
            self?.locationManager.requestWhenInUseAuthorization()
        }
```
3. In `locationManagerDidChangeAuthorization(_:)`, make the first line of the method body:
```swift
        controlVC.updateAuthorization(manager.authorizationStatus)
```
and shorten the `.denied, .restricted` status text to:
```swift
            setStatus("location permission denied —\nthe session will end when the phone locks.")
```
(The Settings deep-link now lives behind the in-app button, so the label no longer needs to spell out the Settings path.)

- [ ] **Step 3: Add the two VC hooks (stub UI for now)**

In `GPSSpoof/GPSSpoof/ControlViewController.swift`, add `import CoreLocation` under `import UIKit`, and add inside the class:

```swift
    /// Set by AppDelegate; triggers the system when-in-use permission prompt.
    var onRequestPermission: (() -> Void)?

    /// Called by AppDelegate whenever CoreLocation authorization changes.
    /// Surfaced as a permission card in the redesigned UI (next task).
    func updateAuthorization(_ status: CLAuthorizationStatus) {}
```

- [ ] **Step 4: Regenerate the project (Theme.swift must enter the graph)**

```bash
TEAM_ID=ZV4B6559W7 ./spoof.sh setup
```
Then verify all three:
```bash
git diff --stat GPSSpoof/GPSSpoof.xcodeproj/xcshareddata/xcschemes/GPSSpoof.xcscheme   # MUST print nothing
grep -c 'ZV4B6559W7' GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj                       # MUST be >= 1
grep -q 'Theme.swift' GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj && echo in-graph     # MUST print in-graph
```

- [ ] **Step 5: Build for the simulator**

```bash
xcodebuild -project GPSSpoof/GPSSpoof.xcodeproj -target GPSSpoof -configuration Debug -sdk iphonesimulator SYMROOT="$PWD/build/sim" OBJROOT="$PWD/build/sim/obj" CODE_SIGNING_ALLOWED=NO build -quiet
```
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git checkout -- GPSSpoof/GPSSpoof/locations/
git add GPSSpoof/GPSSpoof/Theme.swift GPSSpoof/GPSSpoof/AppDelegate.swift GPSSpoof/GPSSpoof/ControlViewController.swift GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj
git commit -m "feat(app): headliner theme + in-app location-permission hook

AppDelegate now routes authorization changes into the control UI and
exposes a request closure, so the app can re-trigger the permission
prompt instead of dead-ending on 'needs location permission'."
```

---

### Task 4: ControlViewController redesign (map + permission card)

**Files:**
- Modify: `GPSSpoof/GPSSpoof/ControlViewController.swift` (full rewrite — replace the entire file with the code below)

- [ ] **Step 1: Replace the file**

```swift
import UIKit
import MapKit
import CoreLocation

// Remote control for the Mac-side helper (GPSSpoofHelper): POSTs new
// coordinates to it, and the helper re-points the running Xcode simulation.
// Also displays the keepalive status that AppDelegate feeds in via showStatus.
// Styled after the headliner.studio palette (see Theme.swift).
final class ControlViewController: UIViewController {
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()

    private let permissionCard = Theme.card()
    private let permissionLabel = UILabel()
    private let permissionButton = Theme.goldButton(title: "Allow location access")

    private let urlField = Theme.field(
        placeholder: "helper URL, e.g. http://192.168.1.20:8755", keyboard: .URL)

    private let mapView = MKMapView()
    private let crosshairView = UIImageView(image: UIImage(
        systemName: "plus",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .light)))
    private let mapCoordLabel = UILabel()
    private let mapApplyButton = Theme.goldButton(title: "Set location to map center")

    private let latField = Theme.field(
        placeholder: "latitude, e.g. 37.3861", keyboard: .numbersAndPunctuation)
    private let lonField = Theme.field(
        placeholder: "longitude, e.g. -122.0839", keyboard: .numbersAndPunctuation)
    private let manualApplyButton = Theme.outlineButton(title: "Apply typed coordinates")
    private let resultLabel = UILabel()

    /// Set by AppDelegate; triggers the system when-in-use permission prompt.
    var onRequestPermission: (() -> Void)?
    private var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private static let urlDefaultsKey = "GPSSpoofHelperURL"
    private static let lastLatKey = "GPSSpoofLastLat"
    private static let lastLonKey = "GPSSpoofLastLon"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background

        titleLabel.text = "GPSSpoof"
        titleLabel.font = Theme.serifFont(size: 34, weight: .bold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.textAlignment = .center

        statusLabel.text = "waiting for location permission…"
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = Theme.textSecondary

        permissionLabel.numberOfLines = 0
        permissionLabel.font = .systemFont(ofSize: 14)
        permissionLabel.textColor = Theme.textSecondary
        permissionButton.addTarget(self, action: #selector(permissionTapped), for: .touchUpInside)
        let permissionStack = UIStackView(arrangedSubviews: [permissionLabel, permissionButton])
        permissionStack.axis = .vertical
        permissionStack.spacing = 12
        permissionStack.translatesAutoresizingMaskIntoConstraints = false
        permissionCard.addSubview(permissionStack)
        NSLayoutConstraint.activate([
            permissionStack.topAnchor.constraint(equalTo: permissionCard.topAnchor, constant: 16),
            permissionStack.bottomAnchor.constraint(equalTo: permissionCard.bottomAnchor, constant: -16),
            permissionStack.leadingAnchor.constraint(equalTo: permissionCard.leadingAnchor, constant: 16),
            permissionStack.trailingAnchor.constraint(equalTo: permissionCard.trailingAnchor, constant: -16),
        ])

        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.text = UserDefaults.standard.string(forKey: Self.urlDefaultsKey)

        mapView.delegate = self
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsUserLocation = true
        mapView.layer.cornerRadius = 12
        mapView.layer.borderWidth = 1
        mapView.layer.borderColor = Theme.surfaceBorder.cgColor
        mapView.clipsToBounds = true
        mapView.heightAnchor.constraint(equalToConstant: 260).isActive = true
        mapView.setRegion(initialRegion(), animated: false)

        crosshairView.tintColor = Theme.gold
        crosshairView.translatesAutoresizingMaskIntoConstraints = false
        mapView.addSubview(crosshairView)
        NSLayoutConstraint.activate([
            crosshairView.centerXAnchor.constraint(equalTo: mapView.centerXAnchor),
            crosshairView.centerYAnchor.constraint(equalTo: mapView.centerYAnchor),
        ])

        mapCoordLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        mapCoordLabel.textColor = Theme.textSecondary
        mapCoordLabel.textAlignment = .center
        updateMapCoordLabel()

        mapApplyButton.addTarget(self, action: #selector(mapApplyTapped), for: .touchUpInside)
        manualApplyButton.addTarget(self, action: #selector(manualApplyTapped), for: .touchUpInside)

        resultLabel.numberOfLines = 0
        resultLabel.textAlignment = .center
        resultLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        resultLabel.textColor = Theme.textSecondary

        let latLonRow = UIStackView(arrangedSubviews: [latField, lonField])
        latLonRow.axis = .horizontal
        latLonRow.spacing = 12
        latLonRow.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, statusLabel, permissionCard, urlField,
            mapView, mapCoordLabel, mapApplyButton,
            latLonRow, manualApplyButton, resultLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(8, after: mapView)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        refreshPermissionCard()
    }

    // MARK: AppDelegate API

    /// Called by AppDelegate with keepalive / simulated-fix updates.
    func showStatus(_ text: String) {
        DispatchQueue.main.async { self.statusLabel.text = text }
    }

    /// Called by AppDelegate whenever CoreLocation authorization changes.
    func updateAuthorization(_ status: CLAuthorizationStatus) {
        DispatchQueue.main.async {
            self.authorizationStatus = status
            self.refreshPermissionCard()
        }
    }

    private func refreshPermissionCard() {
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            permissionCard.isHidden = true
        case .denied, .restricted:
            permissionCard.isHidden = false
            permissionLabel.text = "Location permission denied — the spoof will end when the phone locks. Re-enable it in Settings."
            permissionButton.setTitle("Open Settings", for: .normal)
        case .notDetermined:
            permissionCard.isHidden = false
            permissionLabel.text = "Location access arms the keepalive that lets the spoof survive screen lock."
            permissionButton.setTitle("Allow location access", for: .normal)
        @unknown default:
            permissionCard.isHidden = true
        }
    }

    @objc private func permissionTapped() {
        if authorizationStatus == .notDetermined {
            onRequestPermission?()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: applying locations

    @objc private func mapApplyTapped() {
        view.endEditing(true)
        let center = mapView.centerCoordinate
        apply(lat: center.latitude, lon: center.longitude)
    }

    @objc private func manualApplyTapped() {
        view.endEditing(true)
        guard let lat = Double(latField.text ?? ""), let lon = Double(lonField.text ?? ""),
              (-90...90).contains(lat), (-180...180).contains(lon) else {
            showResult("lat must be -90..90, lon -180..180")
            return
        }
        apply(lat: lat, lon: lon)
    }

    private func apply(lat: Double, lon: Double) {
        var base = (urlField.text ?? "").trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/location"), url.scheme?.hasPrefix("http") == true else {
            showResult("enter the helper URL the Mac printed, e.g. http://192.168.1.20:8755")
            return
        }
        UserDefaults.standard.set(base, forKey: Self.urlDefaultsKey)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["lat": lat, "lon": lon])

        setApplying(true)
        showResult("applying…")
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
                let slot = body["slot"] as? String ?? "?"
                self?.showResult(String(format: "applied %.5f, %.5f (slot %@)", lat, lon, slot))
                self?.locationApplied(lat: lat, lon: lon)
            } else {
                self?.showResult(body["error"] as? String ?? "helper reported an error")
            }
        }.resume()
    }

    private func setApplying(_ inFlight: Bool) {
        mapApplyButton.isEnabled = !inFlight
        manualApplyButton.isEnabled = !inFlight
        mapApplyButton.alpha = inFlight ? 0.5 : 1
    }

    private func locationApplied(lat: Double, lon: Double) {
        UserDefaults.standard.set(lat, forKey: Self.lastLatKey)
        UserDefaults.standard.set(lon, forKey: Self.lastLonKey)
        DispatchQueue.main.async {
            self.latField.text = String(format: "%.5f", lat)
            self.lonField.text = String(format: "%.5f", lon)
            let target = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            self.mapView.setCenter(target, animated: true)
        }
    }

    private func initialRegion() -> MKCoordinateRegion {
        let defaults = UserDefaults.standard
        let lat = defaults.object(forKey: Self.lastLatKey) as? Double ?? 37.3861
        let lon = defaults.object(forKey: Self.lastLonKey) as? Double ?? -122.0839
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
    }

    private func updateMapCoordLabel() {
        let center = mapView.centerCoordinate
        mapCoordLabel.text = String(format: "%.5f, %.5f", center.latitude, center.longitude)
    }

    @objc private func dismissKeyboard() { view.endEditing(true) }

    private func showResult(_ text: String) {
        DispatchQueue.main.async { self.resultLabel.text = text }
    }
}

extension ControlViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        updateMapCoordLabel()
    }
}
```

Behavior notes (the spec for review):
- Helper URL, validation messages, request shape, and response handling are byte-identical in meaning to the old UI (same defaults key, same error strings) — only `applyButton` became two buttons sharing `apply(lat:lon:)`.
- Map apply uses `mapView.centerCoordinate` (always within valid ranges, no validation needed); manual apply keeps the old range validation.
- A successful apply persists the coords, fills the manual fields, and re-centers the map — so the map, fields, and helper state stay in sync no matter which path applied.
- The permission card is hidden once authorized; `.notDetermined` shows the request button (calls `onRequestPermission`), denied/restricted shows "Open Settings" (deep-links via `UIApplication.openSettingsURLString`).
- `showsUserLocation` makes the blue dot render the *simulated* fix — live feedback that the spoof moved.

- [ ] **Step 2: Build for the simulator**

```bash
xcodebuild -project GPSSpoof/GPSSpoof.xcodeproj -target GPSSpoof -configuration Debug -sdk iphonesimulator SYMROOT="$PWD/build/sim" OBJROOT="$PWD/build/sim/obj" CODE_SIGNING_ALLOWED=NO build -quiet
```
Expected: exit 0.

- [ ] **Step 3: Run the full integration suite**

Run: `bash tests/test_integration.sh`
Expected: all checks ok, exit 0.

- [ ] **Step 4: Commit**

```bash
git checkout -- GPSSpoof/GPSSpoof/locations/
git add GPSSpoof/GPSSpoof/ControlViewController.swift
git commit -m "feat(app): redesigned control UI — map picker, permission card, headliner palette

Embedded MKMapView with a gold crosshair and a set-to-map-center apply
button; manual lat/lon entry stays as a secondary path. Permission card
requests when-in-use auth or deep-links to Settings."
```

---

### Task 5: README updates

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the phone-control section**

In "Changing the location from the phone", replace the paragraph that begins "`--listen` opens Xcode as usual" with:

```markdown
`--listen` opens Xcode as usual, then builds and runs `GPSSpoofHelper` — a
small Swift command-line tool that lives in the same Xcode project — in the
foreground. The helper prints a URL like `http://192.168.1.20:8755` — enter
it once in the GPSSpoof app on the phone (it is remembered). Pan the embedded
map and tap **Set location to map center**, or type exact coordinates and tap
**Apply typed coordinates**: the helper writes them into one of two
alternating GPX slots (`live_a.gpx` / `live_b.gpx`) and clicks
**Debug ▸ Simulate Location** in Xcode for you, so the running session
re-reads the file. Two slots are used because Xcode caches a re-selected GPX
file.
```

And replace the Notes bullet "Each Apply briefly brings Xcode to the front on the Mac." with:

```markdown
- Each Apply briefly brings Xcode to the front and opens its Debug menu on
  the Mac (the Simulate Location submenu only exists while the menu chain is
  open, so the helper clicks through it step by step).
```

- [ ] **Step 2: Update the troubleshooting entry**

Replace the "**Spoof dies when the phone locks**" bullet with:

```markdown
- **Spoof dies when the phone locks** — The location permission was probably denied or never requested. Tap the gold permission button in the app (it requests access, or deep-links to Settings if access was denied), then run again. The app shows its keepalive status on screen.
```

- [ ] **Step 3: Run the integration suite, restore GPX, commit**

```bash
bash tests/test_integration.sh   # expect exit 0
git checkout -- GPSSpoof/GPSSpoof/locations/
git add README.md
git commit -m "docs: map picker UI, permission button, menu-chain clicking"
```

---

## Final verification (controller, after all tasks)

1. Dispatch the final whole-branch code reviewer.
2. Controller-only live end-to-end check (osascript allowed for the controller, NOT subagents): with the user's debug session still running, start `./spoof.sh helper --port 0` in the background, scrape the bound port, `curl POST /location` twice (first `{"lat":37.0,"lon":40.0}` expecting `{"ok":true,"slot":"live_a"}`, then `{"lat":37.3861,"lon":-122.0839}` expecting slot `live_b`), kill the helper, `git checkout -- GPSSpoof/GPSSpoof/locations/`.
3. Run all three suites; expect 22 + 18 + 31+1 ok, exit 0 each.
4. finishing-a-development-branch.
