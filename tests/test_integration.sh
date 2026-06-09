#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FAILED=0
assert_ok() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  ok   - $label"
  else echo "  FAIL - $label"; FAILED=1; fi
}

echo "Integration smoke:"

# 1. spoof.sh --no-open should write GPX and exit 0 cleanly (no Xcode handoff).
OUTPUT=$( "$ROOT/spoof.sh" --lat 37.3861 --lon -122.0839 --name "MV" --no-open 2>&1 )
RC=$?
echo "$OUTPUT" | grep -q "GPX written" && echo "  ok   - GPX-write message" || { echo "  FAIL - missing GPX-write message"; FAILED=1; }
[[ "$RC" == "0" ]] && echo "  ok   - exit 0 with --no-open" || { echo "  FAIL - exit $RC with --no-open"; FAILED=1; }

# 2. The GPX file should be valid and contain our coords.
GPX="$ROOT/GPSSpoof/GPSSpoof/locations/target.gpx"
assert_ok "GPX is well-formed" xmllint --noout "$GPX"
LAT=$(xmllint --xpath 'string(//*[local-name()="wpt"]/@lat)' "$GPX")
[[ "$LAT" == "37.3861" ]] && echo "  ok   - lat in GPX" || { echo "  FAIL - lat=$LAT"; FAILED=1; }

# 3. xcodebuild can list the scheme.
LIST=$(cd "$ROOT/GPSSpoof" && xcodebuild -project GPSSpoof.xcodeproj -list 2>&1)
echo "$LIST" | grep -q "GPSSpoof" && echo "  ok   - scheme listed by xcodebuild" || { echo "  FAIL - scheme not listed"; FAILED=1; }

# 4. The scheme XML has the required location-simulation attributes.
# Whitespace-tolerant: Xcode rewrites schemes as `attr = "value"`.
SCHEME="$ROOT/GPSSpoof/GPSSpoof.xcodeproj/xcshareddata/xcschemes/GPSSpoof.xcscheme"
grep -qE 'allowLocationSimulation *= *"YES"' "$SCHEME" && echo "  ok   - allowLocationSimulation=YES" || { echo "  FAIL - missing allowLocationSimulation"; FAILED=1; }
grep -qE 'locationScenarioReference *=' "$SCHEME" && echo "  ok   - locationScenarioReference present" || { echo "  FAIL - missing locationScenarioReference"; FAILED=1; }

# 4b. The app declares the background-location keepalive that lets the
# debug session survive screen lock.
PLIST="$ROOT/GPSSpoof/GPSSpoof/Info.plist"
xmllint --xpath '//key[text()="UIBackgroundModes"]/following-sibling::array[1]/string[text()="location"]' "$PLIST" >/dev/null 2>&1 \
  && echo "  ok   - UIBackgroundModes includes location" || { echo "  FAIL - Info.plist missing location background mode"; FAILED=1; }
grep -q 'allowsBackgroundLocationUpdates' "$ROOT/GPSSpoof/GPSSpoof/AppDelegate.swift" \
  && echo "  ok   - AppDelegate arms background location keepalive" || { echo "  FAIL - AppDelegate missing background location keepalive"; FAILED=1; }
grep -q 'UIBackgroundModes' "$ROOT/GPSSpoof/project.yml" \
  && echo "  ok   - project.yml keeps Info.plist keys in sync" || { echo "  FAIL - project.yml missing UIBackgroundModes (xcodegen regen would drop it)"; FAILED=1; }

# 5. Rejection of bad coords leaves the previous GPX intact.
"$ROOT/spoof.sh" --lat 999 --lon 0 --no-open >/dev/null 2>&1 && { echo "  FAIL - bad coords accepted"; FAILED=1; } || echo "  ok   - bad coords rejected"
LAT2=$(xmllint --xpath 'string(//*[local-name()="wpt"]/@lat)' "$GPX")
[[ "$LAT2" == "37.3861" ]] && echo "  ok   - prior GPX untouched after rejection" || { echo "  FAIL - GPX got overwritten with bad input"; FAILED=1; }

exit "$FAILED"
