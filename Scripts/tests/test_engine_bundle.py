"""Reject unusable runtime bundles without launching Chromium or requiring Xcode."""

from contextlib import ExitStack, redirect_stdout
import io
import json
import plistlib
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from Scripts import build_app
from Scripts.engine import artifact, bundle, cache, embed, fetch


class EngineBundleTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.framework = self.root / bundle.LOCK["framework"]
        self.version = self.framework / "Versions" / bundle.LOCK["chromium"]
        self.version.mkdir(parents=True)
        (self.framework / "Versions/Current").symlink_to(bundle.LOCK["chromium"])
        for name in ("Arx Framework", "Helpers", "Libraries", "Resources"):
            (self.framework / name).symlink_to(f"Versions/Current/{name}")
        self.write("Arx Framework", executable=True)
        for name in bundle.HELPERS:
            contents = f"Helpers/{name}.app/Contents"
            self.write(f"{contents}/Info.plist", plistlib.dumps({"CFBundleExecutable": name}))
            self.write(f"{contents}/MacOS/{name}", executable=True)
        for name in ("app_mode_loader", "chrome_crashpad_handler", "web_app_shortcut_copier"):
            self.write(f"Helpers/{name}", executable=True)
        for name in bundle.LIBRARIES:
            self.write(f"Libraries/{name}", executable=True)
        for name in bundle.RESOURCES:
            self.write(f"Resources/{name}")
        self.write("Resources/Info.plist", plistlib.dumps({
            "CFBundleVersion": bundle.LOCK["helium_macos"]["version"],
            "CFBundleIdentifier": bundle.LOCK["bundle_id"] + ".framework",
            "CFBundleExecutable": "Arx Framework",
        }))
        self.run = self.stack.enter_context(patch.object(bundle, "run", return_value="arm64\n"))

    def write(self, path, data=b"fixture", *, executable=False):
        destination = self.version / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        if executable:
            destination.chmod(0o755)

    def test_fetch_and_validate_from_a_file_url(self):
        """DEV-1282: make engine-fetch engine-validate with only the manifest in git."""
        published = self.root / "release/arx-engine-macos-arm64.tar.gz"
        published.parent.mkdir()
        with tarfile.open(published, "w:gz") as archive:
            archive.add(self.framework, arcname=self.framework.name)
        identity = {"sources": "c" * 64, "architecture": "arm64"}
        for target, name, value in [
            (cache, "ARCHIVES", self.root / "Artifacts/Engine"),
            (cache, "DOWNLOADS", self.root / "downloads"),
            (cache, "RESTORED", self.root / "restored"),
        ]:
            self.stack.enter_context(patch.object(target, name, value))
        self.stack.enter_context(patch.object(artifact, "identity", return_value=identity))
        self.stack.enter_context(patch.object(artifact, "available", return_value=False))
        tracked, manifest = cache.paths()
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({
            "schema": 1, "identity": identity, "framework": cache.LOCK["framework"],
            "chromium": cache.LOCK["chromium"], "archive": tracked.name,
            "sha256": cache.checksum(published), "bytes": published.stat().st_size, "url": published.as_uri(),
        }))
        with redirect_stdout(io.StringIO()):
            fetch.main()
        self.assertFalse(tracked.exists())
        self.assertEqual(bundle.require(), cache.restored_directory() / cache.LOCK["framework"])

    def test_complete_bundle_checks_every_native_binary_architecture(self):
        bundle.validate_framework(self.framework, architectures=["arm64"])
        checked = {call.args[0][-1] for call in self.run.call_args_list}
        self.assertIn(str(self.version / "Helpers/Arx Helper (Renderer).app/Contents/MacOS/Arx Helper (Renderer)"), checked)
        self.assertEqual(len(checked), 1 + len(bundle.HELPERS) + 3 + len(bundle.LIBRARIES))

    def test_missing_resource_or_helper_fails_before_launch(self):
        for relative in ("Resources/icudtl.dat", "Helpers/Arx Helper (Renderer).app/Contents/MacOS/Arx Helper (Renderer)"):
            path = self.version / relative
            contents = path.read_bytes()
            mode = path.stat().st_mode
            path.unlink()
            with self.assertRaisesRegex(ValueError, "missing a required file"):
                bundle.validate_framework(self.framework)
            path.write_bytes(contents)
            path.chmod(mode)

    def test_wrong_helper_architecture_is_rejected(self):
        self.run.side_effect = lambda command, **kwargs: "x86_64" if "(Renderer)" in command[-1] else "arm64"
        with self.assertRaisesRegex(ValueError, "architectures.*x86_64"):
            bundle.validate_framework(self.framework, architectures=["arm64"])

    def test_misplaced_framework_link_is_rejected(self):
        (self.framework / "Resources").unlink()
        (self.framework / "Resources").symlink_to("Versions/Current/Helpers")
        with self.assertRaisesRegex(ValueError, "misplaced Resources link"):
            bundle.validate_framework(self.framework)

    def test_helper_without_executable_permission_is_rejected(self):
        (self.version / "Helpers/chrome_crashpad_handler").chmod(0o644)
        with self.assertRaisesRegex(ValueError, "execute permission"):
            bundle.validate_framework(self.framework)

    def test_wrong_framework_metadata_is_rejected(self):
        self.write("Resources/Info.plist", plistlib.dumps({"CFBundleVersion": "old"}))
        with self.assertRaisesRegex(ValueError, "metadata does not match"):
            bundle.validate_framework(self.framework)

    def test_required_embedding_fails_when_engine_is_absent(self):
        with (
            patch.dict("os.environ", {"TARGET_BUILD_DIR": str(self.root), "FRAMEWORKS_FOLDER_PATH": "Frameworks", "ARX_REQUIRE_ENGINE": "1"}),
            patch.object(cache, "available", return_value=False),
            patch.object(cache, "require", side_effect=ValueError("No matching engine")),
        ):
            with self.assertRaisesRegex(ValueError, "No matching engine"):
                embed.main()

    def test_required_build_passes_requirement_to_xcode_and_validates_product(self):
        with (
            patch.object(build_app, "prepare"),
            patch.object(build_app, "require_mcp_helper"),
            patch.object(build_app, "run", return_value="[]") as run,
            patch.object(build_app, "application_path", return_value=self.root / "Arx.app"),
            patch.object(bundle, "require") as require,
            patch.object(bundle, "validate_application") as validate,
        ):
            build_app.main(require_engine=True)
        require.assert_called_once()
        validate.assert_called_once_with(self.root / "Arx.app")
        self.assertTrue(all("ARX_REQUIRE_ENGINE=1" in call.args[0] for call in run.call_args_list))

    def test_runtime_requirement_does_not_leak_into_preview_builds(self):
        with (
            patch.dict("os.environ", {"ARX_REQUIRE_ENGINE": "1"}),
            patch.object(build_app, "prepare"),
            patch.object(build_app, "require_mcp_helper"),
            patch.object(build_app, "run", return_value="[]"),
            patch.object(build_app, "application_path", return_value=self.root / "Preview.app"),
            patch.object(bundle, "require") as require,
        ):
            build_app.main(scheme="AppUIPreview")
        require.assert_not_called()


class EngineFetchTests(unittest.TestCase):
    def test_stale_manifest_fails_before_any_download(self):
        with (
            patch.object(cache, "metadata", side_effect=ValueError("stale engine")),
            patch.object(fetch, "download") as download,
        ):
            with self.assertRaisesRegex(ValueError, "stale engine"):
                fetch.main()
        download.assert_not_called()

    def test_verified_local_archive_requires_no_network(self):
        with (
            patch.object(cache, "metadata", return_value={}),
            patch.object(cache, "restored_available", return_value=False),
            patch.object(cache, "locate", return_value=(Path("engine.tar.gz"), [])),
            patch.object(fetch, "download") as download,
            patch.object(cache, "unpack") as unpack,
            redirect_stdout(io.StringIO()),
        ):
            fetch.main()
        download.assert_not_called()
        unpack.assert_called_once_with(Path("engine.tar.gz"), {})
