"""Live connection freezing overlay (DEV-879): every edit applies once and again changes nothing."""
from pathlib import Path
import tempfile
import unittest

from Scripts.engine import live_connection_overlay
from Scripts.engine.config import SOURCE


class LiveConnectionOverlayTests(unittest.TestCase):
    def upstream(self, root):
        for relative, before, _ in live_connection_overlay.patches():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a") as stream:
                stream.write(before + "\n")

    def test_applies_once_to_an_upstream_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.upstream(root)
            live_connection_overlay.apply(root)
            first = {path: path.read_bytes() for path in root.rglob("*") if path.is_file()}
            live_connection_overlay.apply(root)
            self.assertEqual(first, {path: path.read_bytes() for path in root.rglob("*") if path.is_file()})
            for relative, _, after in live_connection_overlay.patches():
                self.assertEqual((root / relative).read_text().count(after), 1, relative)
            self.assertTrue((root / "content/public/browser/arx_live_connection.h").is_file())
            self.assertTrue((root / "content/browser/renderer_host/arx_live_connection.cc").is_file())

    def test_spares_both_infinite_tabs_branches_and_nothing_else(self):
        policy = "".join(
            after for relative, _, after in live_connection_overlay.patches()
            if relative == live_connection_overlay.POLICY
        )
        self.assertEqual(policy.count("!holds_live_connection()"), 2)
        self.assertIn("features::kInfiniteTabsFreezing) &&", policy)
        self.assertIn("features::kInfiniteTabsFreezingOnMemoryPressure) &&", policy)
        self.assertNotIn("kVoting", policy)
        self.assertNotIn("kBatterySaver", policy)

    def test_reads_websocket_and_webtransport_features(self):
        native = (live_connection_overlay.__file__.rsplit("/Scripts/", 1)[0]
                  + "/Packages/engine/Native/content/arx_live_connection.cc")
        text = Path(native).read_text()
        for feature in ["kWebSocket,", "kWebSocketSticky", "kWebTransportSticky"]:
            self.assertIn(feature, text)
        self.assertIn("kArxSpareLiveConnections", text)

    @unittest.skipUnless(
        (SOURCE / live_connection_overlay.POLICY).is_file(),
        "needs the pinned engine source",
    )
    def test_anchors_match_the_pinned_source(self):
        # The pinned tree is already overlaid. Each anchor, or its replacement when this overlay
        # ran there, occurs exactly once.
        for relative, before, after in live_connection_overlay.patches():
            text = (SOURCE / relative).read_text()
            self.assertEqual(text.count(after) or text.count(before), 1, (relative, before))


if __name__ == "__main__":
    unittest.main()
