#!/usr/bin/env bash
# spoof.sh — generate GPX, deploy to USB-connected iPhone, persist after unplug.
#
# Usage: ./spoof.sh --lat <lat> --lon <lon> [--name "Label"] [--udid <udid>]
#
# Env:
#   TEAM_ID  — Apple Developer team id for code signing (optional if Xcode already auto-signed once)
#
# Effect: iPhone reports the spoofed coordinates to all apps (Maps, Find My, Snapchat, etc.)
# until reboot. Do NOT stop the Xcode/xcodebuild process — just unplug the USB cable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/gpx.sh
source "$SCRIPT_DIR/lib/gpx.sh"

# --- arg parsing ---
LAT=""
LON=""
NAME="Spoofed Location"
UDID=""

usage() {
  cat <<EOF
Usage: $0 --lat <lat> --lon <lon> [--name "Label"] [--udid <udid>]

  --lat   latitude  (-90  .. 90)
  --lon   longitude (-180 .. 180)
  --name  optional waypoint label
  --udid  override device UDID (default: first connected iPhone)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lat)  LAT="${2-}";  shift 2 ;;
    --lon)  LON="${2-}";  shift 2 ;;
    --name) NAME="${2-}"; shift 2 ;;
    --udid) UDID="${2-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
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

# --- find a connected iPhone ---
if [[ -z "$UDID" ]]; then
  # xctrace lists physical devices in: "iPhone Name (iOS Version) (UDID)"
  # Modern UDIDs are 25 chars with a hyphen (e.g. 00008110-001A347E0E33401E),
  # but older devices use 40 hex chars. Match both, prefer the first iPhone line.
  UDID=$(xcrun xctrace list devices 2>&1 \
         | grep -Ei 'iPhone.*\(([0-9A-Fa-f-]{25,40})\)$' \
         | head -1 \
         | grep -oE '\(([0-9A-Fa-f-]{25,40})\)$' \
         | tr -d '()' \
         || true)
fi

if [[ -z "$UDID" ]]; then
  echo "ERROR: no iPhone detected via USB." >&2
  echo "  - Plug in via USB and accept the 'Trust This Computer' prompt." >&2
  echo "  - Make sure the iPhone is unlocked." >&2
  echo "  - Run 'xcrun xctrace list devices' to verify it appears." >&2
  exit 1
fi
echo "  ok   - device: $UDID"

# --- build & launch ---
echo ""
echo "Building and launching on device (this can take 30-60s on first run)..."
echo "DO NOT interrupt this command. Wait for the 'App is running' line, THEN unplug USB."
echo ""

BUILD_LOG="$(mktemp -t gpsspoof-build).log"
trap 'echo "(build log: $BUILD_LOG)"' EXIT

xcodebuild \
  -project "$SCRIPT_DIR/GPSSpoof/GPSSpoof.xcodeproj" \
  -scheme GPSSpoof \
  -configuration Debug \
  -destination "platform=iOS,id=$UDID" \
  ${TEAM_ID:+DEVELOPMENT_TEAM="$TEAM_ID"} \
  CODE_SIGN_STYLE=Automatic \
  clean build \
  > "$BUILD_LOG" 2>&1 \
  || {
       echo "ERROR: build failed. Tail of log:" >&2
       tail -40 "$BUILD_LOG" >&2
       if grep -qE "No account for team|requires a development team|Signing for .* requires" "$BUILD_LOG"; then
         echo "" >&2
         echo "Signing error detected. Fix:" >&2
         echo "  1. Open GPSSpoof/GPSSpoof.xcodeproj in Xcode." >&2
         echo "  2. Select the GPSSpoof target > Signing & Capabilities." >&2
         echo "  3. Set Team to your Apple ID (a free account works)." >&2
         echo "  4. Copy the 10-char Team ID and re-run with:" >&2
         echo "       export TEAM_ID=XXXXXXXXXX && ./spoof.sh ..." >&2
       fi
       exit 1
     }

echo "  ok   - build succeeded"

APP_BUNDLE_ID="com.local.gpsspoof"

echo "Installing .app on device..."
DERIVED="$(xcodebuild -project "$SCRIPT_DIR/GPSSpoof/GPSSpoof.xcodeproj" -scheme GPSSpoof -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
APP_PATH="$DERIVED/GPSSpoof.app"
[[ -d "$APP_PATH" ]] || { echo "ERROR: built .app not found at $APP_PATH" >&2; exit 1; }

xcrun devicectl device install app --device "$UDID" "$APP_PATH" >>"$BUILD_LOG" 2>&1 \
  || { echo "ERROR: install failed. Tail of log:" >&2; tail -40 "$BUILD_LOG" >&2; exit 1; }
echo "  ok   - app installed"

echo ""
echo "Launching with location simulation..."
echo ""
echo "    >>> A debug session is about to start. Wait until you see"
echo "    >>> 'Process N launched' or similar, THEN unplug the USB cable. <<<"
echo ""
echo "    Do NOT press Ctrl-C in this terminal."
echo "    Do NOT close the lldb session."
echo ""

# Launch the installed app stopped, then attach lldb so the LaunchAction's
# location scenario is applied and the debug session persists across unplug.
xcrun devicectl device process launch \
    --device "$UDID" \
    --start-stopped \
    "$APP_BUNDLE_ID" \
  >>"$BUILD_LOG" 2>&1 \
  || { echo "ERROR: launch failed. Tail of log:" >&2; tail -40 "$BUILD_LOG" >&2; exit 1; }

# Attach lldb interactively so the location scenario is applied and the debug
# session persists. The user unplugs USB while this is running.
echo "Attaching debugger (this is the session that holds the GPS spoof)..."
exec xcrun lldb \
  -o "platform select remote-ios" \
  -o "platform connect \"$UDID\"" \
  -o "attach --name GPSSpoof --waitfor" \
  -o "settings set target.process.location-scenario-file $GPX_PATH" \
  -o "continue"
