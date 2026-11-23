"""Generation contracts without invoking Xcode or touching the real workspace."""

from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as XML

from Scripts.generate_xcworkspace import groups
from Scripts.tools import xcodegen, xcworkspace


class GenerationTests(unittest.TestCase):
    def test_workspace_discovers_only_real_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["features", "core"]:
                package = root / "Packages" / name
                package.mkdir(parents=True)
                (package / "Package.swift").touch()
            (root / "Packages/unused").mkdir()
            first = xcworkspace.contents(groups(root))
            self.assertEqual(first, xcworkspace.contents(groups(root)))
            workspace = XML.fromstring(first)
            self.assertIsNone(workspace.find("Group"))
            locations = [node.attrib["location"] for node in workspace.findall("FileRef")]
            self.assertEqual(locations, [
                "group:Project.xcodeproj", "group:.", "group:Packages/core", "group:Packages/features",
            ])

    def test_regeneration_preserves_workspace_settings_and_escapes_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            settings = root / "Project.xcworkspace/xcuserdata/settings"
            settings.parent.mkdir(parents=True)
            settings.write_text("keep")
            references = ["Project.xcodeproj", ".", "Packages/A&B"]
            xcworkspace.generate(root, name="Project", groups=references)
            content = root / "Project.xcworkspace/contents.xcworkspacedata"
            before = content.read_bytes()
            xcworkspace.generate(root, name="Project", groups=references)
            self.assertEqual(content.read_bytes(), before)
            self.assertEqual(settings.read_text(), "keep")
            self.assertEqual(XML.fromstring(before)[2].attrib["location"], "group:Packages/A&B")

    def test_project_supports_unsigned_generation_without_mutating_environment(self):
        environment = {"PATH": "/tools"}
        with patch.object(xcodegen, "run") as run:
            xcodegen.generate(Path("/project"), environment=environment)
        self.assertEqual(environment, {"PATH": "/tools"})
        run.assert_called_once_with(
            ["xcodegen", "generate", "--spec", "project.yml"],
            cwd=Path("/project"), env={"PATH": "/tools", "DEVELOPMENT_TEAM": ""},
        )

    def test_invalid_signing_team_prevents_generation(self):
        with patch.object(xcodegen, "run") as run:
            with self.assertRaises(ValueError):
                xcodegen.generate(Path("/project"), environment={"DEVELOPMENT_TEAM": "invalid"})
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
