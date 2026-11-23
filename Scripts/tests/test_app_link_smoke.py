"""The app-link fixture redirects without a gesture to a hostile-looking test link (DEV-857)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.core import app_link_smoke


class AppLinkSmokeTests(unittest.TestCase):
    def test_page_redirects_to_the_unregistered_test_scheme_without_a_click(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app_link_smoke.prepare(root)
            page = (root / "app-link.html").read_text()
            self.assertIn("arx-smoke-app-link://callback?code=", page)
            # A replacing redirect: Chrome marks only that one a client redirect after load.
            self.assertIn("location.replace(link)", page)
            self.assertNotIn("location.href = link", page)
            self.assertNotIn("onclick", page)
            for hostile in (";touch", "$(id)", "%27single%27", "%22double%22"):
                self.assertIn(hostile, page)
            with self.assertRaises(FileExistsError):
                app_link_smoke.prepare(root)

    def test_app_page_redirects_to_the_chosen_app_scheme(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app_link_smoke.prepare(root)
            page = (root / "app-link-app.html").read_text()
            self.assertIn("arx-smoke-app-pick://callback?code=", page)
            self.assertIn("Arx App Link App ready", page)
            self.assertNotIn("onclick", page)

    def test_applet_records_the_link_quoted_and_quits(self):
        source = app_link_smoke.applet_source(Path('/tmp/a "b"/record.txt'))
        self.assertIn("on open location theURL", source)
        self.assertIn("quoted form of theURL", source)
        self.assertIn('quoted form of "/tmp/a \\"b\\"/record.txt"', source)
        self.assertIn("  quit\n", source)
        self.assertNotIn("on run", source)

    def test_open_page_redirects_to_the_scheme_no_handler_takes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app_link_smoke.prepare(root)
            page = (root / "app-link-open.html").read_text()
            self.assertIn("arx-smoke-app-open://callback?code=", page)
            self.assertIn("Arx App Link Open ready", page)
            self.assertNotIn("onclick", page)

    def test_open_applet_goes_beside_the_work_folder_on_the_home_volume(self):
        # DEV-1259: Launch Services disables an app in the temporary folder, so the applet
        # must never land there.
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory(dir=home) as work:
            self.assertEqual(app_link_smoke.open_app_parent(Path(work), home=home), Path(work))

    def test_open_applet_leaves_a_work_folder_on_another_volume_for_the_home_caches(self):
        with tempfile.TemporaryDirectory() as home:
            parent = app_link_smoke.open_app_parent(Path("/dev"), home=home)
            self.assertEqual(parent, Path(home) / "Library/Caches/dev.capturecontext.arx.smoke")
            self.assertTrue(parent.is_dir())

    def test_verify_requires_every_marker(self):
        app_link_smoke.verify(
            "x\nARX_APP_LINK_SMOKE_SUCCESS\nARX_APP_LINK_APP_SMOKE_SUCCESS\nARX_APP_LINK_OPEN_SMOKE_SUCCESS\n"
        )
        with self.assertRaises(ValueError):
            app_link_smoke.verify("ARX_LITTLE_POPUP_SMOKE_SUCCESS\n")
        with self.assertRaises(ValueError):
            app_link_smoke.verify("ARX_APP_LINK_SMOKE_SUCCESS\n")
        # DEV-1259: the scheme no handler takes must reach Arx's prompt too.
        with self.assertRaises(ValueError):
            app_link_smoke.verify("ARX_APP_LINK_SMOKE_SUCCESS\nARX_APP_LINK_APP_SMOKE_SUCCESS\n")


if __name__ == "__main__":
    unittest.main()
