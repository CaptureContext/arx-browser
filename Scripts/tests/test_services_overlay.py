"""Helium's services are compiled out: no consent pref, origin pref or build flag reaches Helium (DEV-930)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import services_overlay
from Scripts.engine.config import SOURCE, prepared_mismatch


def prepare(root):
    """Each anchor in a file of its own, between unrelated code that must survive."""
    files = {}
    for relative, before, _ in services_overlay.patches():
        files.setdefault(relative, []).append(before)
    for relative, anchors in files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("// before\n" + "\n// between\n".join(anchors) + "\n// after\n")


def contents(root):
    return {path.relative_to(root): path.read_text() for path in root.rglob("*") if path.is_file()}


class ServicesOverlayTests(unittest.TestCase):
    def test_every_service_path_points_at_nothing_and_applying_twice_is_a_no_op(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            services_overlay.apply(root)
            first = contents(root)
            services_overlay.apply(root)
            self.assertEqual(first, contents(root))

            text = "\n".join(first.values())
            for host in ("services.helium.imput.net", "updates.helium.computer", "crash.helium.computer", "push.helium.computer", '"helium.computer"'):
                self.assertNotIn(host, text)
            for unrelated in ("// before", "// between", "// after"):
                self.assertIn(unrelated, text)

            helpers = first[Path(services_overlay.HELPERS)]
            self.assertIn("return false;", helpers)
            self.assertNotIn("kHeliumServicesConsented", helpers)
            self.assertNotIn("GetValidUserOverridenURL(prefs)", helpers)
            self.assertIn("return GetDummyURL();", helpers)
            self.assertIn(services_overlay.DUMMY_ORIGIN, first[Path(services_overlay.HELPERS_HEADER)])
            self.assertIn("return std::string();", first[Path(services_overlay.CRASH_CLIENT)])
            self.assertNotIn("OFFICIAL_BUILD", first[Path(services_overlay.CRASH_CLIENT)])

    def test_google_hosts_for_features_arx_doesnt_have_are_gone(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            services_overlay.apply(root)
            text = "\n".join(contents(root).values())
            for host in ("chromeenterprise.google", "chromestorage.goog", "webprotect-us.goog",
                         "webprotect-eu.goog", "lens.google.com", "safebrowsing-chrome.google"):
                self.assertNotIn(host, text)
            # Both console messages keep their Chrome Status link.
            client = contents(root)[Path(services_overlay.CONTENT_CLIENT)]
            self.assertEqual(client.count("5680742077038592."), 2)
            self.assertIn('"https://www.google.com/complete/search', contents(root)[Path(services_overlay.SEARCH_ENGINES)])

    def test_the_dummy_origin_is_helium_s_own_unreachable_host(self):
        # The same host Helium's kHeliumDummyOrigin names, under ungoogled-chromium's
        # unresolvable .qjz9zk suffix.
        self.assertTrue(services_overlay.DUMMY_ORIGIN.endswith(".qjz9zk"))
        self.assertTrue(services_overlay.DUMMY_ORIGIN.startswith("https://"))

    def test_changed_anchor_fails_closed(self):
        for relative, anchor, _ in services_overlay.patches():
            with self.subTest(relative=relative, anchor=anchor.splitlines()[0]), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                path = root / relative
                changed = anchor.replace("\n", " // changed upstream\n", 1)
                path.write_text(path.read_text().replace(anchor, changed))
                # The build stops; the changed code is left as it is.
                with self.assertRaises(ValueError):
                    services_overlay.apply(root)
                self.assertIn(changed, path.read_text())

    def test_anchors_match_the_pinned_source(self):
        # This checkout's prepared tree, which matches engine.lock.json.
        source = SOURCE
        if not (source / "chrome/BUILD.gn").is_file():
            self.skipTest("no prepared Chromium tree in this checkout")
        if mismatch := prepared_mismatch():
            self.skipTest(mismatch)
        for relative, anchor, replacement in services_overlay.patches():
            with self.subTest(relative=relative, anchor=anchor.splitlines()[0]):
                text = (source / relative).read_text()
                self.assertEqual(text.count(anchor) + text.count(replacement), 1)


if __name__ == "__main__":
    unittest.main()
