"""The overnight WebKit swipe phase's fixture and markers (DEV-1203)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.core import webkit_swipe_smoke


class WebKitSwipeSmokeTests(unittest.TestCase):
    def test_runs_only_overnight(self):
        self.assertFalse(webkit_swipe_smoke.enabled({}))
        self.assertFalse(webkit_swipe_smoke.enabled({"ARX_SMOKE_OVERNIGHT": "0"}))
        self.assertTrue(webkit_swipe_smoke.enabled({"ARX_SMOKE_OVERNIGHT": "1"}))

    def test_pages_link_a_to_the_listed_site_and_set_the_phase(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = webkit_swipe_smoke.prepare(root)
            a = (root / webkit_swipe_smoke.PAGE_A).read_text()
            self.assertIn("new URL('" + webkit_swipe_smoke.PAGE_B + "', location.href)", a)
            self.assertIn("next.hostname = 'localhost';", a)
            self.assertIn("history.replaceState(null, '', location.pathname);", a)
            b = (root / webkit_swipe_smoke.PAGE_B).read_text()
            self.assertIn("new URL('" + webkit_swipe_smoke.PAGE_C + "', location.href)", b)
            self.assertNotIn("hostname", b)
            self.assertNotIn("location.assign", b)
            for page in (a, b):
                self.assertIn('id="next"', page)
                self.assertIn("overflow-x:hidden", page)
            self.assertEqual(environment, {"ARX_WEBKIT_SWIPE_SMOKE": "1"})

    def test_verify_requires_every_stage(self):
        stages = "".join(line + "\n" for line in webkit_swipe_smoke.STAGES)
        webkit_swipe_smoke.verify("x\n" + stages + "ARX_WEBKIT_SWIPE_SMOKE_SUCCESS\n")
        with self.assertRaises(ValueError):
            webkit_swipe_smoke.verify(stages)
        with self.assertRaises(ValueError):
            webkit_swipe_smoke.verify(stages.replace("short swipe stayed", "") + "ARX_WEBKIT_SWIPE_SMOKE_SUCCESS\n")


if __name__ == "__main__":
    unittest.main()
