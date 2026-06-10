# Swift Helper Bundling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Python phone-control helper (`lib/location_helper.py`) with a Swift command-line tool bundled into the existing Xcode project, and collapse `setup.sh` + `lib/gpx.sh` into `spoof.sh` so the repo has a single shell entry point and zero Python.

**Architecture:** A new `GPSSpoofHelper` macOS `tool` target lives in `GPSSpoof/GPSSpoof.xcodeproj` next to the iOS app (sources in `GPSSpoof/Helper/`). It is a minimal NWListener-based HTTP server with the exact same API contract as the Python helper, shelling out to `osascript` for the Xcode menu click. `spoof.sh` becomes the single entry point with subcommands: `setup` (absorbs setup.sh), `helper` (builds + runs the Swift binary), and the default spoof flow (absorbs lib/gpx.sh as sourceable functions). Tests for the helper become black-box bash tests against the real binary in `--dry-run` mode.

**Tech Stack:** Swift 5 (Foundation + Network frameworks, no third-party deps), xcodegen, bash, xmllint, curl.

**Branch:** `phone-location-control` (already checked out; this work layers on top of the Python implementation it replaces).

---

## Context for implementers (read before any task)

- **The shared scheme file `GPSSpoof/GPSSpoof.xcodeproj/xcshareddata/xcschemes/GPSSpoof.xcscheme` must NEVER be modified.** It carries hand-written location-simulation wiring that Xcode and xcodegen cannot regenerate. After any project regeneration, `git diff` for this file must be empty.
- **Never run raw `xcodegen generate`.** Always regenerate via `TEAM_ID=ZV4B6559W7 ./setup.sh` (Tasks 1–2) or `TEAM_ID=ZV4B6559W7 ./spoof.sh setup` (Task 3 onward, after setup.sh is absorbed). If TEAM_ID is not passed, xcodegen silently blanks `DEVELOPMENT_TEAM = ZV4B6559W7;` out of project.pbxproj and breaks device signing. After every regen, verify: `grep -c 'ZV4B6559W7' GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj` returns a number ≥ 1.
- **API contract (must hold byte-for-byte in semantics, the phone app depends on it):**
  - `POST /location` body `{"lat": <num>, "lon": <num>}` → `200 {"ok":true,"slot":"live_a"}`; numeric strings for lat/lon are also accepted (Python `float()` parity).
  - Invalid JSON / missing keys / out-of-range → `400 {"ok":false,"error":"<msg>"}`
  - Xcode menu item missing → `409`, Accessibility permission missing → `403`, other osascript failure → `502`. All error bodies `{"ok":false,"error":"<msg>"}`.
  - `GET /health` → `200 {"ok":true,"slot":"<last applied slot>"}` (starts at `live_b` so the first apply lands on `live_a`).
  - Anything else → `404 {"ok":false,"error":"not found"}`. Default port 8755.
- **Two GPX slots (`live_a.gpx` / `live_b.gpx`) alternate** because Xcode caches a re-selected GPX file; clicking a *different* menu item forces a re-read. The waypoint `<name>` must equal the slot name — Xcode's Simulate Location menu labels entries by file name in some versions and waypoint name in others.
- **The slot only advances when the whole apply succeeds** (write + menu click). A failed click retries the same slot on the next POST.
- **`tests/test_integration.sh` mutates `GPSSpoof/GPSSpoof/locations/target.gpx` by design.** After running it, always restore: `git checkout -- GPSSpoof/GPSSpoof/locations/target.gpx` before committing.
- The iOS app (`ControlViewController.swift`, `AppDelegate.swift`) is NOT touched by this plan. Free Apple ID signing constraints continue to apply to the iOS target; the macOS helper target builds with code signing disabled.
- Coordinate formatting trap (this bug already happened once in Python): Swift's `String(0.00001)` produces `"1e-05"` — scientific notation is illegal for GPX `xsd:decimal` attributes. `GPX.formatCoord` falls back to `%.7f` fixed-point when the shortest representation contains `e`/`E`. Do not "simplify" this away.
- stdout buffering trap: when the helper's stdout is redirected to a file (as the tests do), libc switches to full buffering and the `listening on port` line never reaches the log, deadlocking the tests. `main.swift` calls `setlinebuf(stdout)` first thing. Do not remove it.

## File structure after all tasks

```
spoof.sh                                 # SINGLE entry point: setup | spoof | helper
tests/test_gpx.sh                        # sources spoof.sh (GPX shell functions)
tests/test_helper.sh                     # black-box tests for the Swift helper (NEW)
tests/test_integration.sh                # end-to-end smoke checks
GPSSpoof/project.yml                     # + GPSSpoofHelper tool target
GPSSpoof/Helper/main.swift               # CLI args, banner, routing, lanIP (NEW)
GPSSpoof/Helper/GPX.swift                # validate, formatCoord, make, slots (NEW)
GPSSpoof/Helper/HTTPServer.swift         # minimal NWListener HTTP/1.1 server (NEW)
GPSSpoof/Helper/Applier.swift            # slot state machine, apply/health (NEW)
GPSSpoof/Helper/XcodeTrigger.swift       # osascript click + probe + error mapping (NEW)
GPSSpoof/GPSSpoof/...                    # iOS app — UNCHANGED
DELETED: setup.sh, lib/gpx.sh, lib/location_helper.py, tests/test_helper.py, lib/
```

---

### Task 1: GPSSpoofHelper target skeleton (project.yml, GPX.swift, HTTPServer.swift, main.swift, /health)

**Files:**
- Create: `tests/test_helper.sh`
- Create: `GPSSpoof/Helper/GPX.swift`
- Create: `GPSSpoof/Helper/HTTPServer.swift`
- Create: `GPSSpoof/Helper/main.swift`
- Modify: `GPSSpoof/project.yml`
- Regenerated: `GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj` (via `TEAM_ID=ZV4B6559W7 ./setup.sh`)

- [ ] **Step 1: Write the failing black-box test**

Create `tests/test_helper.sh` (mode 755):

```bash
#!/usr/bin/env bash
# Black-box tests for the Swift phone-control helper (GPSSpoofHelper).
# Runs the real binary in --dry-run mode on an ephemeral port with a temp
# locations dir: no Xcode UI, no device, nothing beyond loopback.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$ROOT/build/Release/GPSSpoofHelper"

FAILED=0
ok()   { echo "  ok   - $1"; }
fail() { echo "  FAIL - $1"; FAILED=1; }

echo "GPSSpoofHelper black-box:"

# Build the helper (incremental no-op when nothing changed).
if xcodebuild -project "$ROOT/GPSSpoof/GPSSpoof.xcodeproj" -target GPSSpoofHelper \
     -configuration Release SYMROOT="$ROOT/build" OBJROOT="$ROOT/build/obj" \
     build -quiet >/dev/null 2>&1; then
  ok "helper builds"
else
  fail "helper build failed"
  exit 1
fi

TMP="$(mktemp -d -t gpsspoof-helper)"
LOG="$TMP/helper.log"
"$BIN" --dry-run --port 0 --locations-dir "$TMP" >"$LOG" 2>&1 &
HELPER_PID=$!
cleanup() { kill "$HELPER_PID" 2>/dev/null; wait "$HELPER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Wait for the helper to report its kernel-assigned port.
PORT=""
for _ in $(seq 1 50); do
  PORT="$(sed -n 's/.*listening on port \([0-9][0-9]*\).*/\1/p' "$LOG" | head -1)"
  [[ -n "$PORT" ]] && break
  sleep 0.1
done
if [[ -n "$PORT" ]]; then ok "helper starts and reports its port"
else fail "no 'listening on port' line in startup output"; exit 1; fi

BASE="http://127.0.0.1:$PORT"
BODY="$TMP/body.json"

# req <method> <path> [json-body]  — sets STATUS, response body lands in $BODY
req() {
  local method="$1" path="$2" data="${3-}"
  if [[ -n "$data" ]]; then
    STATUS=$(curl -s --max-time 5 -o "$BODY" -w '%{http_code}' -X "$method" \
             -H 'Content-Type: application/json' --data "$data" "$BASE$path")
  else
    STATUS=$(curl -s --max-time 5 -o "$BODY" -w '%{http_code}' -X "$method" "$BASE$path")
  fi
}
has() { grep -q "$1" "$BODY"; }

# 1. /health before any apply: ok=true, slot=live_b (first apply lands live_a).
req GET /health
if [[ "$STATUS" == 200 ]] && has '"ok":true' && has '"slot":"live_b"'; then
  ok "GET /health"
else fail "GET /health -> $STATUS $(cat "$BODY" 2>/dev/null)"; fi

# 2. Unknown path -> 404 with ok=false.
req GET /nope
if [[ "$STATUS" == 404 ]] && has '"ok":false'; then ok "404 on unknown path"
else fail "GET /nope -> $STATUS"; fi

exit "$FAILED"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_helper.sh`
Expected: `FAIL - helper build failed`, exit code 1 (the GPSSpoofHelper target does not exist yet).

- [ ] **Step 3: Add the helper target to project.yml**

In `GPSSpoof/project.yml`, change the `deploymentTarget` block under `options:` from:

```yaml
  deploymentTarget:
    iOS: "15.0"
```

to:

```yaml
  deploymentTarget:
    iOS: "15.0"
    macOS: "13.0"
```

and append this target to the `targets:` section (sibling of `GPSSpoof:`, same indent level):

```yaml
  # Mac-side phone-control helper. A plain command-line tool: listens for
  # HTTP POSTs from the iPhone app and re-points Xcode's running location
  # simulation. Built by spoof.sh via `xcodebuild -target GPSSpoofHelper`;
  # code signing is disabled because it only ever runs on this Mac.
  GPSSpoofHelper:
    type: tool
    platform: macOS
    sources:
      - path: Helper
    settings:
      base:
        CODE_SIGNING_ALLOWED: "NO"
        DEVELOPMENT_TEAM: ""
        PRODUCT_NAME: GPSSpoofHelper
    scheme: ~
```

- [ ] **Step 4: Create `GPSSpoof/Helper/GPX.swift`**

```swift
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
```

- [ ] **Step 5: Create `GPSSpoof/Helper/HTTPServer.swift`**

```swift
import Foundation
import Network

/// Minimal HTTP/1.1 server on NWListener: just enough for the helper's two
/// JSON endpoints. One short-lived connection per request (Connection: close).
final class HTTPServer {
    typealias Handler = (_ method: String, _ path: String, _ body: Data)
        -> (status: Int, json: [String: Any])

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "GPSSpoofHelper.http")

    init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "GPSSpoofHelper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }
        self.listener = try NWListener(using: parameters, on: nwPort)
        self.handler = handler
    }

    /// Starts listening; calls onReady with the actual bound port (resolves
    /// port 0 to the kernel-assigned ephemeral port — the tests rely on it).
    func start(onReady: @escaping (UInt16) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                onReady(self?.listener.port?.rawValue ?? 0)
            case .failed(let error):
                FileHandle.standardError.write(Data("listener failed: \(error)\n".utf8))
                exit(1)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] chunk, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffered
            if let chunk = chunk { buffer.append(chunk) }
            if let request = Self.parse(buffer) {
                let result = self.handler(request.method, request.path, request.body)
                self.respond(connection, status: result.status, json: result.json)
            } else if error != nil || isComplete || buffer.count > 1_048_576 {
                connection.cancel() // malformed, oversized, or closed early
            } else {
                self.receive(connection, buffered: buffer)
            }
        }
    }

    /// Returns nil while the request is still incomplete (keep buffering).
    private static func parse(_ data: Data)
        -> (method: String, path: String, body: Data)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2,
               pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        return (String(requestLine[0]), String(requestLine[1]),
                Data(body.prefix(contentLength)))
    }

    private func respond(_ connection: NWConnection, status: Int, json: [String: Any]) {
        // sortedKeys gives deterministic bodies; the bash tests grep fragments.
        let body = (try? JSONSerialization.data(withJSONObject: json,
                                                options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden",
                       404: "Not Found", 409: "Conflict",
                       500: "Internal Server Error", 502: "Bad Gateway"]
        let head = "HTTP/1.1 \(status) \(reasons[status] ?? "OK")\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
```

- [ ] **Step 6: Create `GPSSpoof/Helper/main.swift`**

```swift
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
      --dry-run        write GPX slots but skip the Xcode menu click
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

_ = dryRun      // used from Task 2 on
_ = probeMenu   // used from Task 2 on
_ = locationsDir // used from Task 2 on

let server: HTTPServer
do {
    server = try HTTPServer(port: port) { method, path, _ in
        switch (method, path) {
        case ("GET", "/health"):
            return (200, ["ok": true, "slot": GPX.slots.last!])
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
    print("  Requires Accessibility permission for this terminal app")
    print("  (System Settings > Privacy & Security > Accessibility).")
    print("  Ctrl-C to stop. Stopping does NOT end the spoof session.")
    print(String(repeating: "=", count: 60))
}
dispatchMain()
```

Note: the three `_ =` lines silence unused-variable warnings until Task 2 wires them up; Task 2 removes them.

- [ ] **Step 7: Regenerate the project and verify nothing fragile broke**

```bash
TEAM_ID=ZV4B6559W7 ./setup.sh
grep -c 'ZV4B6559W7' GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj   # expect >= 1
git diff --stat GPSSpoof/GPSSpoof.xcodeproj/xcshareddata/           # expect EMPTY output
grep -c 'GPSSpoofHelper' GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj # expect >= 1
cd GPSSpoof && xcodebuild -project GPSSpoof.xcodeproj -list && cd ..
# expect: Targets list shows both GPSSpoof and GPSSpoofHelper
```

If `xcodegen` rejects `type: tool` or the macOS deployment target (unlikely on current xcodegen), STOP and report BLOCKED — do not improvise project-format changes.

- [ ] **Step 8: Run the test to verify it passes**

Run: `bash tests/test_helper.sh`
Expected: all 4 checks ok (`helper builds`, `helper starts and reports its port`, `GET /health`, `404 on unknown path`), exit 0.

- [ ] **Step 9: Confirm the existing suites still pass**

```bash
bash tests/test_gpx.sh          # expect: all ok
bash tests/test_integration.sh  # expect: all ok (25 checks)
git checkout -- GPSSpoof/GPSSpoof/locations/target.gpx   # restore test mutation
```

- [ ] **Step 10: Commit**

```bash
git add tests/test_helper.sh GPSSpoof/Helper GPSSpoof/project.yml \
        GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj
git commit -m "feat(helper): add Swift GPSSpoofHelper tool target with /health endpoint"
```

---

### Task 2: Full helper behavior — apply, slots, Xcode trigger, probe

**Files:**
- Create: `GPSSpoof/Helper/Applier.swift`
- Create: `GPSSpoof/Helper/XcodeTrigger.swift`
- Modify: `GPSSpoof/Helper/main.swift`
- Modify: `tests/test_helper.sh`
- Regenerated: `GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj` (via `TEAM_ID=ZV4B6559W7 ./setup.sh` — two new source files must enter the project graph)

- [ ] **Step 1: Extend the black-box test with the apply behavior**

In `tests/test_helper.sh`, insert the following block immediately BEFORE the final `exit "$FAILED"` line:

```bash
# 3. Non-JSON body -> 400.
req POST /location 'not json'
if [[ "$STATUS" == 400 ]] && has '"ok":false'; then ok "400 on malformed JSON"
else fail "malformed JSON -> $STATUS"; fi

# 4. Missing lon -> 400.
req POST /location '{"lat": 10}'
if [[ "$STATUS" == 400 ]]; then ok "400 on missing lon"
else fail "missing lon -> $STATUS"; fi

# 5. Out-of-range -> 400, and no slot file gets written.
req POST /location '{"lat": 999, "lon": 0}'
if [[ "$STATUS" == 400 ]]; then ok "400 on out-of-range lat"
else fail "lat=999 -> $STATUS"; fi
if [[ ! -f "$TMP/live_a.gpx" ]]; then ok "no slot written on rejection"
else fail "live_a.gpx written despite rejection"; fi

# 6. First valid apply -> live_a; file is well-formed with coords + name.
req POST /location '{"lat": 37.3861, "lon": -122.0839}'
if [[ "$STATUS" == 200 ]] && has '"ok":true' && has '"slot":"live_a"'; then
  ok "first apply -> live_a"
else fail "first apply -> $STATUS $(cat "$BODY" 2>/dev/null)"; fi
if xmllint --noout "$TMP/live_a.gpx" 2>/dev/null; then ok "live_a.gpx well-formed"
else fail "live_a.gpx invalid or missing"; fi
LAT="$(xmllint --xpath 'string(//*[local-name()="wpt"]/@lat)' "$TMP/live_a.gpx" 2>/dev/null)"
if [[ "$LAT" == "37.3861" ]]; then ok "lat survives round-trip"
else fail "lat=$LAT (expected 37.3861)"; fi
NAME="$(xmllint --xpath 'string(//*[local-name()="name"])' "$TMP/live_a.gpx" 2>/dev/null)"
if [[ "$NAME" == "live_a" ]]; then ok "waypoint name == slot"
else fail "waypoint name=$NAME (expected live_a)"; fi

# 7. Second apply alternates to live_b.
req POST /location '{"lat": 40, "lon": 50}'
if [[ "$STATUS" == 200 ]] && has '"slot":"live_b"'; then ok "second apply -> live_b"
else fail "second apply -> $STATUS"; fi

# 8. Third apply wraps back to live_a; boundary coords accepted.
req POST /location '{"lat": -90, "lon": 180}'
if [[ "$STATUS" == 200 ]] && has '"slot":"live_a"'; then ok "slots wrap around"
else fail "third apply -> $STATUS"; fi

# 9. Tiny coords stay fixed-point (xsd:decimal forbids 1e-05).
req POST /location '{"lat": 0.00001, "lon": 0}'
if [[ "$STATUS" == 200 ]] && has '"slot":"live_b"'; then ok "tiny coords accepted"
else fail "tiny coords -> $STATUS"; fi
LAT="$(xmllint --xpath 'string(//*[local-name()="wpt"]/@lat)' "$TMP/live_b.gpx" 2>/dev/null)"
case "$LAT" in
  *[eE]*) fail "scientific notation leaked into GPX: lat=$LAT" ;;
  "")     fail "live_b.gpx missing lat" ;;
  *)      ok "tiny coords stay decimal ($LAT)" ;;
esac

# 10. Numeric strings accepted (parity with the Python helper's float()).
req POST /location '{"lat": "37.5", "lon": "10"}'
if [[ "$STATUS" == 200 ]]; then ok "string coords coerced"
else fail "string coords -> $STATUS"; fi

# 11. /health reflects the last applied slot (applies: a,b,a,b,a -> live_a).
req GET /health
if has '"slot":"live_a"'; then ok "/health tracks the active slot"
else fail "/health slot: $(cat "$BODY" 2>/dev/null)"; fi
```

- [ ] **Step 2: Run the test to verify the new checks fail**

Run: `bash tests/test_helper.sh`
Expected: checks 1–2 still ok; checks 3 onward FAIL (POST /location currently routes to 404). Exit 1.

- [ ] **Step 3: Create `GPSSpoof/Helper/XcodeTrigger.swift`**

The AppleScript bodies and user-facing error messages are a 1:1 port of the Python helper — the spec reviewer should diff them against this plan, not paraphrase.

```swift
import Foundation

/// UI-scripts Xcode (Debug > Simulate Location > <slot>) via osascript.
/// Requires macOS Accessibility permission for the terminal app running the
/// helper. Each click briefly brings Xcode frontmost.
enum XcodeTrigger {
    static func clickScript(slot: String) -> String {
        """
        tell application "System Events"
          tell process "Xcode"
            set frontmost to true
            click menu item "\(slot)" of menu 1 of menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
          end tell
        end tell
        """
    }

    static let probeScript = """
        tell application "System Events"
          tell process "Xcode"
            set frontmost to true
            get name of every menu item of menu 1 of menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
          end tell
        end tell
        """

    static func runOsascript(_ script: String)
        -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return (127, "", "failed to launch osascript: \(error.localizedDescription)")
        }
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: stdoutData, encoding: .utf8) ?? "",
                String(data: stderrData, encoding: .utf8) ?? "")
    }

    /// Click Debug > Simulate Location > <slot> in Xcode.
    /// Returns nil on success, or (httpStatus, message) mapping the osascript
    /// failure onto the helper's API error contract.
    static func clickSimulateLocation(slot: String) -> (status: Int, message: String)? {
        let result = runOsascript(clickScript(slot: slot))
        if result.status == 0 { return nil }
        let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = error.lowercased()
        // macOS wording varies by version: "not allowed assistive access",
        // "Not authorized to send Apple events to System Events", ...
        if lowered.contains("assistive access") || lowered.contains("not authorized")
            || lowered.contains("not allowed") {
            return (403, "macOS blocked UI scripting. Grant Accessibility permission to "
                + "the terminal app running this helper (System Settings > "
                + "Privacy & Security > Accessibility; if it still fails, also "
                + "check Privacy & Security > Automation), then tap Apply again.")
        }
        if lowered.contains("menu item") {
            return (409, "Xcode has no 'Simulate Location > \(slot)' menu item. Is the "
                + "debug session running? On the Mac, run "
                + "'./spoof.sh helper --probe-menu' to see what Xcode actually lists.")
        }
        return (502, "osascript failed: \(error)")
    }
}
```

- [ ] **Step 4: Create `GPSSpoof/Helper/Applier.swift`**

```swift
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
```

- [ ] **Step 5: Wire routing, probe mode, and coordinate coercion into `main.swift`**

In `GPSSpoof/Helper/main.swift`:

(a) Delete the three placeholder lines:

```swift
_ = dryRun      // used from Task 2 on
_ = probeMenu   // used from Task 2 on
_ = locationsDir // used from Task 2 on
```

(b) Immediately after the `lanIP()` function, add:

```swift
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
```

(c) Replace the whole `server = try HTTPServer(port: port) { ... }` closure body so the routing reads:

```swift
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
            return applier.apply(lat: lat, lon: lon)
        default:
            return (404, ["ok": false, "error": "not found"])
        }
    }
```

- [ ] **Step 6: Regenerate the project (two new source files) and verify**

```bash
TEAM_ID=ZV4B6559W7 ./setup.sh
grep -c 'ZV4B6559W7' GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj      # expect >= 1
git diff --stat GPSSpoof/GPSSpoof.xcodeproj/xcshareddata/              # expect EMPTY
grep -c 'Applier.swift' GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj    # expect >= 1
grep -c 'XcodeTrigger.swift' GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj # expect >= 1
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bash tests/test_helper.sh`
Expected: all 15 checks ok, exit 0.

- [ ] **Step 8: Confirm the existing suites still pass**

```bash
bash tests/test_gpx.sh
bash tests/test_integration.sh
git checkout -- GPSSpoof/GPSSpoof/locations/target.gpx
```

- [ ] **Step 9: Commit**

```bash
git add tests/test_helper.sh GPSSpoof/Helper \
        GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj
git commit -m "feat(helper): apply locations via GPX slots and Xcode menu click in Swift"
```

---

### Task 3: spoof.sh becomes the single entry point (absorbs setup.sh and lib/gpx.sh)

**Files:**
- Rewrite: `spoof.sh`
- Modify: `tests/test_gpx.sh` (lines 4-6: source spoof.sh instead of lib/gpx.sh)
- Delete: `setup.sh`, `lib/gpx.sh`

- [ ] **Step 1: Point test_gpx.sh at spoof.sh (the failing test)**

In `tests/test_gpx.sh`, replace:

```bash
# shellcheck source=../lib/gpx.sh
source "$SCRIPT_DIR/../lib/gpx.sh"
```

with:

```bash
# spoof.sh is sourceable: its execution guard keeps main() from running.
# shellcheck source=../spoof.sh
source "$SCRIPT_DIR/../spoof.sh"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_gpx.sh`
Expected: FAILURE — the current spoof.sh is NOT sourceable: sourcing it executes the arg parser, prints usage, and exits non-zero before any assertion runs. Any non-zero exit / missing "ok" lines counts as the red state.

- [ ] **Step 3: Rewrite `spoof.sh` in full**

Replace the entire file with (keep mode 755):

```bash
#!/usr/bin/env bash
# spoof.sh — single entry point for the GPS spoof toolkit.
#
#   ./spoof.sh setup                                  one-time prereqs + project generation
#   ./spoof.sh --lat <lat> --lon <lon> [options]      stage GPX, hand off to Xcode
#   ./spoof.sh helper [--port N|--dry-run|--probe-menu]  run the phone-control helper
#
# Effect: iPhone reports the spoofed coordinates to all apps (Maps, Find My,
# Snapchat, etc.) once you press Cmd-R in Xcode and unplug USB. Spoof lasts
# until the iPhone reboots.
#
# Why this is split between CLI and Xcode: xcodebuild's headless path cannot
# honor the scheme's `locationScenarioReference` (xcodebuild -list explicitly
# warns it can't deal with `_locationScenarioReference`), and there is no
# documented lldb command on current Xcode versions to inject the GPX into a
# running process. Only Xcode.app's Run action triggers the simulation. So
# this script stages the GPX and opens Xcode for you.
#
# Sourceable: tests/test_gpx.sh sources this file for the GPX functions;
# nothing executes unless the script is run directly (see guard at EOF).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$SCRIPT_DIR/GPSSpoof/GPSSpoof.xcodeproj"
LOCATIONS_DIR="$SCRIPT_DIR/GPSSpoof/GPSSpoof/locations"
HELPER_BIN="$SCRIPT_DIR/build/Release/GPSSpoofHelper"

# ---------------------------------------------------------------------------
# GPX pure functions (formerly lib/gpx.sh)
# ---------------------------------------------------------------------------

# validate_coords <lat> <lon>
# Returns 0 if both are valid decimal numbers in range, non-zero otherwise.
validate_coords() {
  local lat="${1-}"
  local lon="${2-}"
  local num_re='^-?[0-9]+(\.[0-9]+)?$'

  [[ "$lat" =~ $num_re ]] || return 1
  [[ "$lon" =~ $num_re ]] || return 1

  # bash arithmetic can't do floats; use awk for comparisons
  awk -v lat="$lat" -v lon="$lon" '
    BEGIN {
      if (lat < -90 || lat > 90) exit 1
      if (lon < -180 || lon > 180) exit 1
      exit 0
    }
  '
}

# xml_escape <string>  — escapes &, <, >, " for XML text/attributes
xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

# write_gpx <lat> <lon> <name> <out_path>
# Writes a GPX 1.1 file with a single waypoint. Overwrites if present.
write_gpx() {
  local lat="$1"
  local lon="$2"
  local name="$3"
  local out="$4"

  validate_coords "$lat" "$lon" || {
    echo "write_gpx: invalid coords: lat=$lat lon=$lon" >&2
    return 2
  }

  local esc_name
  esc_name=$(xml_escape "$name")

  mkdir -p "$(dirname "$out")"
  cat > "$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="GPSSpoof" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="$lat" lon="$lon">
    <name>$esc_name</name>
  </wpt>
</gpx>
EOF
}

# ---------------------------------------------------------------------------
# setup subcommand (formerly setup.sh) — idempotent, safe to re-run
# ---------------------------------------------------------------------------
cmd_setup() {
  cd "$SCRIPT_DIR"
  echo "Checking prerequisites..."

  # 1. Xcode (not just CLI tools)
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "ERROR: Xcode is not installed or xcode-select points at nothing."
    echo "  Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
  fi
  local xcode_dev
  xcode_dev="$(xcode-select -p)"
  if [[ "$xcode_dev" != *"/Xcode.app/"* ]]; then
    echo "ERROR: xcode-select points at '$xcode_dev', which is the CLI-tools-only path."
    echo "  Install full Xcode and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
  fi
  echo "  ok   - $(xcodebuild -version | head -1)"

  # 2. xcodegen — preferred; project.pbxproj is checked in as fallback
  if command -v xcodegen >/dev/null 2>&1; then
    echo "  ok   - xcodegen $(xcodegen --version 2>&1 | head -1)"
    echo "Regenerating Xcode project from project.yml..."
    # xcodegen wipes xcshareddata/ on regenerate, which would delete our
    # hand-written scheme carrying the GPX location-simulation wiring.
    # Stash it across the generate, then restore.
    local scheme_src="GPSSpoof/GPSSpoof.xcodeproj/xcshareddata/xcschemes/GPSSpoof.xcscheme"
    local scheme_stash=""
    if [[ -f "$scheme_src" ]]; then
      scheme_stash="$(mktemp -t gpsspoof-scheme).xcscheme"
      cp "$scheme_src" "$scheme_stash"
    fi
    ( cd GPSSpoof && TEAM_ID="${TEAM_ID:-}" xcodegen generate )
    if [[ -n "$scheme_stash" ]]; then
      mkdir -p "$(dirname "$scheme_src")"
      mv "$scheme_stash" "$scheme_src"
    fi
    echo "  ok   - project regenerated"
  else
    echo "  warn - xcodegen not installed; using committed project.pbxproj"
    echo "         install with: brew install xcodegen"
  fi

  # 3. TEAM_ID hint
  if [[ -z "${TEAM_ID:-}" ]]; then
    echo ""
    echo "TEAM_ID is not set."
    echo "  Find your team id:"
    echo "    1. Open Xcode > Settings > Accounts, add your Apple ID (free works)."
    echo "    2. Open GPSSpoof/GPSSpoof.xcodeproj > Signing & Capabilities."
    echo "       Pick your Team. Xcode shows the 10-char team id in the dropdown."
    echo "    3. export TEAM_ID=XXXXXXXXXX"
    echo "  Or just open the project once in Xcode and let it auto-sign; spoof.sh will then work without TEAM_ID."
  else
    echo "  ok   - TEAM_ID=$TEAM_ID"
  fi

  echo ""
  echo "Setup complete. Next:"
  echo "  ./spoof.sh --lat 37.3861 --lon -122.0839 --name 'Mountain View'"
}

# ---------------------------------------------------------------------------
# helper subcommand — build + run the Swift phone-control helper
# ---------------------------------------------------------------------------
build_helper() {
  if ! xcodebuild -project "$PROJECT" -target GPSSpoofHelper -configuration Release \
       SYMROOT="$SCRIPT_DIR/build" OBJROOT="$SCRIPT_DIR/build/obj" build -quiet; then
    echo "ERROR: GPSSpoofHelper build failed. Run ./spoof.sh setup and retry." >&2
    return 1
  fi
}

cmd_helper() {
  build_helper || exit 1
  exec "$HELPER_BIN" --locations-dir "$LOCATIONS_DIR" "$@"
}

# ---------------------------------------------------------------------------
# default subcommand — stage the GPX and hand off to Xcode
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage:
  $0 setup
  $0 --lat <lat> --lon <lon> [--name "Label"] [--no-open] [--listen]
  $0 helper [--port <n>] [--dry-run] [--probe-menu]

  setup       one-time prerequisite check + Xcode project generation
              (run as: TEAM_ID=XXXXXXXXXX $0 setup to keep the signing team)
  --lat       latitude  (-90  .. 90)
  --lon       longitude (-180 .. 180)
  --name      optional waypoint label
  --no-open   write GPX and exit; skip the Xcode handoff (used by tests)
  --listen    after the Xcode handoff, build + run the phone-control helper
              (GPSSpoofHelper) in the foreground; Ctrl-C to stop
  helper      run the phone-control helper on its own (e.g. to restart phone
              control for an already-running session); --probe-menu prints
              Xcode's Simulate Location menu items
EOF
}

cmd_spoof() {
  local lat=""
  local lon=""
  local name="Spoofed Location"
  local no_open=0
  local listen=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lat)      lat="${2-}";  shift 2 ;;
      --lon)      lon="${2-}";  shift 2 ;;
      --name)     name="${2-}"; shift 2 ;;
      --no-open)  no_open=1;    shift ;;
      --listen)   listen=1;     shift ;;
      -h|--help)  usage; exit 0 ;;
      *) echo "Unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
  done

  if [[ -z "$lat" || -z "$lon" ]]; then
    usage >&2
    exit 1
  fi

  # --- write GPX (validates coords) ---
  local gpx_path="$LOCATIONS_DIR/target.gpx"
  if ! write_gpx "$lat" "$lon" "$name" "$gpx_path"; then
    echo "ERROR: coords out of range. lat must be -90..90, lon must be -180..180." >&2
    exit 1
  fi
  echo "  ok   - GPX written: $lat, $lon ($name)"

  # --- informational: which iPhone Xcode will likely target ---
  local udid
  udid=$(xcrun xctrace list devices 2>&1 \
         | grep -Ei 'iPhone.*\(([0-9A-Fa-f-]{25,40})\)$' \
         | head -1 \
         | grep -oE '\(([0-9A-Fa-f-]{25,40})\)$' \
         | tr -d '()' \
         || true)
  if [[ -n "$udid" ]]; then
    echo "  ok   - iPhone detected: $udid"
  else
    echo "  note - no iPhone visible to xctrace; plug in and trust the Mac before pressing Cmd-R in Xcode."
  fi

  if [[ "$no_open" == "1" ]]; then
    # --listen is intentionally moot here; --no-open short-circuits before the handoff (test-only flag).
    exit 0
  fi

  cat <<EOF

============================================================
  HANDOFF TO Xcode.app — required to activate GPS spoof
============================================================

  Opening the project now. In Xcode:
    1. Top-left: scheme dropdown should already show 'GPSSpoof'.
       (Not 'GPSSpoofHelper' — that's the Mac-side helper target.)
       Next to it, pick your iPhone as the run destination.
    2. Press Cmd-R to Run.
       - First run: Xcode may prompt for signing (pick your team).
       - First run: Xcode may need to download device-side support
         files; let it finish.
    3. On the iPhone, when the app asks for location access, tap
       'Allow While Using App'. (First run only. This arms the
       background keepalive that survives screen lock.)
    4. Wait until the bottom status bar shows
       'Running GPSSpoof on <device>' and the app displays the
       spoofed coordinates.

  Keeping the session alive:
    - Most stable: leave the USB cable plugged in. A wired session
      does not care about WiFi changes.
    - If you unplug: do NOT press Stop in Xcode. Put the iPhone on
      a charger, keep Mac and iPhone on the same network, and do
      not switch WiFi networks mid-session. (Hotspot users:
      connect the Mac to the iPhone's hotspot BEFORE pressing
      Cmd-R, then stay on it.)
    - Keep the Mac awake (caffeinate -dis, or lid open + power).
    - The blue location indicator on the iPhone is the heartbeat:
      visible = session alive.
    - Want to move the spoofed location later without the Mac?
      Re-run with --listen and enter the printed URL in the app.

  iPhone reports ($lat, $lon) to every app while the session
  holds. The screen can lock; the spoof now survives that.

  Restore real GPS: reboot the iPhone.
EOF

  if [[ "$listen" == "1" ]]; then
    open -a Xcode "$PROJECT"
    echo
    echo "  Starting the phone-control helper. Once the app is running on"
    echo "  the iPhone, enter the URL below on its control screen to change"
    echo "  the location without touching the Mac."
    cmd_helper   # builds if needed, then execs the helper (does not return)
  fi

  exec open -a Xcode "$PROJECT"
}

main() {
  case "${1-}" in
    setup)  shift; cmd_setup "$@" ;;
    helper) shift; cmd_helper "$@" ;;
    *)      cmd_spoof "$@" ;;
  esac
}

# Execution guard: run main only when executed, not when sourced (tests
# source this file to unit-test the GPX functions). set -e stays inside the
# guard so sourcing never mutates the caller's shell options.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
```

- [ ] **Step 4: Delete the absorbed scripts**

```bash
git rm setup.sh lib/gpx.sh
```

- [ ] **Step 5: Syntax-check and run the GPX tests**

```bash
bash -n spoof.sh                 # expect: silence
bash tests/test_gpx.sh           # expect: all ok, exit 0
```

- [ ] **Step 6: Verify the setup subcommand end-to-end**

```bash
TEAM_ID=ZV4B6559W7 ./spoof.sh setup
# expect: "ok - project regenerated", "ok - TEAM_ID=ZV4B6559W7"
grep -c 'ZV4B6559W7' GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj   # expect >= 1
git diff --stat GPSSpoof/GPSSpoof.xcodeproj/xcshareddata/           # expect EMPTY
git checkout -- GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj 2>/dev/null || true
# (regen output should be identical to the committed pbxproj; the checkout is
#  a no-op safety reset either way)
```

- [ ] **Step 7: Verify the remaining flows**

```bash
./spoof.sh --help | grep -E 'setup|helper|--listen'   # expect all three present
./spoof.sh --lat 37.3861 --lon -122.0839 --name "MV" --no-open && echo PASS
bash tests/test_helper.sh                              # expect: all ok
bash tests/test_integration.sh                         # expect: all ok
git checkout -- GPSSpoof/GPSSpoof/locations/target.gpx
```

Do NOT run `./spoof.sh helper` or `--probe-menu` here — it would trigger macOS permission prompts; the menu path gets verified manually in the final task.

- [ ] **Step 8: Commit**

```bash
git add spoof.sh tests/test_gpx.sh
git rm --cached setup.sh lib/gpx.sh 2>/dev/null || true
git commit -m "feat(cli): collapse setup.sh and lib/gpx.sh into single-entry spoof.sh"
```

(If Step 4's `git rm` already staged the deletions, the `git rm --cached` is a harmless no-op.)

---

### Task 4: Remove the Python helper; update integration checks

**Files:**
- Delete: `lib/location_helper.py`, `tests/test_helper.py` (and the now-empty `lib/`)
- Modify: `tests/test_integration.sh` (checks #7, #8; new #11)
- Modify: `.gitignore` (drop the `__pycache__` block)

- [ ] **Step 1: Update the integration suite first (the failing test)**

In `tests/test_integration.sh`:

(a) Replace check #7:

```bash
# 7. Mac-side helper unit tests (dry-run; no Xcode or device involved).
python3 "$ROOT/tests/test_helper.py" >/dev/null 2>&1 \
  && echo "  ok   - location_helper unit tests" || { echo "  FAIL - location_helper unit tests"; FAILED=1; }
```

with:

```bash
# 7. Mac-side helper black-box tests (builds GPSSpoofHelper, dry-run only).
bash "$ROOT/tests/test_helper.sh" >/dev/null 2>&1 \
  && echo "  ok   - helper black-box tests" || { echo "  FAIL - helper black-box tests"; FAILED=1; }
```

(b) Replace check #8:

```bash
# 8. spoof.sh advertises --listen.
"$ROOT/spoof.sh" --help 2>&1 | grep -q -- '--listen' \
  && echo "  ok   - spoof.sh --help mentions --listen" || { echo "  FAIL - --listen missing from usage"; FAILED=1; }
```

with:

```bash
# 8. spoof.sh is the single entry point: --listen plus both subcommands.
HELP_OUT="$("$ROOT/spoof.sh" --help 2>&1)"
echo "$HELP_OUT" | grep -q -- '--listen' \
  && echo "  ok   - spoof.sh --help mentions --listen" || { echo "  FAIL - --listen missing from usage"; FAILED=1; }
echo "$HELP_OUT" | grep -qE '^[[:space:]]*setup[[:space:]]' \
  && echo "  ok   - spoof.sh --help mentions setup" || { echo "  FAIL - setup missing from usage"; FAILED=1; }
echo "$HELP_OUT" | grep -qE '^[[:space:]]*helper[[:space:]]' \
  && echo "  ok   - spoof.sh --help mentions helper" || { echo "  FAIL - helper missing from usage"; FAILED=1; }
```

(c) Append a new check #11 immediately before the final `exit "$FAILED"` line:

```bash
# 11. The Swift helper is bundled in the Xcode project and Python is gone.
grep -q 'GPSSpoofHelper' "$ROOT/GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj" \
  && echo "  ok   - GPSSpoofHelper target in pbxproj" || { echo "  FAIL - GPSSpoofHelper missing from pbxproj"; FAILED=1; }
[[ -f "$ROOT/GPSSpoof/Helper/main.swift" ]] \
  && echo "  ok   - helper sources present" || { echo "  FAIL - GPSSpoof/Helper/main.swift missing"; FAILED=1; }
[[ ! -e "$ROOT/lib" ]] \
  && echo "  ok   - lib/ retired (logic lives in spoof.sh + GPSSpoof/Helper/)" || { echo "  FAIL - stale lib/ still present"; FAILED=1; }
[[ ! -e "$ROOT/setup.sh" ]] \
  && echo "  ok   - setup.sh absorbed into spoof.sh" || { echo "  FAIL - setup.sh still present"; FAILED=1; }
```

- [ ] **Step 2: Run it to verify the new checks fail**

Run: `bash tests/test_integration.sh; git checkout -- GPSSpoof/GPSSpoof/locations/target.gpx`
Expected: `FAIL - stale lib/ still present` (lib/location_helper.py still exists). Everything else ok. Exit non-zero.

- [ ] **Step 3: Delete the Python helper and its tests**

```bash
git rm lib/location_helper.py tests/test_helper.py
rmdir lib 2>/dev/null || true
```

- [ ] **Step 4: Drop the Python block from `.gitignore`**

Remove these two lines (keep everything else, including the target.gpx comment block below them):

```
# Python bytecode (lib/location_helper.py)
__pycache__/
```

- [ ] **Step 5: Run the full suite to verify green**

```bash
bash tests/test_gpx.sh           # expect: all ok
bash tests/test_helper.sh        # expect: all ok
bash tests/test_integration.sh   # expect: all ok, exit 0
git checkout -- GPSSpoof/GPSSpoof/locations/target.gpx
git status --short               # expect: only staged deletions + modified files, no stray artifacts
```

- [ ] **Step 6: Commit**

```bash
git add tests/test_integration.sh .gitignore
git commit -m "chore: retire the Python helper — the Swift binary owns phone control"
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the First-time setup section**

Replace the section body (currently a `./setup.sh` code block plus the paragraph about Xcode and TEAM_ID export) with:

````markdown
```bash
./spoof.sh setup
```

Then open `GPSSpoof/GPSSpoof.xcodeproj` in Xcode once. Select your team under Signing & Capabilities to complete the device signing process. Copy the 10-character Team ID and run:

```bash
export TEAM_ID=XXXXXXXXXX
```

(Add this to your shell profile. Re-runs of `./spoof.sh setup` regenerate the Xcode project, and the signing team is only preserved when TEAM_ID is set.)
````

- [ ] **Step 2: Update the "Changing the location from the phone" section**

Replace the paragraphs that mention `lib/location_helper.py` so the section reads:

````markdown
Once the debug session is running, you can move the spoofed location from the
iPhone itself — no Mac interaction needed beyond initial setup.

Start the session with the helper:

```bash
./spoof.sh --lat 37.3861 --lon -122.0839 --listen
```

`--listen` opens Xcode as usual, then builds and runs `GPSSpoofHelper` — a
small Swift command-line tool that lives in the same Xcode project — in the
foreground. The helper prints a URL like `http://192.168.1.20:8755` — enter
it once in the GPSSpoof app on the phone (it is remembered). Type new
coordinates and tap **Apply location**: the helper writes them into one of
two alternating GPX slots (`live_a.gpx` / `live_b.gpx`) and clicks
**Debug ▸ Simulate Location** in Xcode for you, so the running session
re-reads the file. Two slots are used because Xcode caches a re-selected GPX
file.

One-time Mac setup: grant **Accessibility** permission to the terminal app
running the helper (System Settings ▸ Privacy & Security ▸ Accessibility).
The helper returns a clear error to the phone if the permission is missing.

Notes:
- Each Apply briefly brings Xcode to the front on the Mac.
- The first Apply triggers iOS's one-time **Local Network** permission prompt
  on the phone — allow it.
- Stopping the helper (Ctrl-C) does not end the spoof session; it only stops
  phone control. Run `./spoof.sh helper` to get it back.
- If the helper reports a missing menu item, run
  `./spoof.sh helper --probe-menu` to see the names Xcode actually shows,
  and check that a debug session is running.
````

- [ ] **Step 3: Update the Tests section**

Replace the code block and trailing sentence with:

````markdown
```bash
bash tests/test_gpx.sh           # GPX shell functions (sourced from spoof.sh)
bash tests/test_helper.sh        # Swift helper, black-box over loopback HTTP
bash tests/test_integration.sh   # end-to-end smoke checks
```

These tests run without a physical device. `test_helper.sh` and
`test_integration.sh` build the `GPSSpoofHelper` target on first run.
````

- [ ] **Step 4: Update the Project layout section**

Replace the layout code block with:

```
spoof.sh                                 # Single entry point: setup | spoof | helper
tests/                                   # Test scripts
GPSSpoof/project.yml                     # xcodegen configuration (both targets)
GPSSpoof/GPSSpoof.xcodeproj/             # Generated project
GPSSpoof/Helper/                         # GPSSpoofHelper: Mac-side phone-control
                                         #   helper (Swift command-line tool)
GPSSpoof/GPSSpoof/AppDelegate.swift      # Minimal iOS app
GPSSpoof/GPSSpoof/ControlViewController.swift  # Phone-side control UI
GPSSpoof/GPSSpoof/Info.plist
GPSSpoof/GPSSpoof/locations/target.gpx   # GPX file updated per run
GPSSpoof/GPSSpoof/locations/live_a.gpx   # Alternating live slots rewritten by
GPSSpoof/GPSSpoof/locations/live_b.gpx   #   the helper during phone control
```

- [ ] **Step 5: Sweep for stale references**

```bash
grep -rn 'location_helper\|setup\.sh\|lib/gpx' README.md
```

Expected: no matches (fix any stragglers — e.g. the Prerequisites table and Usage section must not reference setup.sh or Python).

- [ ] **Step 6: Run the full suite one last time**

```bash
bash tests/test_gpx.sh && bash tests/test_helper.sh && bash tests/test_integration.sh
git checkout -- GPSSpoof/GPSSpoof/locations/target.gpx
```

Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add README.md
git commit -m "docs: single-entry spoof.sh and the Swift helper"
```

---

### Task 6: Manual end-to-end verification (USER — needs the physical iPhone)

Not automatable. Supersedes the previous plan's Task 8 (same steps, new commands):

1. `./spoof.sh --lat 37.3861 --lon -122.0839 --listen`; Cmd-R in Xcode (scheme `GPSSpoof`, not `GPSSpoofHelper`); accept the location prompt on the phone.
2. In a second terminal: `./spoof.sh helper --probe-menu`. If the menu names differ from `live_a` / `live_b` (e.g. they include `.gpx`), update `GPX.slots` in `GPSSpoof/Helper/GPX.swift` and the slot-name assertions in `tests/test_helper.sh` + `tests/test_integration.sh`, rebuild, commit.
3. On the phone: enter the printed URL, apply `40.7580, -73.9855`, accept the Local Network prompt. Maps' blue dot should move to Times Square.
4. Apply a second location — response should report slot `live_b`.
5. Lock the phone 2 minutes, unlock, apply again — should still work.
6. Ctrl-C the helper — the spoof session must survive. `./spoof.sh helper` brings phone control back.
