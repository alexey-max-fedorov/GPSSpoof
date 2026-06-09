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
from xml.sax.saxutils import escape

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


def _fmt_coord(value):
    """Decimal string for a GPX attribute. repr() keeps typical values
    readable (37.3861 stays "37.3861") but switches to scientific notation
    below 1e-4, which xsd:decimal forbids -- fall back to fixed-point."""
    text = repr(value)
    return f"{value:.7f}" if "e" in text or "E" in text else text


def make_gpx(lat, lon, name):
    """Single-waypoint GPX 1.1, same shape lib/gpx.sh writes. The waypoint
    name must equal the slot name: Xcode's Simulate Location menu has labeled
    GPX entries by file name in some versions and by waypoint name in others,
    and keeping them identical makes the menu click work either way."""
    name = escape(str(name))
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<gpx version="1.1" creator="GPSSpoof" '
        'xmlns="http://www.topografix.com/GPX/1/1">\n'
        f'  <wpt lat="{_fmt_coord(lat)}" lon="{_fmt_coord(lon)}">\n'
        f'    <name>{name}</name>\n'
        '  </wpt>\n'
        '</gpx>\n'
    )


def next_slot(current):
    return SLOTS[(SLOTS.index(current) + 1) % len(SLOTS)]


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
    err_l = err.lower()
    # macOS wording varies by version: "not allowed assistive access",
    # "Not authorized to send Apple events to System Events", ...
    if "assistive access" in err_l or "not authorized" in err_l or "not allowed" in err_l:
        return (403,
                "macOS blocked UI scripting. Grant Accessibility permission to "
                "the terminal app running this helper (System Settings > "
                "Privacy & Security > Accessibility; if it still fails, also "
                "check Privacy & Security > Automation), then tap Apply again.")
    if "menu item" in err_l:
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
        (self.locations_dir / f"{slot}.gpx").write_text(make_gpx(lat, lon, slot), encoding="utf-8")
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
