import Foundation

/// GPX generation and coordinate validation — the Swift port of the pure
/// functions from the retired Python helper.
enum GPX {
    /// Two slots alternate because Xcode caches a re-selected GPX file;
    /// picking a *different* menu item forces a re-read.
    static let slots = ["live_a", "live_b"]

    static func validate(lat: Double, lon: Double) -> Bool {
        lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
    }

    /// Decimal string for a GPX attribute. Swift's shortest-round-trip
    /// description keeps typical values readable ("37.3861" stays "37.3861")
    /// but switches to scientific notation for tiny magnitudes ("1e-05"),
    /// which xsd:decimal forbids — fall back to fixed-point.
    static func formatCoord(_ value: Double) -> String {
        let text = String(value)
        if text.contains("e") || text.contains("E") {
            return String(format: "%.7f", value)
        }
        return text
    }

    static func xmlEscape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Single-waypoint GPX 1.1, same shape spoof.sh's write_gpx emits. The
    /// waypoint name must equal the slot name: Xcode's Simulate Location menu
    /// has labeled GPX entries by file name in some versions and by waypoint
    /// name in others, and keeping them identical makes the click work
    /// either way.
    static func make(lat: Double, lon: Double, name: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="GPSSpoof" xmlns="http://www.topografix.com/GPX/1/1">
          <wpt lat="\(formatCoord(lat))" lon="\(formatCoord(lon))">
            <name>\(xmlEscape(name))</name>
          </wpt>
        </gpx>

        """
    }

    static func nextSlot(after current: String) -> String {
        let index = slots.firstIndex(of: current) ?? 0
        return slots[(index + 1) % slots.count]
    }
}
