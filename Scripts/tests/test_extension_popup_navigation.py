"""Execute the real popup navigation delegate with bounded browser ownership peers."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from Scripts.engine.config import PACKAGE
from Scripts.tests.test_media_freeze import method


class ExtensionPopupNavigationTests(unittest.TestCase):
    def test_actual_delegate_source_child_document_and_resume_admission(self):
        native = (PACKAGE / "Native/extension_action_host.mm").read_text()
        source = (Path(__file__).parent / "fixtures/extension_popup_navigation.cc").read_text()
        source = source.replace("// PRODUCTION_HOST", method(native, "class NavigableExtensionViewHost") + ";")
        # DEV-1316: each popup has its own ID, epoch and pending close.
        scoped = method(native, "  void RunPopupScoped(uint64_t id, base::OnceClosure action)").replace("Impl", "CallOwner")
        close_prefix = method(native, "  void ClosePopup(Popup& popup)").split("    auto found = ", 1)[0]
        source = source.replace("// CALL_SCOPE", scoped)
        source = source.replace("// CLOSE_PREFIX", close_prefix)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.cc").write_text(source)
            result = subprocess.run([
                "xcrun", "clang++", "-std=c++23", "-Wall", "-Wextra", "-Werror",
                "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                "-I", str(PACKAGE / "Native"),
                str(root / "test.cc"), "-o", str(root / "test"),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "test")], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
