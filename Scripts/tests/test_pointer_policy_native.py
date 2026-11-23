"""Compile the pointer and keyboard payload parsers and the snapshot consumption rule."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.config import PACKAGE


class PointerPolicyNativeTests(unittest.TestCase):
    def test_canonical_payload_and_non_consuming_hover(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "pointer"
            compiled = subprocess.run(
                ["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror", "-fsanitize=address,undefined",
                 "-I", str(PACKAGE / "Native/inspection"),
                 str(Path(__file__).parent / "fixtures/pointer_policy.cc"), "-o", str(binary)],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)

    def test_key_chord_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "keyboard"
            compiled = subprocess.run(
                ["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror", "-fsanitize=address,undefined",
                 "-I", str(PACKAGE / "Native/inspection"),
                 str(Path(__file__).parent / "fixtures/keyboard_policy.cc"), "-o", str(binary)],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)
