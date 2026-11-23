"""A page restored from the back/forward cache keeps its media session metadata and actions (DEV-960)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import bfcache_media_session_overlay as overlay


def prepare(root, patches=None):
    for relative, before, _ in patches or overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write("// Chromium\n" + before + "// more Chromium\n")


def texts(root):
    return {relative: (root / relative).read_text() for relative, _, _ in overlay.patches()}


class BackForwardCacheMediaSessionOverlayTests(unittest.TestCase):
    def test_anchors_apply_once_and_again_changes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            first = texts(root)
            overlay.apply(root)
            self.assertEqual(first, texts(root))
            for relative, _, after in overlay.patches():
                self.assertEqual(first[relative].count(after), 1, relative)

    def test_a_restore_keeps_metadata_and_actions_but_not_playback_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            service = texts(root)[overlay.SERVICE]
            restore = service[service.index("void MediaSessionServiceImpl::DidRestoreFromBackForwardCache() {"):]
            restore = restore[:restore.index("\n}\n")]
            self.assertIn("SetPlaybackState(blink::mojom::MediaSessionPlaybackState::NONE);", restore)
            self.assertNotIn("SetMetadata(", restore)
            self.assertNotIn("ClearActions(", restore)
            # Any other navigation still resets everything.
            self.assertIn("  SetMetadata(nullptr);\n  ClearActions();\n}\n", service)
            self.assertIn("  void DidRestoreFromBackForwardCache();\n", texts(root)[overlay.SERVICE_HEADER])

    def test_only_a_navigation_served_from_the_cache_skips_the_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            session = texts(root)[overlay.SESSION]
            branch = session[session.index("if (navigation_handle->IsServedFromBackForwardCache()) {"):]
            self.assertLess(branch.index("DidRestoreFromBackForwardCache();"), branch.index("} else {"))
            self.assertLess(branch.index("} else {"), branch.index("DidFinishNavigation();"))
            self.assertEqual(session.count("->DidFinishNavigation();"), 1)

    def test_changed_anchor_fails_closed(self):
        for relative, _, _ in overlay.patches():
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                changed = [(other, text.replace("(", " (") if other == relative else text, new)
                           for other, text, new in overlay.patches()]
                prepare(root, changed)
                with self.assertRaisesRegex(ValueError, "anchor changed"):
                    overlay.apply(root)

    def test_the_overlay_is_applied_and_identifies_the_engine(self):
        engine = Path(__file__).parents[1] / "engine"
        self.assertIn("apply_bfcache_media_session(source)", (engine / "overlay.py").read_text())
        self.assertIn('"Scripts/engine/bfcache_media_session_overlay.py"', (engine / "artifact.py").read_text())

    def test_the_bridge_keeps_a_restored_pages_artwork(self):
        bridge = (Path(__file__).parents[2] / "Packages/engine/Native/media_bridge.mm").read_text()
        navigation = bridge[bridge.index("void DidFinishNavigation(content::NavigationHandle* navigation) override {"):]
        navigation = navigation[:navigation.index("void PrimaryMainFrameRenderProcessGone(")]
        self.assertIn("const bool restored = navigation->IsServedFromBackForwardCache();", navigation)
        kept = navigation[navigation.index("if (!restored) {"):]
        self.assertLess(kept.index("artwork_image_.reset();"), kept.index("}"))
        self.assertLess(kept.index("artwork_.clear();"), kept.index("}"))


if __name__ == "__main__":
    unittest.main()
