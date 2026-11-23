"""Compile and execute the exact production one-use close policy with sanitizers."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.overlay import PACKAGE


class CloseAuthorityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.executable = Path(cls.directory.name) / "close-authority"
        result = subprocess.run([
            "xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
            "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
            "-I" + str(PACKAGE / "Native"),
            "-I" + str(PACKAGE / "Sources/ChromiumBridge/include"),
            str(Path(__file__).parent / "fixtures/close_authority.cc"),
            "-o", str(cls.executable),
        ], capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise AssertionError(result.stderr)

    def test_production_policy(self):
        for scenario in ["cancel-slot", "navigation-pending", "navigation-approved",
                         "reset-retry", "weak-document", "replay-other-page", "refused-cancel-approved", "invalid"]:
            with self.subTest(scenario=scenario):
                result = subprocess.run([str(self.executable), scenario],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
