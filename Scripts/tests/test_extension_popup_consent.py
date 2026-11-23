"""Execute production popup load ordering, consent revocation and safe teardown."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from Scripts.engine.config import PACKAGE
from Scripts.tests.test_media_freeze import method


class ExtensionPopupConsentTests(unittest.TestCase):
    def test_modal_delegate_reclaimed_after_chrome_load_and_stale_retry_refused(self):
        native = (PACKAGE / "Native/page_consent_host.mm").read_text()
        action = (PACKAGE / "Native/extension_action_host.mm").read_text()
        configure = method(native, "  void Configure(bool enabled)")
        # Execute the real C++ revocation/delegate-binding prefix. AppKit view
        # attachment begins at this exact boundary and is outside this harness.
        prefix = configure.split("    if (enabled) {", 1)[0]
        source = (Path(__file__).parent / "fixtures/extension_popup_consent.cc").read_text()
        source = source.replace("// CONFIGURE_PREFIX", prefix)
        source = source.replace("// SHUTDOWN", method(native, "  void ShutDown()"))
        source = source.replace("// HOST_SUBCLASS", method(action, "class ConsentExtensionViewHost") + ";")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.cc").write_text(source)
            result = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-I", str(PACKAGE / "Native"),
                str(root / "test.cc"), "-o", str(root / "test"),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "test")], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
