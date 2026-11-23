"""Run the real native journal/executor only under native-owned temporary roots."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.overlay import PACKAGE


class ProfileErasureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.executable = Path(cls.directory.name) / "profile-erasure"
        result = subprocess.run([
            "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
            "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
            "-I" + str(PACKAGE / "Native"),
            str(PACKAGE / "Native/profile_erasure/journal.cc"),
            str(Path(__file__).parent / "fixtures/profile_erasure.cc"),
            "-o", str(cls.executable),
        ], capture_output=True, text=True, timeout=40)
        if result.returncode:
            raise AssertionError(result.stderr)

    def test_owned_filesystem_and_process_authority(self):
        for scenario in ["clean", "same-cache", "legacy", "interruptions",
                         "crash-pending", "authority", "root-replacement",
                         "target-replacement", "symlinks", "ledger",
                         "late-recreation", "children", "interrupted-restart",
                         "cache-hardlink", "bounds", "verified-failure",
                         "failed-receipt", "root-ancestry", "verified-root", "ordinary-recovery", "unrecorded-helper",
                         "created-root", "created-same-parent", "created-data-replacement",
                         "created-cache-replacement", "created-parent-replacement",
                         "created-cache-parent-replacement", "created-parent-policy",
                         "created-failure", "created-process-move", "unproven-initial-boundary",
                         "boot-quarantine", "boot-same-cache", "boot-legacy", "boot-no-full-bypass",
                         "boot-partial-no-bypass", "boot-staging-save-failure",
                         "boot-stage-interruptions", "boot-resume-interruptions",
                         "boot-data-recreated", "boot-cache-recreated", "boot-late-recreation", "boot-qdata-replaced",
                         "boot-qcache-replaced", "boot-unavailable", "boot-startup-sealed",
                         "boot-seal-failure", "boot-old-schema", "boot-kernel", "boot-progress",
                         "device-renumbering", "device-renumbering-same-cache",
                         "device-ledger-replaced-target", "foreign-volume"]:
            with self.subTest(scenario=scenario):
                result = subprocess.run([str(self.executable), scenario],
                                        capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("ARX_ERASURE_POLICY_SUCCESS " + scenario, result.stdout)
