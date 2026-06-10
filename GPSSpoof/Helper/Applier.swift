import Foundation

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

/// The helper's state machine: writes coords into alternating live-slot GPX
/// files and (unless dry-run) clicks Xcode's Simulate Location menu.
/// The slot only advances when the whole apply succeeds, so a failed menu
/// click retries the same slot on the next attempt.
///
/// Xcode leaves the Simulate Location menu clickable after the debug session
/// dies (e.g. the app was quit on the phone), so every apply first checks
/// that a session is actually running; if not, it writes the coords into
/// target.gpx (the scheme's startup GPX) and asks Xcode to run again.
final class Applier {
    private let locationsDir: URL
    private let dryRun: Bool
    private var slot = GPX.slots.last! // first apply lands on slots[0]
    private let lock = NSLock()

    init(locationsDir: URL, dryRun: Bool) {
        self.locationsDir = locationsDir
        self.dryRun = dryRun
    }

    func health() -> (status: Int, json: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        return (200, ["ok": true, "slot": slot])
    }

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

    /// Dead session: slot clicks would silently no-op, so boot a fresh Run
    /// instead. The coords go into target.gpx — the GPX the shared scheme
    /// references — so the new session starts at the requested location.
    private func relaunch(lat: Double, lon: Double) -> (status: Int, json: [String: Any]) {
        let file = locationsDir.appendingPathComponent("target.gpx")
        do {
            try GPX.make(lat: lat, lon: lon, name: "target")
                .write(to: file, atomically: true, encoding: .utf8)
        } catch {
            let message = "cannot write \(file.path): \(error.localizedDescription)"
            print("  FAIL - \(message)")
            return (500, ["ok": false, "error": message])
        }
        if let failure = XcodeTrigger.relaunchDebugSession() {
            print("  FAIL - \(failure.message)")
            return (failure.status, ["ok": false, "error": failure.message])
        }
        // Fresh session boots with target.gpx selected, so both slots are
        // "different items" again; restart the alternation from the top.
        slot = GPX.slots.last!
        print("  ok   - session was dead; relaunching at "
            + "\(GPX.formatCoord(lat)), \(GPX.formatCoord(lon)) via target.gpx")
        return (200, ["ok": true, "relaunched": true])
    }
}
