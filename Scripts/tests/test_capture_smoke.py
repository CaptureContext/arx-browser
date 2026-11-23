"""A zero-exit app cannot pass the capture gate with missing rendering assertions."""

import json
import unittest

from Scripts.core import capture_fixture, capture_smoke


class CaptureSmokeTests(unittest.TestCase):
    def test_expectations_are_the_http_fixtures_css_points_and_rgb(self):
        patches = json.loads(capture_smoke.environment()["ARX_CAPTURE_SMOKE_PATCHES"])
        self.assertEqual([(p["x"], p["y"], (p["red"], p["green"], p["blue"])) for p in patches],
                         list(capture_fixture.PATCHES))
        self.assertEqual(len(patches), 6)

    def test_requires_every_rendering_and_lifetime_assertion(self):
        for omitted in capture_smoke.MARKERS:
            with self.subTest(omitted=omitted), self.assertRaisesRegex(ValueError, omitted):
                capture_smoke.verify("\n".join(value for value in capture_smoke.MARKERS if value != omitted))

    def test_diagnostic_mention_is_not_a_success_marker(self):
        with self.assertRaisesRegex(ValueError, "did not complete"):
            capture_smoke.verify("failed waiting for " + " ".join(capture_smoke.MARKERS))

    def test_accepts_complete_capture_gate_output(self):
        capture_smoke.verify("unrelated engine output\n" + "\n".join(capture_smoke.MARKERS) + "\n")
