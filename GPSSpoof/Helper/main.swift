import Foundation

// When stdout is redirected to a file (the tests do this), libc switches to
// full buffering and the "listening on port" line never reaches the log,
// deadlocking the test harness. Force line buffering before any print.
setlinebuf(stdout)

let defaultPort: UInt16 = 8755

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(2)
}

func printUsage() {
    print("""
    GPSSpoofHelper — phone-control helper for the GPS spoof toolkit.

    Listens for HTTP POSTs from the GPSSpoof iPhone app and re-points Xcode's
    running location simulation by rewriting alternating live-slot GPX files
    and clicking Debug > Simulate Location via UI scripting.

    Usage: GPSSpoofHelper [--port <n>] [--dry-run] [--probe-menu] [--locations-dir <path>]

      --port           listen port (default \(defaultPort); 0 = ephemeral)
      --dry-run        write GPX slots but skip all Xcode interaction
      --probe-menu     print Xcode's Simulate Location menu items and exit
      --locations-dir  directory holding the live-slot GPX files
                       (default: ./GPSSpoof/GPSSpoof/locations)
    """)
}

var port = defaultPort
var dryRun = false
var probeMenu = false
var locationsDir = FileManager.default.currentDirectoryPath
    + "/GPSSpoof/GPSSpoof/locations"

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--port":
        guard !arguments.isEmpty, let value = UInt16(arguments.removeFirst()) else {
            die("--port needs a number 0-65535")
        }
        port = value
    case "--dry-run":
        dryRun = true
    case "--probe-menu":
        probeMenu = true
    case "--locations-dir":
        guard !arguments.isEmpty else { die("--locations-dir needs a path") }
        locationsDir = arguments.removeFirst()
    case "-h", "--help":
        printUsage()
        exit(0)
    default:
        die("unknown argument: \(argument)")
    }
}

/// Best-effort LAN IP for the startup banner. The UDP socket is connected
/// but never written to — no traffic is sent.
func lanIP() -> String {
    let sock = socket(AF_INET, SOCK_DGRAM, 0)
    guard sock >= 0 else { return "127.0.0.1" }
    defer { close(sock) }
    var remote = sockaddr_in()
    remote.sin_family = sa_family_t(AF_INET)
    remote.sin_port = in_port_t(80).bigEndian
    remote.sin_addr.s_addr = inet_addr("1.1.1.1")
    let connected = withUnsafePointer(to: &remote) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return "127.0.0.1" }
    var local = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let resolved = withUnsafeMutablePointer(to: &local) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { name in
            getsockname(sock, name, &length)
        }
    }
    guard resolved == 0 else { return "127.0.0.1" }
    var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var address = local.sin_addr
    inet_ntop(AF_INET, &address, &ip, socklen_t(INET_ADDRSTRLEN))
    return String(cString: ip)
}

if probeMenu {
    let result = XcodeTrigger.runOsascript(XcodeTrigger.probeScript)
    let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    print(stdout.isEmpty ? stderr : stdout)
    exit(result.status == 0 ? 0 : 1)
}

/// JSON number or numeric string (parity with the Python helper's float()).
func coordinate(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

let applier = Applier(locationsDir: URL(fileURLWithPath: locationsDir), dryRun: dryRun)

let server: HTTPServer
do {
    server = try HTTPServer(port: port) { method, path, body in
        switch (method, path) {
        case ("GET", "/health"):
            return applier.health()
        case ("POST", "/location"):
            guard let object = try? JSONSerialization.jsonObject(with: body)
                    as? [String: Any],
                  let lat = coordinate(object["lat"]),
                  let lon = coordinate(object["lon"]) else {
                return (400, ["ok": false,
                              "error": "body must be JSON: {\"lat\": .., \"lon\": ..}"])
            }
            guard GPX.validate(lat: lat, lon: lon) else {
                return (400, ["ok": false, "error": "lat must be -90..90, lon -180..180"])
            }
            // Missing mode means v2 so app builds predating the toggle keep
            // working; an unrecognized value is a client bug, reject it.
            guard let mode = ApplyMode(rawValue: (object["mode"] as? String) ?? "v2") else {
                return (400, ["ok": false, "error": "mode must be \"v1\" or \"v2\""])
            }
            return applier.apply(lat: lat, lon: lon, mode: mode)
        default:
            return (404, ["ok": false, "error": "not found"])
        }
    }
} catch {
    die("cannot listen on port \(port): \(error.localizedDescription)")
}

server.start { boundPort in
    print(String(repeating: "=", count: 60))
    print("  GPSSpoof phone-control helper")
    print("  Enter this URL in the GPSSpoof app on the iPhone:")
    print("    http://\(lanIP()):\(boundPort)")
    print("  listening on port \(boundPort)")
    print("  Requires this terminal app to have Accessibility permission and")
    print("  Automation permission for Xcode (System Settings >")
    print("  Privacy & Security > Accessibility / Automation).")
    print("  Ctrl-C to stop. Stopping does NOT end the spoof session.")
    print(String(repeating: "=", count: 60))
}
dispatchMain()
