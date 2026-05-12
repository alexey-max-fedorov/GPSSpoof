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

# --- build & install on device, then hand off to Xcode.app for spoof activation ---
echo ""
echo "Building (this can take 30-60s on first run)..."
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
DERIVED="$(xcodebuild -project "$SCRIPT_DIR/GPSSpoof/GPSSpoof.xcodeproj" \
                      -scheme GPSSpoof \
                      -configuration Debug \
                      -destination "platform=iOS,id=$UDID" \
                      -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
APP_PATH="$DERIVED/GPSSpoof.app"
[[ -d "$APP_PATH" ]] || { echo "ERROR: built .app not found at $APP_PATH" >&2; exit 1; }

xcrun devicectl device install app --device "$UDID" "$APP_PATH" >>"$BUILD_LOG" 2>&1 \
  || { echo "ERROR: install failed. Tail of log:" >&2; tail -40 "$BUILD_LOG" >&2; exit 1; }
echo "  ok   - app installed"

# The actual GPS-spoof trigger lives in Xcode.app's Run action, which honors the
# scheme's allowLocationSimulation + locationScenarioReference. xcodebuild's
# headless path explicitly cannot interpret those scheme attributes
# (xcodebuild -list prints: "not able to deal with ivar '_locationScenarioReference'"),
# and there is no documented lldb command on current Xcode versions that injects
# the GPX into a running process. So we hand off to Xcode.app.

echo ""
echo "============================================================"
echo "  HANDOFF TO Xcode.app — required to activate GPS spoof"
echo "============================================================"
echo ""
echo "  Opening the project now. In Xcode:"
echo "    1. Select the GPSSpoof scheme (top-left)."
echo "    2. Select your iPhone as the run destination."
echo "    3. Press Cmd-R to Run."
echo "    4. Wait until the bottom status bar shows 'Running GPSSpoof on <device>'."
echo "    5. UNPLUG the USB cable. Do NOT press Stop in Xcode."
echo ""
echo "  iPhone will report ($LAT, $LON) to all apps until reboot."
echo ""
echo "  Why Xcode and not the CLI: only Xcode's Run action triggers"
echo "  the scheme's locationScenarioReference. The .app is already"
echo "  installed on your device; Cmd-R just attaches the debug"
echo "  session that holds the spoof."
echo ""

exec open -a Xcode "$SCRIPT_DIR/GPSSpoof/GPSSpoof.xcodeproj"
