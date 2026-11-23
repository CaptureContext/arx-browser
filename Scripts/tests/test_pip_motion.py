"""Picture in Picture motion math (DEV-825): throws, snapping, pinch and springs."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.config import PACKAGE

FIXTURE = Path(__file__).parent / "fixtures/pip-motion/pip_motion_test.cc"


class PipMotionTests(unittest.TestCase):
    def test_projection_snapping_pinch_and_spring(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "pip_motion_test"
            result = subprocess.run(
                ["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                 "-fsanitize=address,undefined", "-I", str(PACKAGE / "Native"),
                 str(FIXTURE), "-o", str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
