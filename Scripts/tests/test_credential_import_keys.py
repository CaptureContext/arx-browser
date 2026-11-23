"""Run the ABI46 credential import rules (DEV-830) from credential_import_keys.h without Chromium."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.overlay import PACKAGE


class CredentialImportKeysTests(unittest.TestCase):
    def test_rules(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "keys"
            compiled = subprocess.run(
                ["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
                 "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                 "-I", str(PACKAGE / "Native"),
                 str(Path(__file__).parent / "fixtures/credential_import_keys.cc"), "-o", str(executable)],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
