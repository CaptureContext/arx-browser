"""Execute source/document/profile admission immediately before command dispatch."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from Scripts.engine.config import PACKAGE
from Scripts.tests.test_media_freeze import method


class ExtensionCommandSourceTests(unittest.TestCase):
    def test_delayed_command_cannot_borrow_rehost_navigation_or_replaced_extension(self):
        native = (PACKAGE / "Native/extension_action_host.mm").read_text()
        source = (Path(__file__).parent / "fixtures/extension_command_source.cc").read_text()
        for marker, signature in [
            ("HANDLE_SHORTCUT", "  bool HandleShortcut(const input::NativeWebKeyboardEvent& event)"),
            ("SOURCE_CURRENT", "  bool SourceCurrent() const"),
            ("ALLOWED", "  bool Allowed("),
            ("RUN_COMMAND", "  void RunCommand("),
        ]:
            production = method(native, signature).replace("&Impl::RunCommand", "&Owner::RunCommand")
            if marker == "HANDLE_SHORTCUT":
                # Objective-C property access is represented by C++ field peers;
                # no native admission/dispatch branch is changed or omitted.
                production = production.replace("native.", "native->").replace("view.window", "view->window")
            source = source.replace("// " + marker, production)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "test.cc").write_text(source)
            result = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                "-I", str(PACKAGE / "Native"),
                str(root / "test.cc"), "-o", str(root / "test"),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "test")], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
