"""Execute native fixture construction; signing peers do not verify CRX signatures."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from Scripts.tests.test_media_freeze import method

NATIVE = Path(__file__).parents[2] / "Packages/engine/Native/extensions_bridge.mm"
FIXTURE = Path(__file__).parent / "fixtures/extension_fixture_generation.cc"


class ExtensionFixtureGenerationTests(unittest.TestCase):
    def test_signed_escalation_unpacked_messaging_and_complete_update_resources(self):
        native = NATIVE.read_text()
        names = ("kFixtureManifest", "kFixtureNative", "kFixtureWorker", "kFixtureContent", "kFixturePopup", "kFixtureRules")
        constants = []
        for name in names:
            match = re.search(r"constexpr char " + name + r'\[\] = R"\((.*?)\)";', native, re.S)
            self.assertIsNotNone(match, name)
            constants.append(match.group(0))
        source = FIXTURE.read_text().replace("// COMPILED_CONSTANTS", "\n".join(constants))
        source = source.replace("// PREPARE_SIGNED", method(native, "bool PrepareInstallFixtures("))
        source = source.replace("// INITIALIZE", method(native, "bool InitializeExtensions("))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "fixture.cc").write_text(source)
            binary = root / "fixture"
            result = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                "-fsanitize=address,undefined", str(root / "fixture.cc"), "-o", str(binary),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary), str(root)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            first = json.loads((root / "signed/extension/manifest.json").read_text())
            second = json.loads((root / "signed/extension-v2/manifest.json").read_text())
            ordinary = json.loads((root / "unpacked/extension/manifest.json").read_text())
            self.assertEqual(first["version"], "1.0")
            # DEV-968: the install review names the manifest's author as the publisher.
            self.assertEqual(first["author"], "CaptureContext fixtures")
            self.assertEqual(set(first["permissions"]), {"storage", "declarativeNetRequest", "contextMenus"})
            self.assertEqual(second["version"], "2.0")
            self.assertEqual(set(second["permissions"]), {*first["permissions"], "tabs", "nativeMessaging"})
            self.assertEqual(set(ordinary["permissions"]), {*first["permissions"], "nativeMessaging"})
            for manifest in (first, second, ordinary):
                self.assertEqual(len(manifest["permissions"]), len(set(manifest["permissions"])))
            referenced = [second["options_ui"]["page"], second["action"]["default_popup"]]
            for name in referenced:
                original = root / "signed/extension" / name
                updated = root / "signed/extension-v2" / name
                self.assertEqual(updated.read_bytes(), original.read_bytes())
                scripts = re.findall(r"<script src=([^ >]+)", updated.read_text())
                self.assertTrue(scripts)
                for script in scripts:
                    self.assertEqual((updated.parent / script).read_bytes(), (original.parent / script).read_bytes())
