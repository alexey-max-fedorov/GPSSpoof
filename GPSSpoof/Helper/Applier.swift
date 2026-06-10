import Foundation

/// The helper's state machine: writes coords into alternating live-slot GPX
/// files and (unless dry-run) clicks Xcode's Simulate Location menu.
/// The slot only advances when the whole apply succeeds, so a failed menu
/// click retries the same slot on the next attempt.
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

    func apply(lat: Double, lon: Double) -> (status: Int, json: [String: Any]) {
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
        if !dryRun, let failure = XcodeTrigger.clickSimulateLocation(slot: next) {
            print("  FAIL - \(failure.message)")
            return (failure.status, ["ok": false, "error": failure.message])
        }
        slot = next
        print("  ok   - applied \(GPX.formatCoord(lat)), \(GPX.formatCoord(lon)) via \(next)")
        return (200, ["ok": true, "slot": next])
    }
}
