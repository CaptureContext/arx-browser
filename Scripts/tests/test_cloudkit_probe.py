"""The CloudKit probe's verdict and its checks of the signed app, without launching it."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from Scripts import cloudkit_probe


CONTAINER = "iCloud.dev.capturecontext.arx"


class ParseTests(unittest.TestCase):
    def test_any_returned_status_means_the_container_was_reached(self):
        for status in ("available", "noAccount", "temporarilyUnavailable"):
            output = f"noise\nARX_CLOUDKIT_PROBE container={CONTAINER} result=returned status={status}\n"
            self.assertEqual(cloudkit_probe.parse(output), (status, None))

    def test_errors_timeouts_and_silence_fail(self):
        cases = {
            f"ARX_CLOUDKIT_PROBE container={CONTAINER} result=error domain=CKErrorDomain code=9": "did not answer",
            f"ARX_CLOUDKIT_PROBE container={CONTAINER} result=timeout": "did not answer",
            "ARX_CLOUDKIT_PROBE container=iCloud.other result=returned status=available": "iCloud.other",
            "Killed: 9": "no ARX_CLOUDKIT_PROBE line",
        }
        for output, problem in cases.items():
            status, message = cloudkit_probe.parse(output)
            self.assertIsNone(status, output)
            self.assertIn(problem, message)


class ProbeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.app = Path(directory.name) / "Arx.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)

    def test_app_without_a_profile_is_not_launched(self):
        with patch.object(cloudkit_probe.subprocess, "run") as run, self.assertRaisesRegex(ValueError, "no embedded provisioning profile"):
            cloudkit_probe.probe(self.app)
        run.assert_not_called()

    def test_app_without_the_container_entitlement_is_not_launched(self):
        (self.app / "Contents/embedded.provisionprofile").write_bytes(b"profile")
        with (
            patch.object(cloudkit_probe, "entitlements", return_value={}),
            patch.object(cloudkit_probe.subprocess, "run") as run,
            self.assertRaisesRegex(ValueError, "not signed with"),
        ):
            cloudkit_probe.probe(self.app)
        run.assert_not_called()

    def test_launches_the_app_executable_with_the_probe_argument(self):
        (self.app / "Contents/embedded.provisionprofile").write_bytes(b"profile")
        answer = subprocess.CompletedProcess([], 0, stdout=f"ARX_CLOUDKIT_PROBE container={CONTAINER} result=returned status=available\n", stderr="")
        signed = {
            "com.apple.developer.icloud-container-identifiers": [CONTAINER],
            "com.apple.developer.icloud-container-environment": "Development",
        }
        with (
            patch.object(cloudkit_probe, "entitlements", return_value=signed),
            patch.object(cloudkit_probe.subprocess, "run", return_value=answer) as run,
        ):
            self.assertEqual(cloudkit_probe.probe(self.app), "available")
        self.assertEqual(run.call_args.args[0], [str(self.app / "Contents/MacOS/Arx"), "--arx-cloudkit-probe"])

    def test_a_killed_app_reports_its_exit(self):
        (self.app / "Contents/embedded.provisionprofile").write_bytes(b"profile")
        killed = subprocess.CompletedProcess([], -9, stdout="", stderr="")
        with (
            patch.object(cloudkit_probe, "entitlements", return_value={"com.apple.developer.icloud-container-identifiers": [CONTAINER]}),
            patch.object(cloudkit_probe.subprocess, "run", return_value=killed),
            self.assertRaisesRegex(ValueError, "exit -9"),
        ):
            cloudkit_probe.probe(self.app)


if __name__ == "__main__":
    unittest.main()


class BuildTests(unittest.TestCase):
    def test_builds_debug_even_when_release_is_configured(self):
        with (
            patch.dict(os.environ, {"CONFIGURATION": "Release"}),
            patch.object(cloudkit_probe.build_app, "main", return_value=Path("/Arx.app")) as build,
            patch.object(cloudkit_probe, "run"),
            patch.object(cloudkit_probe, "probe"),
        ):
            cloudkit_probe.main()
        self.assertEqual(build.call_args.kwargs["configuration"], "Debug")
