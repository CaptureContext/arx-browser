"""`make engine-overlay-report` lists every missing anchor instead of stopping at the first."""

import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from Scripts.engine import overlay


def tree(root):
    (root / "chrome").mkdir()
    (root / "chrome/BUILD.gn").write_text("")
    (root / "a.cc").write_text("one\ntwo\n")
    (root / "b.cc").write_text("three\n")


class OverlayReportTests(unittest.TestCase):
    def test_lists_each_missing_anchor_and_keeps_the_edits_that_apply(self):
        def apply(source, team=""):
            overlay.replace_once(source / "a.cc", "one\n", "one\nadded\n")
            overlay.replace_once(source / "a.cc", "gone\n", "gone\nadded\n")
            overlay.replace_once(source / "b.cc", "moved\nupstream\n", "moved\n")
            overlay.replace_once(source / "b.cc", "three\n", "three\nadded\n")

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(overlay, "apply", apply):
            root = Path(directory)
            tree(root)
            output = io.StringIO()
            with contextlib.redirect_stdout(output), self.assertRaisesRegex(ValueError, "2 overlay anchors are missing"):
                overlay.report(root)
            lines = output.getvalue().splitlines()
            self.assertEqual(len(lines), 2)
            self.assertIn("a.cc  (anchor found 0 times): gone", lines[0])
            self.assertIn("b.cc  (anchor found 0 times): moved", lines[1])
            self.assertTrue(lines[0].startswith("test_overlay_report.py:"))
            self.assertEqual((root / "a.cc").read_text(), "one\nadded\ntwo\n")
            self.assertEqual((root / "b.cc").read_text(), "three\nadded\n")
            # Outside a report, a missing anchor stops at once.
            with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                overlay.replace_once(root / "a.cc", "gone\n", "")

    def test_an_overlay_that_stops_is_reported(self):
        def apply(source, team=""):
            raise ValueError("Chromium's browser core target changed")

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(overlay, "apply", apply):
            root = Path(directory)
            tree(root)
            output = io.StringIO()
            with contextlib.redirect_stdout(output), self.assertRaisesRegex(ValueError, "an overlay stopped"):
                overlay.report(root)
            self.assertIn("Stopped before the remaining overlays: Chromium's browser core target changed",
                          output.getvalue())
            self.assertIsNone(overlay._missing)

    def test_every_overlay_applying_passes(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(overlay, "apply", lambda source, team="": None):
            root = Path(directory)
            tree(root)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                overlay.report(root)
            self.assertEqual(output.getvalue(), "Every overlay applies.\n")

    def test_needs_a_prepared_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "make engine-prepare"):
                overlay.report(Path(directory))


if __name__ == "__main__":
    unittest.main()
