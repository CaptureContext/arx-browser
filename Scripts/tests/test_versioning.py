"""The marketing version and the build number in the XcodeGen settings (DEV-837)."""

import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from Scripts import release, tasks, versioning


SETTINGS = """settings:
  base:
    SWIFT_VERSION: '6.0'
    MARKETING_VERSION: 0.1.0
    CURRENT_PROJECT_VERSION: '0'
    DEVELOPMENT_LANGUAGE: en
"""


class VersioningTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.settings = Path(directory.name) / "settings.yml"
        self.settings.write_text(SETTINGS)

    def test_reads_both_values(self):
        self.assertEqual(versioning.marketing_version(self.settings), "0.1.0")
        self.assertEqual(versioning.build_number(self.settings), 0)

    def test_each_release_build_takes_the_next_number_and_keeps_it(self):
        self.assertEqual(versioning.next_build_number(self.settings, environment={}), 1)
        self.assertEqual(versioning.next_build_number(self.settings, environment={}), 2)
        self.assertEqual(versioning.build_number(self.settings), 2)
        text = self.settings.read_text()
        self.assertIn("    CURRENT_PROJECT_VERSION: '2'\n", text)
        self.assertIn("    MARKETING_VERSION: 0.1.0\n", text)
        self.assertIn("    SWIFT_VERSION: '6.0'\n", text)

    def test_a_ci_build_number_wins_and_is_checked(self):
        self.assertEqual(versioning.next_build_number(self.settings, environment={"ARX_BUILD_NUMBER": "41"}), 41)
        self.assertEqual(versioning.build_number(self.settings), 41)
        for bad in ("0", "-3", "4.1", "next"):
            with self.assertRaises(ValueError):
                versioning.next_build_number(self.settings, environment={"ARX_BUILD_NUMBER": bad})

    def test_the_marketing_version_is_semantic_and_leaves_the_build_number_alone(self):
        versioning.next_build_number(self.settings, environment={})
        self.assertEqual(versioning.set_marketing_version(" 0.2.0 ", self.settings), "0.2.0")
        self.assertEqual(versioning.marketing_version(self.settings), "0.2.0")
        self.assertEqual(versioning.build_number(self.settings), 1)
        for bad in ("0.2", "v0.2.0", "01.2.0", "0.2.0-beta"):
            with self.assertRaises(ValueError):
                versioning.set_marketing_version(bad, self.settings)

    def test_a_settings_file_without_the_keys_fails(self):
        self.settings.write_text("settings:\n  base:\n    SWIFT_VERSION: '6.0'\n")
        with self.assertRaises(ValueError):
            versioning.marketing_version(self.settings)
        with self.assertRaises(ValueError):
            versioning.next_build_number(self.settings, environment={})

    def test_release_build_passes_the_new_number_to_xcode(self):
        with patch.object(versioning, "SETTINGS", self.settings), \
                patch.object(release.build_app, "main", return_value=Path("/tmp/Arx.app")) as build, \
                patch.object(release, "stage"), patch.dict("os.environ", {"ARX_BUILD_NUMBER": ""}):
            release.build()
        settings = build.call_args.kwargs["build_settings"]
        self.assertIn("CURRENT_PROJECT_VERSION=1", settings)
        self.assertIn("MARKETING_VERSION=0.1.0", settings)

    def test_make_version_takes_its_argument(self):
        with patch.dict(tasks.COMMANDS, {"version": Mock(return_value=0)}):
            self.assertEqual(tasks.main(["version", "0.2.0"]), 0)
            tasks.COMMANDS["version"].assert_called_once_with(["0.2.0"])


if __name__ == "__main__":
    unittest.main()
