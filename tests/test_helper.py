#!/usr/bin/env python3
"""Unit tests for lib/location_helper.py. No device, no Xcode, no network
permissions needed: the HTTP tests (added in Task 3) run the server in
dry-run mode on a loopback ephemeral port."""
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import location_helper as lh


class TestValidate(unittest.TestCase):
    def test_valid_floats(self):
        self.assertEqual(lh.validate(37.3861, -122.0839), (37.3861, -122.0839))

    def test_valid_strings_coerced(self):
        self.assertEqual(lh.validate("45.5", "-120"), (45.5, -120.0))

    def test_boundaries(self):
        self.assertEqual(lh.validate(90, 180), (90.0, 180.0))
        self.assertEqual(lh.validate(-90, -180), (-90.0, -180.0))

    def test_out_of_range(self):
        self.assertIsNone(lh.validate(90.1, 0))
        self.assertIsNone(lh.validate(-90.1, 0))
        self.assertIsNone(lh.validate(0, 180.1))
        self.assertIsNone(lh.validate(0, -180.1))

    def test_garbage(self):
        self.assertIsNone(lh.validate("abc", 0))
        self.assertIsNone(lh.validate(None, None))
        self.assertIsNone(lh.validate("1; rm -rf /", 0))


class TestMakeGpx(unittest.TestCase):
    def test_round_trip(self):
        xml = lh.make_gpx(37.3861, -122.0839, "live_a")
        root = ET.fromstring(xml)
        ns = {"g": "http://www.topografix.com/GPX/1/1"}
        wpt = root.find("g:wpt", ns)
        self.assertEqual(wpt.get("lat"), "37.3861")
        self.assertEqual(wpt.get("lon"), "-122.0839")
        self.assertEqual(wpt.find("g:name", ns).text, "live_a")

    def test_integer_coords(self):
        root = ET.fromstring(lh.make_gpx(45.0, -120.0, "live_b"))
        ns = {"g": "http://www.topografix.com/GPX/1/1"}
        self.assertEqual(root.find("g:wpt", ns).get("lat"), "45.0")

    def test_near_zero_coords_stay_decimal(self):
        ns = {"g": "http://www.topografix.com/GPX/1/1"}
        wpt = ET.fromstring(lh.make_gpx(0.00001, -0.00002, "live_a")).find("g:wpt", ns)
        self.assertNotIn("e", wpt.get("lat").lower())
        self.assertNotIn("e", wpt.get("lon").lower())
        self.assertAlmostEqual(float(wpt.get("lat")), 0.00001)

    def test_name_escaped(self):
        ns = {"g": "http://www.topografix.com/GPX/1/1"}
        root = ET.fromstring(lh.make_gpx(1.0, 2.0, "a&b<c"))
        self.assertEqual(root.find("g:wpt/g:name", ns).text, "a&b<c")


class TestSlots(unittest.TestCase):
    def test_toggle(self):
        self.assertEqual(lh.next_slot("live_a"), "live_b")
        self.assertEqual(lh.next_slot("live_b"), "live_a")


if __name__ == "__main__":
    unittest.main(verbosity=2)
