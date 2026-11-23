"""Compile exact click dispatch/lifetime bodies with deterministic native peers."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine import inspection_overlay
from Scripts.engine.config import PACKAGE
from Scripts.tests.test_inspection_native import section


class ReferenceClickNativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        root = Path(cls.directory.name)
        browser = (PACKAGE / "Native/inspection_bridge.mm").read_text()
        fixture = (Path(__file__).parent / "fixtures/reference_click_policy.cc").read_text()
        replacements = {
            "// PRODUCTION_BLINK_CLICK": inspection_overlay.CLICK_HELPER,
            "// PRODUCTION_PENDING": section(browser, "  struct PendingClick {", "  struct Pending {"),
            "// PRODUCTION_SUBMIT_CANCEL": section(browser, "  void Click(", "  bool Current("),
            "// PRODUCTION_RECEIVE_DELIVER": section(browser, "  void ReceivedClick(", "  const uint64_t page_;"),
        }
        for marker, code in replacements.items():
            fixture = fixture.replace(marker, code)
        (root / "contract.cc").write_text(fixture)
        cls.executable = root / "contract"
        result = subprocess.run(
            ["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
             "-fsanitize=address,undefined", "-I", str(PACKAGE / "Native/inspection"),
             "-I", str(PACKAGE / "Sources/ChromiumBridge/include"),
             str(root / "contract.cc"), "-o", str(cls.executable)],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode:
            raise AssertionError(result.stderr)

    def run_scenario(self, name):
        result = subprocess.run([str(self.executable), name], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_post_layout_identity_eligibility_and_authority_before_first_event(self):
        self.run_scenario("atomic")

    def test_receipts_never_evict_replay_or_disclose_another_binding(self):
        self.run_scenario("receipts")

    def test_cancel_keeps_physical_capacity_and_late_dispatch_preserves_receipt(self):
        self.run_scenario("physical")

    def test_clean_hover_keeps_its_snapshot_and_other_actions_consume_it(self):
        self.run_scenario("pointer")
