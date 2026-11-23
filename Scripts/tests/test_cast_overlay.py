"""Cast overlay (DEV-927): discovery comes back, the picker hook applies once, and nothing else."""
from pathlib import Path
import tempfile
import unittest

from Scripts.engine import build, cast_overlay


class CastOverlayTests(unittest.TestCase):
    def test_applies_once_to_an_upstream_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative, before, _ in cast_overlay.patches():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(before + "\n")
            cast_overlay.apply(root)
            first = {path: path.read_bytes() for path in root.rglob("*") if path.is_file()}
            cast_overlay.apply(root)
            self.assertEqual(first, {path: path.read_bytes() for path in root.rglob("*") if path.is_file()})
            for relative, _, after in cast_overlay.patches():
                self.assertEqual((root / relative).read_text().count(after), 1, relative)

    def test_restores_discovery_and_asks_arx_for_the_picker(self):
        after = {}
        for relative, _, text in cast_overlay.patches():
            after[relative] = after.get(relative, "") + text
        self.assertIn("ServiceDiscoveryDeviceLister::Create(", after[cast_overlay.LISTER])
        self.assertIn("service_discovery_client_.get()", after[cast_overlay.REGISTRY])
        self.assertIn("repeating_timer_->Start(", after[cast_overlay.DIAL])
        self.assertIn("arx::CastDialogFactoryHook()", after[cast_overlay.VIEWS_PARTS])
        self.assertIn('"https://google.com/cast#__castAppId__="', after[cast_overlay.MEDIA_SOURCE])

    def test_only_production_origins_come_back(self):
        restored = "".join(text for relative, _, text in cast_overlay.patches()
                           if relative in (cast_overlay.CAST_PROVIDER, cast_overlay.DIAL_PROVIDER))
        self.assertNotIn("qa.youtube.com", restored)
        self.assertIn("https://www.youtube.com", restored)

    def test_turns_on_only_helium_mdns_and_service_discovery(self):
        with tempfile.TemporaryDirectory() as directory:
            args = Path(directory) / "args.gn"
            args.write_text("enable_mdns=false\nenable_remoting=false\nenable_service_discovery=false\n")
            build.enable_cast_discovery(args)
            self.assertEqual(args.read_text(),
                             "enable_mdns=true\nenable_remoting=false\nenable_service_discovery=true\n")
            args.write_text("enable_mdns=false\n")
            with self.assertRaisesRegex(ValueError, "enable_service_discovery"):
                build.enable_cast_discovery(args)
            args.write_text("enable_mdns=true\nenable_service_discovery=false\n")
            with self.assertRaisesRegex(ValueError, "enable_mdns"):
                build.enable_cast_discovery(args)


if __name__ == "__main__":
    unittest.main()
