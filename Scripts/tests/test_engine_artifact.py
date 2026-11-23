"""Reject incomplete/stale engine builds and avoid embedding them into the app."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from Scripts.engine import artifact, cache, embed


class EngineArtifactTests(unittest.TestCase):
    def test_framework_requires_matching_completion_stamp(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            framework = root / "Engine.framework"
            binary = framework / "Versions" / artifact.LOCK["chromium"] / "Arx Framework"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"binary")
            stamp = root / "artifact.json"
            with patch.object(artifact, "FRAMEWORK", framework), patch.object(artifact, "STAMP", stamp):
                self.assertFalse(artifact.available())
                artifact.complete()
                self.assertTrue(artifact.available())
                stamp.write_text(json.dumps({"sources": "old", "architecture": "arm64"}))
                self.assertFalse(artifact.available())
                with self.assertRaises(ValueError):
                    artifact.require()

    def test_new_branding_needs_a_new_build(self):
        """DEV-1100: a changed render or branding overlay invalidates a built framework."""
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "Packages/engine"
            (package / "Branding").mkdir(parents=True)
            logo = package / "Branding/product_logo_256.png"
            logo.write_bytes(b"Arx")
            overlay = Path(directory) / "Scripts/engine/branding_overlay.py"
            overlay.parent.mkdir(parents=True)
            overlay.write_text("# overlay")
            with patch.object(artifact, "PACKAGE", package):
                first = artifact.identity()
                logo.write_bytes(b"Arx, rendered again")
                second = artifact.identity()
                overlay.write_text("# overlay, changed")
                third = artifact.identity()
            self.assertNotEqual(first, second)
            self.assertNotEqual(second, third)

    def test_missing_engine_removes_stale_embedded_framework(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "Arx.app/Contents/Frameworks" / embed.LOCK["framework"]
            destination.mkdir(parents=True)
            (destination / "old-binary").touch()
            with patch.dict("os.environ", {
                "TARGET_BUILD_DIR": directory,
                "FRAMEWORKS_FOLDER_PATH": "Arx.app/Contents/Frameworks",
                "ARX_REQUIRE_ENGINE": "0",
            }), patch.object(cache, "available", return_value=False):
                embed.main()
            self.assertFalse(destination.exists())
