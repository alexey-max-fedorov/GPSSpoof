#!/usr/bin/env bash
# Pure functions for GPX generation. Source this file; do not execute directly.

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
