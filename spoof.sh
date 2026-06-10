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
