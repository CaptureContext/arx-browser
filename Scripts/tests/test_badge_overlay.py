"""Badging API overlay (DEV-907): every hook applies once and again changes nothing."""
from pathlib import Path
import tempfile
import unittest

from Scripts.engine import badge_overlay


class BadgeOverlayTests(unittest.TestCase):
    def test_applies_once_to_an_upstream_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative, before, _ in badge_overlay.patches():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(before + "\n")
            badge_overlay.apply(root)
            first = {path: path.read_bytes() for path in root.rglob("*") if path.is_file()}
            badge_overlay.apply(root)
            self.assertEqual(first, {path: path.read_bytes() for path in root.rglob("*") if path.is_file()})
            for relative, _, after in badge_overlay.patches():
                self.assertEqual((root / relative).read_text().count(after), 1, relative)

    def test_reports_from_set_and_clear(self):
        source = "".join(after for relative, _, after in badge_overlay.patches() if relative == badge_overlay.SOURCE)
        self.assertIn("ArxReportBadge(std::make_optional(value))", source)
        self.assertIn("ArxReportBadge(std::nullopt)", source)
        self.assertIn("arx::PageBadgeChanged", source)


if __name__ == "__main__":
    unittest.main()
