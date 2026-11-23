"""Execute the exact nearest-container scroll helper with deterministic peers."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.config import PACKAGE


class ReferenceScrollNativeTests(unittest.TestCase):
    def test_atomic_identity_container_resolution_and_bounded_offset_application(self):
        contract = (PACKAGE / "Native/inspection/scroll_action_contract.h").read_text()
        contract = contract[contract.index("enum class ArxScrollAxis"):contract.index("// Resolves one")]
        fixture = (Path(__file__).parent / "fixtures/reference_scroll_policy.cc").read_text()
        fixture = fixture.replace("// PRODUCTION_SCROLL_CONTRACT", contract)
        fixture = fixture.replace("// PRODUCTION_SCROLL_HELPER", (PACKAGE / "Native/inspection/scroll_action_helper.inc").read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "scroll.cc"
            source.write_text(fixture)
            binary = root / "scroll"
            compiled = subprocess.run(
                ["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror", "-fsanitize=address,undefined",
                 str(source), "-o", str(binary)], capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)
