#!/usr/bin/env bash
# Plain-bash test runner. Exits non-zero on any failed assertion.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPOOF_SH="$SCRIPT_DIR/../spoof.sh"
# spoof.sh is sourceable: its execution guard keeps main() from running.
# shellcheck source=../spoof.sh
source "$SPOOF_SH"

FAILED=0
assert_ok() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok   - $label"
  else
    echo "  FAIL - $label (expected success, got exit $?)"
    FAILED=1
  fi
}
assert_fail() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  FAIL - $label (expected failure, got success)"
    FAILED=1
  else
    echo "  ok   - $label"
  fi
}

echo "validate_coords:"
assert_ok   "valid lat/lon"            validate_coords 37.3861 -122.0839
assert_ok   "boundary lat=90"          validate_coords 90 0
assert_ok   "boundary lat=-90"         validate_coords -90 0
assert_ok   "boundary lon=180"         validate_coords 0 180
assert_ok   "boundary lon=-180"        validate_coords 0 -180
assert_ok   "integer coords"           validate_coords 37 -122
assert_fail "lat above 90"             validate_coords 90.1 0
assert_fail "lat below -90"            validate_coords -90.1 0
assert_fail "lon above 180"            validate_coords 0 180.1
assert_fail "lon below -180"           validate_coords 0 -180.1
assert_fail "non-numeric lat"          validate_coords abc 0
assert_fail "non-numeric lon"          validate_coords 0 xyz
assert_fail "empty lat"                validate_coords "" 0
assert_fail "shell-injection attempt"  validate_coords '0; rm -rf /' 0


echo ""
echo "write_gpx:"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/out.gpx"

assert_ok "writes file"        bash -c 'source "'"$SPOOF_SH"'" && write_gpx 37.3861 -122.0839 "MV" "'"$OUT"'"'
assert_ok "file exists"        test -f "$OUT"
assert_ok "is well-formed XML" xmllint --noout "$OUT"

LAT_FOUND=$(xmllint --xpath 'string(//*[local-name()="wpt"]/@lat)' "$OUT")
LON_FOUND=$(xmllint --xpath 'string(//*[local-name()="wpt"]/@lon)' "$OUT")
NAME_FOUND=$(xmllint --xpath 'string(//*[local-name()="wpt"]/*[local-name()="name"])' "$OUT")
[[ "$LAT_FOUND" == "37.3861" ]] && echo "  ok   - lat attr round-trips" || { echo "  FAIL - lat attr ($LAT_FOUND)"; FAILED=1; }
[[ "$LON_FOUND" == "-122.0839" ]] && echo "  ok   - lon attr round-trips" || { echo "  FAIL - lon attr ($LON_FOUND)"; FAILED=1; }
[[ "$NAME_FOUND" == "MV" ]] && echo "  ok   - name round-trips" || { echo "  FAIL - name ($NAME_FOUND)"; FAILED=1; }

# XML escaping: ampersand and angle brackets in name must not break the document
bash -c 'source "'"$SPOOF_SH"'" && write_gpx 0 0 "A & B <c>" "'"$OUT"'"'
assert_ok "well-formed after escaping" xmllint --noout "$OUT"
ESC_NAME=$(xmllint --xpath 'string(//*[local-name()="wpt"]/*[local-name()="name"])' "$OUT")
[[ "$ESC_NAME" == "A & B <c>" ]] && echo "  ok   - name escaped+decoded" || { echo "  FAIL - escaped name ($ESC_NAME)"; FAILED=1; }

exit "$FAILED"
