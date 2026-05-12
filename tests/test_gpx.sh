#!/usr/bin/env bash
# Plain-bash test runner. Exits non-zero on any failed assertion.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/gpx.sh
source "$SCRIPT_DIR/../lib/gpx.sh"

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

exit "$FAILED"
