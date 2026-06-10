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
    private let controlVC = ControlViewController()
    private var keepaliveRunning = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        // The control UI is a fixed dark design (headliner palette); forcing
        // dark also keeps MKMapView in its dark appearance.
        window?.overrideUserInterfaceStyle = .dark
        window?.rootViewController = controlVC
        window?.makeKeyAndVisible()

        // Locking is safe once the background location session is running;
        // disabling auto-lock just removes one way to trigger it accidentally
        // before permission is granted.
        application.isIdleTimerDisabled = true
        controlVC.onRequestPermission = { [weak self] in
            self?.locationManager.requestWhenInUseAuthorization()
        }

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.activityType = .otherNavigation
        // Seed from the cached status instead of waiting for the async
        // delegate callback, so the permission card never flashes (or
        // sticks) when access was already granted.
        applyAuthorization()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Re-sync on every foreground: covers Settings round-trips and any
        // missed delegate callback. This is also the reliable moment to
        // prompt — the system alert can be dropped when requested before
        // the app is active.
        applyAuthorization()
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        applyAuthorization()
    }

    private func applyAuthorization() {
        let status = locationManager.authorizationStatus
        controlVC.updateAuthorization(status)
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            // Idempotent: applyAuthorization runs on every foreground, and
            // re-arming would stomp the "reporting…" status text.
            guard !keepaliveRunning else { break }
            keepaliveRunning = true
            // Requires the `location` entry in UIBackgroundModes, otherwise
            // this assignment raises an exception.
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
            setStatus("keepalive armed\nwaiting for first fix…")
        case .denied, .restricted:
            keepaliveRunning = false
            setStatus("location permission denied —\nthe session will end when the phone locks.")
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
        controlVC.showStatus(text)
    }
}
