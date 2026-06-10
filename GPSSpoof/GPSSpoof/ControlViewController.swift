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

    private let urlToggleButton = UIButton(type: .system)
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

    // Index 0 = v2 (default). v1 is the escape hatch if the session check
    // ever misfires — it never triggers a rebuild.
    private let modeControl = UISegmentedControl(items: ["v2 · self-healing", "v1 · raw clicks"])

    private let spoofToggleButton = UIButton(type: .system)
    private var spoofingOn = false
    // Auto-detect drives the toggle only until the user (or an apply) takes
    // over; after that it reflects explicit actions, so a stale GPS fix
    // can't flip it back mid-session.
    private var spoofingStateLocked = false
    /// Simulated fixes land exactly on the target; real GPS practically
    /// never does unless you're physically there.
    private static let targetMatchMeters: CLLocationDistance = 100

    /// Set by AppDelegate; triggers the system when-in-use permission prompt.
    var onRequestPermission: (() -> Void)?
    private var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private static let urlDefaultsKey = "GPSSpoofHelperURL"
    private static let lastLatKey = "GPSSpoofLastLat"
    private static let lastLonKey = "GPSSpoofLastLon"
    private static let modeDefaultsKey = "GPSSpoofApplyMode"

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
        urlToggleButton.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        urlToggleButton.setTitleColor(Theme.gold, for: .normal)
        urlToggleButton.addTarget(self, action: #selector(urlToggleTapped), for: .touchUpInside)
        // Tucked away once a helper URL is saved; first run starts revealed.
        setURLFieldRevealed((urlField.text ?? "").isEmpty)

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

        spoofToggleButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        spoofToggleButton.layer.cornerRadius = 10
        spoofToggleButton.layer.borderWidth = 1
        spoofToggleButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        spoofToggleButton.addTarget(self, action: #selector(spoofToggleTapped), for: .touchUpInside)
        renderSpoofToggle()

        let latLonRow = UIStackView(arrangedSubviews: [latField, lonField])
        latLonRow.axis = .horizontal
        latLonRow.spacing = 12
        latLonRow.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, statusLabel, spoofToggleButton, permissionCard,
            mapView, mapCoordLabel, mapApplyButton,
            latLonRow, manualApplyButton, resultLabel,
            modeControl,
            urlToggleButton, urlField,
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(8, after: mapView)
        stack.setCustomSpacing(8, after: urlToggleButton)
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

    // MARK: helper address reveal

    private func setURLFieldRevealed(_ revealed: Bool) {
        urlField.isHidden = !revealed
        urlToggleButton.setTitle(revealed ? "helper address ▾" : "helper address ▸", for: .normal)
    }

    @objc private func urlToggleTapped() {
        let reveal = urlField.isHidden
        if !reveal { view.endEditing(true) }
        UIView.animate(withDuration: 0.25) {
            self.setURLFieldRevealed(reveal)
            self.view.layoutIfNeeded()
        }
    }

    // MARK: switch method

    /// "v1" = blind menu clicks (original), "v2" = session check + self-heal.
    private var applyMode: String {
        modeControl.selectedSegmentIndex == 1 ? "v1" : "v2"
    }

    @objc private func modeChanged() {
        UserDefaults.standard.set(applyMode, forKey: Self.modeDefaultsKey)
    }

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

    private func apply(lat: Double, lon: Double) {
        guard let url = helperEndpoint("/location") else {
            showResult("enter the helper URL the Mac printed, e.g. http://192.168.1.20:8755")
            setURLFieldRevealed(true)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["lat": lat, "lon": lon, "mode": applyMode])

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
                if body["relaunched"] as? Bool == true {
                    // The Mac session had died (e.g. this app was quit);
                    // the helper restarted it with these coords in target.gpx.
                    // Xcode will reinstall and relaunch this app shortly.
                    self?.showResult(String(format:
                        "the Mac session had ended — restarting it\nat %.5f, %.5f. Xcode is rebuilding;\nthis app will relaunch itself in ~30s.",
                        lat, lon))
                } else {
                    let slot = body["slot"] as? String ?? "?"
                    self?.showResult(String(format: "applied %.5f, %.5f (slot %@)", lat, lon, slot))
                }
                self?.locationApplied(lat: lat, lon: lon)
            } else {
                self?.showResult(body["error"] as? String ?? "helper reported an error")
            }
        }.resume()
    }

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
