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

# 6. Live-slot GPX files exist, are well-formed, and are in the project graph
# (Xcode's Simulate Location menu only lists workspace GPX files).
for SLOT in live_a live_b; do
  SLOT_GPX="$ROOT/GPSSpoof/GPSSpoof/locations/$SLOT.gpx"
  assert_ok "$SLOT.gpx is well-formed" xmllint --noout "$SLOT_GPX"
  grep -q "$SLOT.gpx" "$ROOT/GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj" \
    && echo "  ok   - $SLOT.gpx in project graph" || { echo "  FAIL - $SLOT.gpx missing from pbxproj"; FAILED=1; }
  NAME=$(xmllint --xpath 'string(//*[local-name()="name"])' "$SLOT_GPX")
  [[ "$NAME" == "$SLOT" ]] \
    && echo "  ok   - $SLOT.gpx waypoint name matches slot" \
    || { echo "  FAIL - $SLOT.gpx waypoint name='$NAME', expected '$SLOT'"; FAILED=1; }
done

# 7. Mac-side helper unit tests (dry-run; no Xcode or device involved).
python3 "$ROOT/tests/test_helper.py" >/dev/null 2>&1 \
  && echo "  ok   - location_helper unit tests" || { echo "  FAIL - location_helper unit tests"; FAILED=1; }

# 8. spoof.sh advertises --listen.
"$ROOT/spoof.sh" --help 2>&1 | grep -q -- '--listen' \
  && echo "  ok   - spoof.sh --help mentions --listen" || { echo "  FAIL - --listen missing from usage"; FAILED=1; }

# 9. Networking plist keys for the phone-control channel.
PLIST="$ROOT/GPSSpoof/GPSSpoof/Info.plist"
xmllint --xpath '//key[text()="NSAppTransportSecurity"]/following-sibling::dict[1]/key[text()="NSAllowsLocalNetworking"]' "$PLIST" >/dev/null 2>&1 \
  && echo "  ok   - ATS allows local networking" || { echo "  FAIL - NSAllowsLocalNetworking missing"; FAILED=1; }
grep -q 'NSLocalNetworkUsageDescription' "$PLIST" \
  && echo "  ok   - local-network usage description" || { echo "  FAIL - NSLocalNetworkUsageDescription missing"; FAILED=1; }
grep -q 'NSAllowsLocalNetworking' "$ROOT/GPSSpoof/project.yml" \
  && echo "  ok   - project.yml carries networking keys" || { echo "  FAIL - project.yml missing networking keys (xcodegen regen would drop them)"; FAILED=1; }

# 10. Phone-side control UI is present and compiled into the target.
[[ -f "$ROOT/GPSSpoof/GPSSpoof/ControlViewController.swift" ]] \
  && echo "  ok   - ControlViewController.swift exists" || { echo "  FAIL - ControlViewController.swift missing"; FAILED=1; }
grep -q 'ControlViewController.swift' "$ROOT/GPSSpoof/GPSSpoof.xcodeproj/project.pbxproj" \
  && echo "  ok   - ControlViewController in project graph" || { echo "  FAIL - ControlViewController missing from pbxproj"; FAILED=1; }

exit "$FAILED"
