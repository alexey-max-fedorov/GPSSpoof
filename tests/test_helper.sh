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
