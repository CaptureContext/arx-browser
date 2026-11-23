"""A profile Arx loads again in the same run keeps its session cookies (DEV-880)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import session_cookies_overlay as overlay


def prepare(root, patches=None):
    for relative, before, _ in patches or overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write("// Chromium\n" + before + "// more Chromium\n")


class SessionCookiesOverlayTests(unittest.TestCase):
    def test_reload_consults_the_embedder_first_and_is_repeatable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            first = {relative: (root / relative).read_text() for relative, _, _ in overlay.patches()}
            overlay.apply(root)
            self.assertEqual(first, {relative: (root / relative).read_text() for relative, _, _ in overlay.patches()})

            restore = first[overlay.PROFILE]
            # The embedder's answer comes before Chromium's own policy, which stays.
            self.assertLess(restore.index("ArxKeepsSession(GetPath())"), restore.index("#if BUILDFLAG(IS_ANDROID)"))
            manager = first[overlay.MANAGER]
            self.assertIn("void SetArxSessionKeeper(", manager)
            self.assertIn("return arx_session_keeper_ && arx_session_keeper_.Run(path);", manager)

    def test_changed_anchor_fails_closed(self):
        for relative, before, _ in overlay.patches():
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                changed = [(other, text.replace("(", " (") if other == relative else text, new)
                           for other, text, new in overlay.patches()]
                prepare(root, changed)
                with self.assertRaisesRegex(ValueError, "anchor changed"):
                    overlay.apply(root)

    def test_the_engine_installs_the_keeper_before_profiles_load(self):
        engine = (Path(__file__).parents[2] / "Packages/engine/Native/engine_bridge.mm").read_text()
        start = engine.index("void PreProfileInit() override {")
        self.assertIn("SetArxSessionKeeper(", engine[start:engine.index("}", engine.index("SetArxSessionKeeper(", start))])
        release = engine[engine.index("bool ReleaseProfile("):]
        self.assertLess(release.index("KeepSessionOnReload(profile);"), release.index("state.profiles.erase(found);"))


if __name__ == "__main__":
    unittest.main()
