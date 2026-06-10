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

# 12. mode=v1 accepted; slot still alternates (applies so far: a,b,a,b,a -> next b).
req POST /location '{"lat": 1, "lon": 2, "mode": "v1"}'
if [[ "$STATUS" == 200 ]] && has '"slot":"live_b"'; then ok "mode v1 accepted"
else fail "mode v1 -> $STATUS $(cat "$BODY" 2>/dev/null)"; fi

# 13. mode=v2 accepted explicitly (same behavior as omitting it).
req POST /location '{"lat": 1, "lon": 2, "mode": "v2"}'
if [[ "$STATUS" == 200 ]] && has '"slot":"live_a"'; then ok "mode v2 accepted"
else fail "mode v2 -> $STATUS $(cat "$BODY" 2>/dev/null)"; fi

# 14. Unknown mode -> 400, and the slot pointer does not advance.
req POST /location '{"lat": 1, "lon": 2, "mode": "v3"}'
if [[ "$STATUS" == 400 ]] && has '"ok":false'; then ok "400 on unknown mode"
else fail "mode v3 -> $STATUS"; fi
req GET /health
if has '"slot":"live_a"'; then ok "slot unchanged after rejected mode"
else fail "/health slot after bad mode: $(cat "$BODY" 2>/dev/null)"; fi

# 15. POST /stop in dry-run -> 200, spoofing reported off. Body is ignored.
req POST /stop '{}'
if [[ "$STATUS" == 200 ]] && has '"ok":true' && has '"spoofing":false'; then
  ok "POST /stop"
else fail "POST /stop -> $STATUS $(cat "$BODY" 2>/dev/null)"; fi

# 16. Stopping does not advance the slot pointer (still live_a after test 14).
req GET /health
if has '"slot":"live_a"'; then ok "slot unchanged after stop"
else fail "/health slot after stop: $(cat "$BODY" 2>/dev/null)"; fi

exit "$FAILED"
