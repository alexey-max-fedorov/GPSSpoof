#!/usr/bin/env python3
"""GPSSpoof phone-control helper.

Listens for HTTP POSTs from the GPSSpoof iPhone app and re-points Xcode's
*running* location simulation at new coordinates by:
  1. writing the coords into the next "live slot" GPX file
     (GPSSpoof/GPSSpoof/locations/live_a.gpx / live_b.gpx), and
  2. UI-scripting Xcode (Debug > Simulate Location > <slot>) via osascript.

Two slots are alternated because Xcode caches a re-selected GPX; picking a
*different* menu item forces a re-read.

Requires macOS Accessibility permission for the terminal app running this
script (System Settings > Privacy & Security > Accessibility). Each apply
briefly brings Xcode frontmost.

Usage:
  python3 lib/location_helper.py [--port 8755] [--dry-run]
  python3 lib/location_helper.py --probe-menu

Python 3 stdlib only; no third-party dependencies.
"""
import argparse
import json
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
LOCATIONS_DIR = ROOT / "GPSSpoof" / "GPSSpoof" / "locations"
SLOTS = ("live_a", "live_b")
DEFAULT_PORT = 8755


def validate(lat, lon):
    """Return (lat, lon) as floats if both are in range, else None."""
    try:
        lat, lon = float(lat), float(lon)
    except (TypeError, ValueError):
        return None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None
    return lat, lon


def _fmt_coord(value):
    """Decimal string for a GPX attribute. repr() keeps typical values
    readable (37.3861 stays "37.3861") but switches to scientific notation
    below 1e-4, which xsd:decimal forbids -- fall back to fixed-point."""
    text = repr(value)
    return f"{value:.7f}" if "e" in text or "E" in text else text


def make_gpx(lat, lon, name):
    """Single-waypoint GPX 1.1, same shape lib/gpx.sh writes. The waypoint
    name must equal the slot name: Xcode's Simulate Location menu has labeled
    GPX entries by file name in some versions and by waypoint name in others,
    and keeping them identical makes the menu click work either way."""
    name = escape(str(name))
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<gpx version="1.1" creator="GPSSpoof" '
        'xmlns="http://www.topografix.com/GPX/1/1">\n'
        f'  <wpt lat="{_fmt_coord(lat)}" lon="{_fmt_coord(lon)}">\n'
        f'    <name>{name}</name>\n'
        '  </wpt>\n'
        '</gpx>\n'
    )


def next_slot(current):
    return SLOTS[(SLOTS.index(current) + 1) % len(SLOTS)]
