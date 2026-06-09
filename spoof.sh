#!/usr/bin/env bash
# spoof.sh — write the GPX, hand off to Xcode for build + run.
#
# Usage: ./spoof.sh --lat <lat> --lon <lon> [--name "Label"] [--no-open]
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
# this script just stages the GPX and opens Xcode for you.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/gpx.sh
source "$SCRIPT_DIR/lib/gpx.sh"

# --- arg parsing ---
LAT=""
LON=""
NAME="Spoofed Location"
NO_OPEN=0

usage() {
  cat <<EOF
Usage: $0 --lat <lat> --lon <lon> [--name "Label"] [--no-open]

  --lat       latitude  (-90  .. 90)
  --lon       longitude (-180 .. 180)
  --name      optional waypoint label
  --no-open   write GPX and exit; skip the Xcode handoff (used by tests)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lat)      LAT="${2-}";  shift 2 ;;
    --lon)      LON="${2-}";  shift 2 ;;
    --name)     NAME="${2-}"; shift 2 ;;
    --no-open)  NO_OPEN=1;    shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$LAT" || -z "$LON" ]]; then
  usage >&2
  exit 1
fi

# --- write GPX (validates coords) ---
GPX_PATH="$SCRIPT_DIR/GPSSpoof/GPSSpoof/locations/target.gpx"
if ! write_gpx "$LAT" "$LON" "$NAME" "$GPX_PATH"; then
  echo "ERROR: coords out of range. lat must be -90..90, lon must be -180..180." >&2
  exit 1
fi
echo "  ok   - GPX written: $LAT, $LON ($NAME)"

# --- informational: which iPhone Xcode will likely target ---
UDID=$(xcrun xctrace list devices 2>&1 \
       | grep -Ei 'iPhone.*\(([0-9A-Fa-f-]{25,40})\)$' \
       | head -1 \
       | grep -oE '\(([0-9A-Fa-f-]{25,40})\)$' \
       | tr -d '()' \
       || true)
if [[ -n "$UDID" ]]; then
  echo "  ok   - iPhone detected: $UDID"
else
  echo "  note - no iPhone visible to xctrace; plug in and trust the Mac before pressing Cmd-R in Xcode."
fi

if [[ "$NO_OPEN" == "1" ]]; then
  exit 0
fi

cat <<EOF

============================================================
  HANDOFF TO Xcode.app — required to activate GPS spoof
============================================================

  Opening the project now. In Xcode:
    1. Top-left: scheme dropdown should already show 'GPSSpoof'.
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

  iPhone reports ($LAT, $LON) to every app while the session
  holds. The screen can lock; the spoof now survives that.

  Restore real GPS: reboot the iPhone.
EOF

exec open -a Xcode "$SCRIPT_DIR/GPSSpoof/GPSSpoof.xcodeproj"
