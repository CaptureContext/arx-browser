"""Check task orchestration and failure propagation without invoking Xcode."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from Scripts import project, tasks, test_all
from Scripts.core.process import run


class TaskTests(unittest.TestCase):
    def test_tool_failure_reaches_make(self):
        failure = subprocess.CalledProcessError(42, ["xcodegen"])
        with (
            patch.object(project.generate_xcodeproj, "main", side_effect=failure),
            patch.object(project.generate_xcworkspace, "main") as workspace,
        ):
            self.assertEqual(tasks.main(["project"]), 42)
        workspace.assert_not_called()

    def test_full_validation_stops_at_first_failure(self):
        completed = []
        def fail():
            completed.append("test")
            raise subprocess.CalledProcessError(9, ["swift", "test"])
        with (
            patch.object(test_all.check, "main", side_effect=lambda: completed.append("check")),
            patch.object(test_all.test, "main", side_effect=fail),
            patch.object(test_all.build_package, "main") as package_build,
            patch.object(test_all.build_app, "main") as app_build,
        ):
            self.assertEqual(tasks.main(["test-all"]), 9)
        self.assertEqual(completed, ["check", "test"])
        package_build.assert_not_called()
        app_build.assert_not_called()

    def test_logged_build_failure_reaches_make(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                run([sys.executable, "-c", "raise SystemExit(7)"], log="failure.log", cwd=Path(directory))
            self.assertEqual(failure.exception.returncode, 7)
            self.assertTrue((Path(directory) / "build/logs/failure.log").is_file())

if __name__ == "__main__":
    unittest.main()
