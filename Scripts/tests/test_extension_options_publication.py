"""Execute exact native ownership publication and failed initial-offer rollback."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from Scripts.engine.config import PACKAGE
from Scripts.tests.test_media_freeze import method


class ExtensionOptionsPublicationTests(unittest.TestCase):
    def test_reentrant_caller_loss_revokes_before_destroy_and_preserves_user_replacement(self):
        native = (PACKAGE / "Native/engine_bridge.mm").read_text()
        source = (Path(__file__).parent / "fixtures/extension_options_publication.cc").read_text()
        source = source.replace("// PRODUCTION_PUBLICATION", method(native, "bool AdoptExtensionOptionsImpl("))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.cc").write_text(source)
            result = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                str(root / "test.cc"), "-o", str(root / "test"),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "test")], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
