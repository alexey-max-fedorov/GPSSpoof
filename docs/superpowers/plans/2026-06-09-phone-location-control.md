# Phone-Controlled Location Switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user change the spoofed GPS coordinates from the GPSSpoof iPhone app while the Xcode debug session is running, without touching the Mac.

**Architecture:** The iPhone app gains a small control form (helper URL + lat/lon + Apply) that POSTs JSON to a Python helper running on the Mac. The helper writes the coordinates into one of two alternating "live slot" GPX files (`live_a.gpx`/`live_b.gpx`, both registered in the Xcode project graph) and then UI-scripts Xcode via `osascript`/System Events to click **Debug ▸ Simulate Location ▸ \<slot\>**, which makes Xcode re-read the file and re-point the running simulation. Two slots are alternated because Xcode caches a re-selected GPX; clicking a *different* menu item forces a re-read. Everything stays tied to the standard Xcode debug Run action — no new simulation mechanism, no private APIs, free Apple ID signing intact.

**Tech Stack:** Python 3 stdlib (`http.server`, `subprocess`) for the Mac helper; AppleScript via `osascript` for the Xcode menu click; UIKit + `URLSession` on the phone; bash for `spoof.sh --listen`; `unittest` (Python) and the existing bash test suites.

**Key constraints honored:**
- Free Apple ID signing (only plain Info.plist keys added: ATS local networking + local-network usage description).
- No jailbreak, no private APIs.
- Simulation remains driven by Xcode's standard debug Run action.
- The shared scheme file is NOT modified (it is the most fragile artifact in this repo — Xcode 26 rewrites it, and setup.sh stashes it across xcodegen runs).

**Known operational requirements (document, don't fight):**
- The terminal app running the helper needs macOS **Accessibility** permission (System Settings ▸ Privacy & Security ▸ Accessibility) for System Events UI scripting.
- Each Apply briefly brings Xcode frontmost on the Mac (side effect of `set frontmost to true`).
- Phone and Mac must be on the same network — already a requirement of the wireless debug session itself.

**File map (what's created/modified and why):**

| File | Action | Responsibility |
| ---- | ------ | -------------- |
| `GPSSpoof/GPSSpoof/locations/live_a.gpx`, `live_b.gpx` | Create | Alternating mid-session location slots; must be in the project graph to appear in Xcode's Simulate Location menu |
| `lib/location_helper.py` | Create | Mac-side helper: validation, GPX writing, osascript trigger, HTTP server, CLI |
| `tests/test_helper.py` | Create | Python unit tests for the helper (pure functions + HTTP in dry-run mode) |
| `GPSSpoof/GPSSpoof/ControlViewController.swift` | Create | Phone UI: keepalive status display + control form + POST to helper |
| `GPSSpoof/GPSSpoof/AppDelegate.swift` | Modify | Swap root VC to ControlViewController; route keepalive status into it |
| `GPSSpoof/project.yml` + `GPSSpoof/GPSSpoof/Info.plist` | Modify (both, kept in sync) | ATS `NSAllowsLocalNetworking`, `NSLocalNetworkUsageDescription` |
| `GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj` | Regenerate via `./setup.sh` | Picks up the new .gpx and .swift files |
| `spoof.sh` | Modify | `--listen` flag: stage GPX, open Xcode, then run the helper in the foreground |
| `tests/test_integration.sh` | Modify | New checks for slots, plist keys, pbxproj membership, helper tests |
| `README.md` | Modify | "Changing the location from the phone" section + troubleshooting |

**API contract (used by Tasks 3 and 7 — must match exactly):**
- `POST /location` with body `{"lat": <number>, "lon": <number>}` → `200 {"ok": true, "slot": "live_a"}` on success; `400` invalid input; `409` no usable Xcode menu item (no debug session); `403` Accessibility permission missing; error bodies are `{"ok": false, "error": "<human-readable message>"}`.
- `GET /health` → `200 {"ok": true, "slot": "<last applied slot or live_b initially>"}`.
- Default port: **8755**.

---

### Task 1: Live-slot GPX files in the project graph

The Simulate Location menu only lists GPX files that are part of the workspace (precedent: commit 327da27 had to add `target.gpx` to the project graph before Xcode honored it). xcodegen includes everything under `GPSSpoof/GPSSpoof/` as sources, so creating the files and regenerating is enough.

**Files:**
- Create: `GPSSpoof/GPSSpoof/locations/live_a.gpx`
- Create: `GPSSpoof/GPSSpoof/locations/live_b.gpx`
- Regenerate: `GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj` (via `./setup.sh`)
- Test: `tests/test_integration.sh`

- [ ] **Step 1: Add failing integration checks**

Append to `tests/test_integration.sh` immediately before the final `exit "$FAILED"` line:

```bash
# 6. Live-slot GPX files exist, are well-formed, and are in the project graph
# (Xcode's Simulate Location menu only lists workspace GPX files).
for SLOT in live_a live_b; do
  SLOT_GPX="$ROOT/GPSSpoof/GPSSpoof/locations/$SLOT.gpx"
  assert_ok "$SLOT.gpx is well-formed" xmllint --noout "$SLOT_GPX"
  grep -q "$SLOT.gpx" "$ROOT/GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj" \
    && echo "  ok   - $SLOT.gpx in project graph" || { echo "  FAIL - $SLOT.gpx missing from pbxproj"; FAILED=1; }
done
```

- [ ] **Step 2: Run the integration suite to verify the new checks fail**

Run: `bash tests/test_integration.sh`
Expected: the four new checks FAIL (`live_a.gpx is well-formed`, `live_a.gpx in project graph`, same for `live_b`); all pre-existing checks still pass.

- [ ] **Step 3: Create the slot files**

Write `GPSSpoof/GPSSpoof/locations/live_a.gpx` (note: the waypoint `<name>` equals the slot name on purpose — Xcode's menu labels GPX entries by file name in current versions, but has used the waypoint name in others; making them identical means the AppleScript menu match works either way):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="GPSSpoof" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="0" lon="0">
    <name>live_a</name>
  </wpt>
</gpx>
```

Write `GPSSpoof/GPSSpoof/locations/live_b.gpx`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="GPSSpoof" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="0" lon="0">
    <name>live_b</name>
  </wpt>
</gpx>
```

(The 0,0 placeholders are never simulated — the helper overwrites a slot before ever selecting it.)

- [ ] **Step 4: Regenerate the project**

Run: `./setup.sh`
Expected: `ok   - project regenerated` (setup.sh stashes and restores the hand-written scheme across the xcodegen run — do NOT run raw `xcodegen generate`).

Then confirm: `grep -c 'live_[ab].gpx' GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj`
Expected: a non-zero count (each file appears in PBXFileReference and group sections).

- [ ] **Step 5: Run the integration suite to verify it passes**

Run: `bash tests/test_integration.sh`
Expected: all checks pass, exit 0.

Note: the suite's earlier steps overwrite `locations/target.gpx` with test coordinates. Restore it before committing: `git checkout -- GPSSpoof/GPSSpoof/locations/target.gpx`

- [ ] **Step 6: Commit**

```bash
git add GPSSpoof/GPSSpoof/locations/live_a.gpx GPSSpoof/GPSSpoof/locations/live_b.gpx \
        GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj tests/test_integration.sh
git commit -m "feat(control): add alternating live-slot GPX files to project graph"
```

---

### Task 2: Helper pure functions (validate, GPX generation, slot toggle)

**Files:**
- Create: `lib/location_helper.py`
- Create: `tests/test_helper.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_helper.py`:

```python
#!/usr/bin/env python3
"""Unit tests for lib/location_helper.py. No device, no Xcode, no network
permissions needed: the HTTP tests (added in Task 3) run the server in
dry-run mode on a loopback ephemeral port."""
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import location_helper as lh


class TestValidate(unittest.TestCase):
    def test_valid_floats(self):
        self.assertEqual(lh.validate(37.3861, -122.0839), (37.3861, -122.0839))

    def test_valid_strings_coerced(self):
        self.assertEqual(lh.validate("45.5", "-120"), (45.5, -120.0))

    def test_boundaries(self):
        self.assertEqual(lh.validate(90, 180), (90.0, 180.0))
        self.assertEqual(lh.validate(-90, -180), (-90.0, -180.0))

    def test_out_of_range(self):
        self.assertIsNone(lh.validate(90.1, 0))
        self.assertIsNone(lh.validate(-90.1, 0))
        self.assertIsNone(lh.validate(0, 180.1))
        self.assertIsNone(lh.validate(0, -180.1))

    def test_garbage(self):
        self.assertIsNone(lh.validate("abc", 0))
        self.assertIsNone(lh.validate(None, None))
        self.assertIsNone(lh.validate("1; rm -rf /", 0))


class TestMakeGpx(unittest.TestCase):
    def test_round_trip(self):
        xml = lh.make_gpx(37.3861, -122.0839, "live_a")
        root = ET.fromstring(xml)
        ns = {"g": "http://www.topografix.com/GPX/1/1"}
        wpt = root.find("g:wpt", ns)
        self.assertEqual(wpt.get("lat"), "37.3861")
        self.assertEqual(wpt.get("lon"), "-122.0839")
        self.assertEqual(wpt.find("g:name", ns).text, "live_a")

    def test_integer_coords(self):
        root = ET.fromstring(lh.make_gpx(45.0, -120.0, "live_b"))
        ns = {"g": "http://www.topografix.com/GPX/1/1"}
        self.assertEqual(root.find("g:wpt", ns).get("lat"), "45.0")


class TestSlots(unittest.TestCase):
    def test_toggle(self):
        self.assertEqual(lh.next_slot("live_a"), "live_b")
        self.assertEqual(lh.next_slot("live_b"), "live_a")


if __name__ == "__main__":
    unittest.main(verbosity=2)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 tests/test_helper.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'location_helper'`

- [ ] **Step 3: Implement the pure functions**

Create `lib/location_helper.py`:

```python
#!/usr/bin/env python3
"""GPSSpoof phone-control helper.

Listens for HTTP POSTs from the GPSSpoof iPhone app and re-points Xcode's
*running* location simulation at new coordinates by:
  1. writing the coords into the next "live slot" GPX file
     (GPSSpoof/GPSSpoof/locations/live_a.gpx / live_b.gpx), and
  2. UI-scripting Xcode (Debug > Simulate Location > <slot>) via osascript.

Two slots are alternated because Xcode caches a re-selected GPX; picking a
*different* menu item forces a re-read.

Requires macOS Accessibility permission for the terminal app running this
script (System Settings > Privacy & Security > Accessibility). Each apply
briefly brings Xcode frontmost.

Usage:
  python3 lib/location_helper.py [--port 8755] [--dry-run]
  python3 lib/location_helper.py --probe-menu

Python 3 stdlib only; no third-party dependencies.
"""
import argparse
import json
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCATIONS_DIR = ROOT / "GPSSpoof" / "GPSSpoof" / "locations"
SLOTS = ("live_a", "live_b")
DEFAULT_PORT = 8755


def validate(lat, lon):
    """Return (lat, lon) as floats if both are in range, else None."""
    try:
        lat, lon = float(lat), float(lon)
    except (TypeError, ValueError):
        return None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None
    return lat, lon


def make_gpx(lat, lon, name):
    """Single-waypoint GPX 1.1, same shape lib/gpx.sh writes. The waypoint
    name must equal the slot name: Xcode's Simulate Location menu has labeled
    GPX entries by file name in some versions and by waypoint name in others,
    and keeping them identical makes the menu click work either way."""
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<gpx version="1.1" creator="GPSSpoof" '
        'xmlns="http://www.topografix.com/GPX/1/1">\n'
        f'  <wpt lat="{lat}" lon="{lon}">\n'
        f'    <name>{name}</name>\n'
        '  </wpt>\n'
        '</gpx>\n'
    )


def next_slot(current):
    return SLOTS[(SLOTS.index(current) + 1) % len(SLOTS)]
```

(The HTTP server, osascript trigger, and CLI are added in Task 3 — this file grows in place.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 tests/test_helper.py`
Expected: all tests PASS (`OK`).

- [ ] **Step 5: Commit**

```bash
git add lib/location_helper.py tests/test_helper.py
git commit -m "feat(control): helper pure functions — validation, GPX, slot toggle"
```

---

### Task 3: Helper HTTP server, osascript trigger, and CLI

**Files:**
- Modify: `lib/location_helper.py` (append server + trigger + CLI below the Task 2 functions)
- Modify: `tests/test_helper.py` (append server tests)

- [ ] **Step 1: Write the failing server tests**

Append to `tests/test_helper.py` (above the `if __name__ == "__main__":` block):

```python
import json
import tempfile
import threading
import urllib.error
import urllib.request


class TestServer(unittest.TestCase):
    """Exercises the HTTP layer with dry_run=True (no osascript, no Xcode)
    and a temp locations dir (repo files untouched)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.server = lh.HelperServer(
            ("127.0.0.1", 0), dry_run=True, locations_dir=Path(self.tmp.name)
        )
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def _post(self, payload):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/location",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_health(self):
        with urllib.request.urlopen(
            f"http://127.0.0.1:{self.port}/health", timeout=5
        ) as resp:
            self.assertEqual(resp.status, 200)
            self.assertTrue(json.loads(resp.read())["ok"])

    def test_apply_alternates_slots_and_writes_gpx(self):
        status, body = self._post({"lat": 37.3861, "lon": -122.0839})
        self.assertEqual(status, 200)
        self.assertEqual(body["slot"], "live_a")
        gpx = (Path(self.tmp.name) / "live_a.gpx").read_text()
        self.assertIn('lat="37.3861"', gpx)

        status, body = self._post({"lat": 45.0, "lon": -120.0})
        self.assertEqual(status, 200)
        self.assertEqual(body["slot"], "live_b")
        self.assertTrue((Path(self.tmp.name) / "live_b.gpx").exists())

    def test_rejects_out_of_range(self):
        status, body = self._post({"lat": 999, "lon": 0})
        self.assertEqual(status, 400)
        self.assertFalse(body["ok"])

    def test_rejects_bad_json(self):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/location",
            data=b"not json",
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                status = resp.status
        except urllib.error.HTTPError as e:
            status = e.code
        self.assertEqual(status, 400)

    def test_unknown_path_404(self):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{self.port}/nope", timeout=5)
            self.fail("expected 404")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 404)
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `python3 tests/test_helper.py`
Expected: Task 2 tests still PASS; `TestServer` tests FAIL with `AttributeError: module 'location_helper' has no attribute 'HelperServer'`.

- [ ] **Step 3: Implement server, trigger, and CLI**

Append to `lib/location_helper.py`:

```python
# --- Xcode trigger -----------------------------------------------------------

def applescript_click(slot):
    return f'''
tell application "System Events"
  tell process "Xcode"
    set frontmost to true
    click menu item "{slot}" of menu 1 of menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
  end tell
end tell'''


APPLESCRIPT_PROBE = '''
tell application "System Events"
  tell process "Xcode"
    set frontmost to true
    get name of every menu item of menu 1 of menu item "Simulate Location" of menu 1 of menu bar item "Debug" of menu bar 1
  end tell
end tell'''


def click_simulate_location(slot):
    """Click Debug > Simulate Location > <slot> in Xcode.
    Returns (http_status, error_message) on failure, or None on success."""
    proc = subprocess.run(
        ["osascript", "-e", applescript_click(slot)],
        capture_output=True, text=True,
    )
    if proc.returncode == 0:
        return None
    err = proc.stderr.strip()
    if "assistive access" in err:
        return (403,
                "macOS blocked UI scripting. Grant Accessibility permission to "
                "the terminal app running this helper (System Settings > "
                "Privacy & Security > Accessibility), then tap Apply again.")
    if "menu item" in err.lower():
        return (409,
                f"Xcode has no 'Simulate Location > {slot}' menu item. Is the "
                "debug session running? On the Mac, run "
                "'python3 lib/location_helper.py --probe-menu' to see what "
                "Xcode actually lists.")
    return (502, f"osascript failed: {err}")


# --- HTTP server -------------------------------------------------------------

class HelperServer(HTTPServer):
    def __init__(self, addr, dry_run=False, locations_dir=LOCATIONS_DIR):
        super().__init__(addr, Handler)
        self.dry_run = dry_run
        self.locations_dir = Path(locations_dir)
        self.slot = SLOTS[-1]  # first apply lands on SLOTS[0]

    def apply_location(self, lat, lon):
        """Returns (http_status, body_dict)."""
        slot = next_slot(self.slot)
        (self.locations_dir / f"{slot}.gpx").write_text(make_gpx(lat, lon, slot))
        if not self.dry_run:
            failure = click_simulate_location(slot)
            if failure:
                status, message = failure
                return status, {"ok": False, "error": message}
        self.slot = slot
        return 200, {"ok": True, "slot": slot}


class Handler(BaseHTTPRequestHandler):
    server_version = "GPSSpoofHelper/1.0"

    def log_message(self, fmt, *args):
        print(f"  {self.address_string()} {fmt % args}")

    def _reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, {"ok": True, "slot": self.server.slot})
        else:
            self._reply(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if self.path != "/location":
            self._reply(404, {"ok": False, "error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            self._reply(400, {"ok": False, "error": "body must be JSON: {\"lat\": .., \"lon\": ..}"})
            return
        coords = validate(payload.get("lat"), payload.get("lon"))
        if coords is None:
            self._reply(400, {"ok": False, "error": "lat must be -90..90, lon -180..180"})
            return
        status, body = self.server.apply_location(*coords)
        if body.get("ok"):
            print(f"  ok   - applied {coords[0]}, {coords[1]} via {body['slot']}")
        else:
            print(f"  FAIL - {body['error']}")
        self._reply(status, body)


# --- CLI ---------------------------------------------------------------------

def lan_ip():
    """Best-effort LAN IP for the startup banner (no traffic is sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("1.1.1.1", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--dry-run", action="store_true",
                        help="write GPX but skip the Xcode menu click")
    parser.add_argument("--probe-menu", action="store_true",
                        help="print Xcode's Simulate Location menu items and exit")
    args = parser.parse_args(argv)

    if args.probe_menu:
        proc = subprocess.run(["osascript", "-e", APPLESCRIPT_PROBE],
                              capture_output=True, text=True)
        print(proc.stdout.strip() or proc.stderr.strip())
        return proc.returncode

    server = HelperServer(("0.0.0.0", args.port), dry_run=args.dry_run)
    url = f"http://{lan_ip()}:{args.port}"
    print("=" * 60)
    print("  GPSSpoof phone-control helper")
    print(f"  Enter this URL in the GPSSpoof app on the iPhone:")
    print(f"    {url}")
    print("  Requires Accessibility permission for this terminal app")
    print("  (System Settings > Privacy & Security > Accessibility).")
    print("  Ctrl-C to stop. Stopping does NOT end the spoof session.")
    print("=" * 60)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
```

Note: `HelperServer.__init__` references `Handler`, which is defined after it in the file. That is fine — the name is resolved at call time, and `main()`/tests construct the server after the module fully loads.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 tests/test_helper.py`
Expected: all tests PASS (`OK`).

- [ ] **Step 5: Smoke-test the CLI in dry-run mode**

```bash
python3 lib/location_helper.py --dry-run --port 8756 &
HELPER_PID=$!
sleep 1
curl -s -X POST http://127.0.0.1:8756/location -d '{"lat": 37.4, "lon": -122.0}'
curl -s http://127.0.0.1:8756/health
kill $HELPER_PID
git checkout -- GPSSpoof/GPSSpoof/locations/  # dry-run wrote into the real slots
```

Expected: first curl prints `{"ok": true, "slot": "live_a"}`, second prints `{"ok": true, "slot": "live_a"}`.

- [ ] **Step 6: Hook the Python tests into the integration suite**

Append to `tests/test_integration.sh` before `exit "$FAILED"`:

```bash
# 7. Mac-side helper unit tests (dry-run; no Xcode or device involved).
python3 "$ROOT/tests/test_helper.py" >/dev/null 2>&1 \
  && echo "  ok   - location_helper unit tests" || { echo "  FAIL - location_helper unit tests"; FAILED=1; }
```

Run: `bash tests/test_integration.sh` — Expected: all checks pass.
Then: `git checkout -- GPSSpoof/GPSSpoof/locations/target.gpx`

- [ ] **Step 7: Commit**

```bash
git add lib/location_helper.py tests/test_helper.py tests/test_integration.sh
git commit -m "feat(control): helper HTTP server + Xcode Simulate Location trigger"
```

---

### Task 4: `spoof.sh --listen`

**Files:**
- Modify: `spoof.sh`
- Modify: `tests/test_integration.sh`

- [ ] **Step 1: Add a failing usage check**

Append to `tests/test_integration.sh` before `exit "$FAILED"`:

```bash
# 8. spoof.sh advertises --listen.
"$ROOT/spoof.sh" --help 2>&1 | grep -q -- '--listen' \
  && echo "  ok   - spoof.sh --help mentions --listen" || { echo "  FAIL - --listen missing from usage"; FAILED=1; }
```

Run: `bash tests/test_integration.sh` — Expected: only the new check FAILs.

- [ ] **Step 2: Implement the flag**

In `spoof.sh`, make these four edits:

(a) Add to the variable block (after `NO_OPEN=0`):

```bash
LISTEN=0
```

(b) Add to the `usage()` heredoc after the `--no-open` line:

```
  --listen    after the Xcode handoff, run the phone-control helper
              (lib/location_helper.py) in the foreground; Ctrl-C to stop
```

(c) Add to the arg-parsing `case` (before the `-h|--help` arm):

```bash
    --listen)   LISTEN=1;     shift ;;
```

(d) Replace the final line `exec open -a Xcode "$SCRIPT_DIR/GPSSpoof/GPSSpoof.xcodeproj"` with:

```bash
if [[ "$LISTEN" == "1" ]]; then
  open -a Xcode "$SCRIPT_DIR/GPSSpoof/GPSSpoof.xcodeproj"
  echo ""
  echo "  Starting the phone-control helper. Once the app is running on"
  echo "  the iPhone, enter the URL below on its control screen to change"
  echo "  the location without touching the Mac."
  exec python3 "$SCRIPT_DIR/lib/location_helper.py"
fi

exec open -a Xcode "$SCRIPT_DIR/GPSSpoof/GPSSpoof.xcodeproj"
```

- [ ] **Step 3: Run the integration suite to verify it passes**

Run: `bash tests/test_integration.sh`
Expected: all checks pass. Then: `git checkout -- GPSSpoof/GPSSpoof/locations/target.gpx`

- [ ] **Step 4: Commit**

```bash
git add spoof.sh tests/test_integration.sh
git commit -m "feat(control): spoof.sh --listen runs the phone-control helper"
```

---

### Task 5: Networking Info.plist keys (ATS + local network)

The app makes cleartext HTTP requests to a LAN IP. Two plain plist keys are required (both free-signing compatible): `NSAppTransportSecurity > NSAllowsLocalNetworking` (ATS exemption for local hosts) and `NSLocalNetworkUsageDescription` (iOS 14+ Local Network privacy prompt — iOS shows it the first time the app touches a LAN address).

**Files:**
- Modify: `GPSSpoof/project.yml`
- Modify: `GPSSpoof/GPSSpoof/Info.plist`
- Modify: `tests/test_integration.sh`

- [ ] **Step 1: Add failing integration checks**

Append to `tests/test_integration.sh` before `exit "$FAILED"`:

```bash
# 9. Networking plist keys for the phone-control channel.
PLIST="$ROOT/GPSSpoof/GPSSpoof/Info.plist"
xmllint --xpath '//key[text()="NSAppTransportSecurity"]/following-sibling::dict[1]/key[text()="NSAllowsLocalNetworking"]' "$PLIST" >/dev/null 2>&1 \
  && echo "  ok   - ATS allows local networking" || { echo "  FAIL - NSAllowsLocalNetworking missing"; FAILED=1; }
grep -q 'NSLocalNetworkUsageDescription' "$PLIST" \
  && echo "  ok   - local-network usage description" || { echo "  FAIL - NSLocalNetworkUsageDescription missing"; FAILED=1; }
grep -q 'NSAllowsLocalNetworking' "$ROOT/GPSSpoof/project.yml" \
  && echo "  ok   - project.yml carries networking keys" || { echo "  FAIL - project.yml missing networking keys (xcodegen regen would drop them)"; FAILED=1; }
```

Run: `bash tests/test_integration.sh` — Expected: the three new checks FAIL.

- [ ] **Step 2: Add the keys to project.yml**

In `GPSSpoof/project.yml`, append under `info.properties` (after the `NSLocationWhenInUseUsageDescription` line, same indentation):

```yaml
        # Phone-control channel: the app POSTs cleartext HTTP to the helper
        # on the Mac's LAN IP. Both keys are plain plist entries.
        NSAppTransportSecurity:
          NSAllowsLocalNetworking: true
        NSLocalNetworkUsageDescription: Sends new spoof coordinates to the helper running on your Mac.
```

- [ ] **Step 3: Add the same keys to Info.plist**

In `GPSSpoof/GPSSpoof/Info.plist`, insert before the closing `</dict>`:

```xml
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Sends new spoof coordinates to the helper running on your Mac.</string>
```

- [ ] **Step 4: Verify plist syntax and the yml round-trip**

```bash
plutil -lint GPSSpoof/GPSSpoof/Info.plist
./setup.sh
plutil -lint GPSSpoof/GPSSpoof/Info.plist
git diff --stat GPSSpoof/GPSSpoof/Info.plist
```

Expected: both lints `OK`; after regeneration the plist still contains all keys (xcodegen regenerates Info.plist from project.yml, so a content-equivalent rewrite is fine — re-run step 1's checks if the diff looks surprising).

- [ ] **Step 5: Run the integration suite to verify it passes**

Run: `bash tests/test_integration.sh`
Expected: all checks pass. Then: `git checkout -- GPSSpoof/GPSSpoof/locations/target.gpx`

- [ ] **Step 6: Commit**

```bash
git add GPSSpoof/project.yml GPSSpoof/GPSSpoof/Info.plist \
        GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj tests/test_integration.sh
git commit -m "feat(control): ATS local-networking + local-network usage plist keys"
```

---

### Task 6: ControlViewController + AppDelegate wiring

**Files:**
- Create: `GPSSpoof/GPSSpoof/ControlViewController.swift`
- Modify: `GPSSpoof/GPSSpoof/AppDelegate.swift`
- Regenerate: `GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj` (new source file)
- Modify: `tests/test_integration.sh`

- [ ] **Step 1: Add failing integration checks**

Append to `tests/test_integration.sh` before `exit "$FAILED"`:

```bash
# 10. Phone-side control UI is present and compiled into the target.
[[ -f "$ROOT/GPSSpoof/GPSSpoof/ControlViewController.swift" ]] \
  && echo "  ok   - ControlViewController.swift exists" || { echo "  FAIL - ControlViewController.swift missing"; FAILED=1; }
grep -q 'ControlViewController.swift' "$ROOT/GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj" \
  && echo "  ok   - ControlViewController in project graph" || { echo "  FAIL - ControlViewController missing from pbxproj"; FAILED=1; }
```

Run: `bash tests/test_integration.sh` — Expected: the two new checks FAIL.

- [ ] **Step 2: Create ControlViewController.swift**

Create `GPSSpoof/GPSSpoof/ControlViewController.swift`:

```swift
import UIKit

// Remote control for the Mac-side helper (lib/location_helper.py): POSTs new
// coordinates to it, and the helper re-points the running Xcode simulation.
// Also displays the keepalive status that AppDelegate feeds in via showStatus.
final class ControlViewController: UIViewController {
    private let statusLabel = UILabel()
    private let urlField = UITextField()
    private let latField = UITextField()
    private let lonField = UITextField()
    private let applyButton = UIButton(type: .system)
    private let resultLabel = UILabel()

    private static let urlDefaultsKey = "GPSSpoofHelperURL"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.text = "GPSSpoof\nwaiting for location permission…"
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)

        configure(urlField, placeholder: "helper URL, e.g. http://192.168.1.20:8755",
                  keyboard: .URL)
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.text = UserDefaults.standard.string(forKey: Self.urlDefaultsKey)

        configure(latField, placeholder: "latitude, e.g. 37.3861",
                  keyboard: .numbersAndPunctuation)
        configure(lonField, placeholder: "longitude, e.g. -122.0839",
                  keyboard: .numbersAndPunctuation)

        applyButton.setTitle("Apply location", for: .normal)
        applyButton.titleLabel?.font = .boldSystemFont(ofSize: 18)
        applyButton.addTarget(self, action: #selector(applyTapped), for: .touchUpInside)

        resultLabel.numberOfLines = 0
        resultLabel.textAlignment = .center
        resultLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        resultLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [
            statusLabel, urlField, latField, lonField, applyButton, resultLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    /// Called by AppDelegate with keepalive / simulated-fix updates.
    func showStatus(_ text: String) {
        DispatchQueue.main.async { self.statusLabel.text = text }
    }

    private func configure(_ field: UITextField, placeholder: String,
                           keyboard: UIKeyboardType) {
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.keyboardType = keyboard
        field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
    }

    @objc private func dismissKeyboard() { view.endEditing(true) }

    @objc private func applyTapped() {
        view.endEditing(true)
        var base = (urlField.text ?? "").trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/location"), url.scheme?.hasPrefix("http") == true else {
            showResult("enter the helper URL the Mac printed, e.g. http://192.168.1.20:8755")
            return
        }
        guard let lat = Double(latField.text ?? ""), let lon = Double(lonField.text ?? ""),
              (-90...90).contains(lat), (-180...180).contains(lon) else {
            showResult("lat must be -90..90, lon -180..180")
            return
        }
        UserDefaults.standard.set(base, forKey: Self.urlDefaultsKey)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["lat": lat, "lon": lon])

        showResult("applying…")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
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
            } else {
                self?.showResult(body["error"] as? String ?? "helper reported an error")
            }
        }.resume()
    }

    private func showResult(_ text: String) {
        DispatchQueue.main.async { self.resultLabel.text = text }
    }
}
```

- [ ] **Step 3: Rewire AppDelegate**

In `GPSSpoof/GPSSpoof/AppDelegate.swift`, make these three edits (the CoreLocation keepalive logic is untouched):

(a) Replace the property block:

```swift
    var window: UIWindow?
    private let locationManager = CLLocationManager()
    private let statusLabel = UILabel()
```

with:

```swift
    var window: UIWindow?
    private let locationManager = CLLocationManager()
    private let controlVC = ControlViewController()
```

(b) In `application(_:didFinishLaunchingWithOptions:)`, replace everything from `let root = UIViewController()` through the `NSLayoutConstraint.activate([...])` call and the window setup lines:

```swift
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
```

with:

```swift
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = controlVC
        window?.makeKeyAndVisible()
```

(c) Replace the `setStatus` helper at the bottom of the class:

```swift
    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.statusLabel.text = text }
    }
```

with:

```swift
    private func setStatus(_ text: String) {
        controlVC.showStatus(text)
    }
```

(All existing `setStatus(...)` call sites in the authorization and location delegate callbacks stay exactly as they are.)

- [ ] **Step 4: Regenerate the project and type-check**

```bash
./setup.sh
swiftc -parse -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" -target arm64-apple-ios15.0 \
  GPSSpoof/GPSSpoof/AppDelegate.swift GPSSpoof/GPSSpoof/ControlViewController.swift
```

Expected: setup prints `ok   - project regenerated`; swiftc exits 0 with no diagnostics.

- [ ] **Step 5: Run the integration suite to verify it passes**

Run: `bash tests/test_integration.sh`
Expected: all checks pass. Then: `git checkout -- GPSSpoof/GPSSpoof/locations/target.gpx`

- [ ] **Step 6: Commit**

```bash
git add GPSSpoof/GPSSpoof/ControlViewController.swift GPSSpoof/GPSSpoof/AppDelegate.swift \
        GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj tests/test_integration.sh
git commit -m "feat(control): phone-side control UI posting coords to the Mac helper"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md`
- Modify: `spoof.sh` (handoff text only)

- [ ] **Step 1: Add the README section**

In `README.md`, insert a new section after the `## Usage` section (i.e., between Usage and `## Restoring the real location`):

````markdown
## Changing the location from the phone

Once the debug session is running, you can move the spoofed location from the
iPhone itself — no Mac interaction needed beyond initial setup.

Start the session with the helper:

```bash
./spoof.sh --lat 37.3861 --lon -122.0839 --listen
```

`--listen` opens Xcode as usual, then runs a small helper
(`lib/location_helper.py`) in the foreground. The helper prints a URL like
`http://192.168.1.20:8755` — enter it once in the GPSSpoof app on the phone
(it is remembered). Type new coordinates and tap **Apply location**: the
helper writes them into one of two alternating GPX slots (`live_a.gpx` /
`live_b.gpx`) and clicks **Debug ▸ Simulate Location** in Xcode for you, so
the running session re-reads the file. Two slots are used because Xcode
caches a re-selected GPX file.

One-time Mac setup: grant **Accessibility** permission to the terminal app
running the helper (System Settings ▸ Privacy & Security ▸ Accessibility).
The helper returns a clear error to the phone if the permission is missing.

Notes:
- Each Apply briefly brings Xcode to the front on the Mac.
- The first Apply triggers iOS's one-time **Local Network** permission prompt
  on the phone — allow it.
- Stopping the helper (Ctrl-C) does not end the spoof session; it only stops
  phone control. Re-run `python3 lib/location_helper.py` to get it back.
- If the helper reports a missing menu item, run
  `python3 lib/location_helper.py --probe-menu` to see the names Xcode
  actually shows, and check that a debug session is running.
````

- [ ] **Step 2: Update the Tests section and project layout**

In `README.md` `## Tests`, add `python3 tests/test_helper.py` to the command list. In `## Project layout`, add these two lines in the appropriate places:

```
lib/location_helper.py                   # Mac-side phone-control helper
GPSSpoof/GPSSpoof/ControlViewController.swift  # Phone-side control UI
```

- [ ] **Step 3: Mention phone control in the spoof.sh handoff text**

In `spoof.sh`, inside the handoff heredoc's "Keeping the session alive" block, add as the final bullet:

```
    - Want to move the spoofed location later without the Mac?
      Re-run with --listen and enter the printed URL in the app.
```

- [ ] **Step 4: Run everything**

```bash
bash tests/test_gpx.sh && bash tests/test_integration.sh && python3 tests/test_helper.py
git checkout -- GPSSpoof/GPSSpoof/locations/target.gpx GPSSpoof/GPSSpoof/locations/live_a.gpx GPSSpoof/GPSSpoof/locations/live_b.gpx
```

Expected: all three suites pass.

- [ ] **Step 5: Commit**

```bash
git add README.md spoof.sh
git commit -m "docs(control): document phone-controlled location switching"
```

---

### Task 8: Manual end-to-end verification (requires the iPhone — cannot be automated)

No code changes; this validates the two assumptions that only a live debug session can prove: (1) the Simulate Location menu lists the slots under the expected names, and (2) re-selecting an updated slot moves the system-wide location.

- [ ] **Step 1:** Run `./spoof.sh --lat 37.3861 --lon -122.0839 --listen`, press Cmd-R in Xcode, accept the location prompt on the phone, wait for the app to show the simulated fix.
- [ ] **Step 2:** On the Mac, in a second terminal: `python3 lib/location_helper.py --probe-menu`. Expected output includes `live_a` and `live_b`. **If the names differ** (e.g., they include the `.gpx` extension), update the `SLOTS` tuple in `lib/location_helper.py` and the slot names used in `tests/test_helper.py` accordingly, re-run the tests, and commit the fix.
- [ ] **Step 3:** On the phone, enter the helper URL printed in step 1, set lat/lon to a visibly different place (e.g., `40.7580, -73.9855`), tap **Apply location**. Accept the Local Network prompt if shown. Expected: result label shows `applied 40.75800, -73.98550 (slot live_a)` and within a few seconds the keepalive status label shows the new coordinates (the app is consuming the simulated feed, so it doubles as confirmation).
- [ ] **Step 4:** Open Maps on the phone and confirm the blue dot moved. Apply a second location and confirm it lands in slot `live_b` and moves again (proves the alternation defeats Xcode's cache).
- [ ] **Step 5:** Lock the phone, wait 2 minutes, unlock, apply a third location. Expected: still works (keepalive held the session).
- [ ] **Step 6:** Kill the helper with Ctrl-C, confirm the spoofed location persists (helper lifetime is independent of the debug session), restart the helper, confirm Apply works again.

---

## Self-review notes

- **Spec coverage:** phone-side UI (Task 6), Mac helper + osascript trigger (Tasks 2–3), slot files in project graph (Task 1), `--listen` entry point (Task 4), required plist keys (Task 5), docs (Task 7), live verification of the two untestable assumptions (Task 8). The scheme file is intentionally untouched.
- **Type/name consistency verified:** `SLOTS = ("live_a", "live_b")`, `HelperServer(addr, dry_run, locations_dir)`, `apply_location(lat, lon) -> (status, body)`, `click_simulate_location(slot) -> None | (status, message)`, port `8755`, endpoints `/location` + `/health`, response shape `{"ok": ..., "slot"/"error": ...}` consumed identically by `tests/test_helper.py` and `ControlViewController.applyTapped`, UserDefaults key `GPSSpoofHelperURL`, `showStatus(_:)` called by `AppDelegate.setStatus`.
- **Known risk, mitigated:** the exact Simulate Location menu-item names are the one assumption that can't be verified without a live session; `--probe-menu` exists for exactly this, and Task 8 step 2 contains the adjustment procedure.
- **Repo hygiene:** the integration suite mutates `target.gpx` (pre-existing behavior) and the helper smoke test mutates the live slots — every task that runs them includes the `git checkout --` restore before committing.
