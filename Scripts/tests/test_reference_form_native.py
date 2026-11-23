"""Execute the production form preflight/baseline/setter with deterministic peers."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.config import PACKAGE


class ReferenceFormNativeTests(unittest.TestCase):
    def test_property_baselines_atomic_setters_bounds_and_reentrant_effects(self):
        contract = (PACKAGE / "Native/inspection/form_action_contract.h").read_text()
        contract = contract[contract.index("enum class ArxFormBaselineStatus"):contract.index("BLINK_EXPORT ArxFormBaselineStatus")]
        fixture = (Path(__file__).parent / "fixtures/reference_form_policy.cc").read_text()
        fixture = fixture.replace("// PRODUCTION_FORM_CONTRACT", contract)
        fixture = fixture.replace("// PRODUCTION_FORM_HELPER", (PACKAGE / "Native/inspection/form_action_helper.inc").read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "form.cc"
            source.write_text(fixture)
            binary = root / "form"
            compiled = subprocess.run(
                ["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror", "-fsanitize=address,undefined",
                 str(source), "-o", str(binary)], capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=5)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)
