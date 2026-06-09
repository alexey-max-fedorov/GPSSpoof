import UIKit
import CoreLocation

// The app's real job is keeping the debuggee process alive: Xcode's location
// simulation lasts only as long as the debug Run session, and iOS suspends a
// foreground-only app seconds after the screen locks, which ends the session.
// Declaring the `location` background mode and holding a continuous location
// session keeps the process running while the phone is locked or the app is
// backgrounded. When-in-use authorization is sufficient for this once
// allowsBackgroundLocationUpdates is set.
@main
class AppDelegate: UIResponder, UIApplicationDelegate, CLLocationManagerDelegate {
    var window: UIWindow?
    private let locationManager = CLLocationManager()
    private let statusLabel = UILabel()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground

        statusLabel.text = "GPSSpoof\nwaiting for location permission…"
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: root.view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: root.view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.view.trailingAnchor, constant: -16),
        ])

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = root
        window?.makeKeyAndVisible()

        // Locking is safe once the background location session is running;
        // disabling auto-lock just removes one way to trigger it accidentally
        // before permission is granted.
        application.isIdleTimerDisabled = true

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.activityType = .otherNavigation
        locationManager.requestWhenInUseAuthorization()
        return true
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // Requires the `location` entry in UIBackgroundModes, otherwise
            // this assignment raises an exception.
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
            setStatus("keepalive armed\nwaiting for first fix…")
        case .denied, .restricted:
            setStatus("location permission denied —\nthe session will end when the phone locks.\nEnable in Settings > Privacy > Location Services.")
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        setStatus(String(
            format: "reporting\n%.5f, %.5f\n\nkeep this app installed and running;\nthe blue location indicator means\nthe session is alive",
            fix.coordinate.latitude, fix.coordinate.longitude
        ))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        setStatus("location error: \(error.localizedDescription)")
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.statusLabel.text = text }
    }
}
