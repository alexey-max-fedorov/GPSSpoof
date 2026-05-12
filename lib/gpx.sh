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

# xml_escape <string>  — escapes &, <, > for XML text/attributes
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
