"""Exercise portable cache restore without a Chromium checkout or build tools."""

from contextlib import ExitStack, redirect_stdout
import io
import json
import shutil
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from Scripts.engine import archive, artifact, cache, fetch


class ArchiveFixture:
    """A small fake framework archive and its manifest; never the real engine."""

    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(redirect_stdout(io.StringIO()))
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.stack.enter_context(patch.object(cache, "ARCHIVES", self.root / "artifacts"))
        self.stack.enter_context(patch.object(cache, "RESTORED", self.root / "restored"))
        self.stack.enter_context(patch.object(cache, "DOWNLOADS", self.root / "downloads"))
        self.stack.enter_context(patch.object(artifact, "identity", return_value={"sources": "a" * 64, "architecture": "arm64"}))
        self.stack.enter_context(patch.object(artifact, "available", return_value=False))
        self.archive, self.manifest = cache.paths()
        self.archive.parent.mkdir()
        framework = self.root / "input" / cache.LOCK["framework"]
        version = framework / "Versions" / cache.LOCK["chromium"]
        for name in ["Helpers", "Libraries", "Resources"]:
            (version / name).mkdir(parents=True)
        binary = version / "Arx Framework"
        binary.write_bytes(b"fixture executable")
        binary.chmod(0o755)
        (framework / "Versions/Current").symlink_to(cache.LOCK["chromium"])
        (framework / "Arx Framework").symlink_to("Versions/Current/Arx Framework")
        with tarfile.open(self.archive, "w:gz") as bundle:
            bundle.add(framework, arcname=framework.name)
        self.write_manifest()

    def write_manifest(self):
        data = {"schema": 1, "identity": artifact.identity(), "framework": cache.LOCK["framework"],
                "chromium": cache.LOCK["chromium"], "archive": self.archive.name,
                "sha256": cache.checksum(self.archive), "bytes": self.archive.stat().st_size}
        self.manifest.write_text(json.dumps(data))


class EngineCacheTests(ArchiveFixture, unittest.TestCase):
    def test_restore_preserves_framework_links_and_executable_mode(self):
        self.assertFalse(cache.available())
        cache.restore()
        framework = cache.require()
        self.assertEqual(framework, cache.restored_directory() / cache.LOCK["framework"])
        self.assertTrue((framework / "Versions/Current").is_symlink())
        self.assertEqual((framework / "Arx Framework").read_bytes(), b"fixture executable")
        self.assertTrue((framework / "Arx Framework").stat().st_mode & 0o111)
        stamp = cache.restored_directory() / "artifact.json"
        first_time = stamp.stat().st_mtime_ns
        cache.restore()
        self.assertEqual(stamp.stat().st_mtime_ns, first_time)

    def test_corrupt_archive_is_rejected_before_extraction(self):
        self.archive.write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "size mismatch"):
            cache.restore()
        self.archive.write_bytes(b"x" * json.loads(self.manifest.read_text())["bytes"])
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            cache.restore()
        self.assertFalse(cache.restored_directory().exists())

    def test_wrong_source_or_architecture_is_rejected(self):
        for field, value in [("sources", "old"), ("architecture", "x86_64")]:
            data = json.loads(self.manifest.read_text())
            data["identity"][field] = value
            self.manifest.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, "does not match"):
                cache.restore()
            self.write_manifest()

    def test_restored_stamp_must_match_archive_metadata(self):
        cache.restore()
        data = json.loads(self.manifest.read_text())
        data["sha256"] = "b" * 64
        self.manifest.write_text(json.dumps(data))
        self.assertFalse(cache.available())

    def test_archive_path_traversal_is_rejected(self):
        with tarfile.open(self.archive, "w:gz") as bundle:
            member = tarfile.TarInfo("../escaped")
            member.size = 1
            bundle.addfile(member, io.BytesIO(b"x"))
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "Unexpected path"):
            cache.restore()
        self.assertFalse((self.root / "escaped").exists())

    def test_escaping_symlink_is_rejected(self):
        with tarfile.open(self.archive, "w:gz") as bundle:
            member = tarfile.TarInfo(cache.LOCK["framework"] + "/escape")
            member.type = tarfile.SYMTYPE
            member.linkname = "../../outside"
            bundle.addfile(member)
        self.write_manifest()
        with self.assertRaises(tarfile.FilterError):
            cache.restore()
        self.assertFalse(cache.restored_directory().exists())

    def test_incomplete_framework_is_rejected(self):
        with tarfile.open(self.archive, "w:gz"):
            pass
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "missing its framework executable"):
            cache.restore()
        self.assertFalse(cache.restored_directory().exists())

    def test_completed_local_build_takes_precedence(self):
        with patch.object(artifact, "available", return_value=True), patch.object(artifact, "require", return_value=Path("local")):
            self.assertEqual(cache.require(), Path("local"))


class EngineFetchTests(ArchiveFixture, unittest.TestCase):
    """DEV-1282: the archive comes from a local copy or the manifest's URL."""

    def setUp(self):
        super().setUp()
        self.published = self.root / "release" / self.archive.name
        self.published.parent.mkdir()
        self.archive.replace(self.published)
        self.write_manifest(self.published)
        self.network = self.stack.enter_context(patch.object(fetch.urllib.request, "urlopen", wraps=fetch.urllib.request.urlopen))

    def write_manifest(self, archive=None, **changes):
        archive = archive or self.archive
        data = {"schema": 1, "identity": artifact.identity(), "framework": cache.LOCK["framework"],
                "chromium": cache.LOCK["chromium"], "archive": self.archive.name,
                "sha256": cache.checksum(archive), "bytes": archive.stat().st_size,
                "url": archive.as_uri()}
        data.update(changes)
        self.manifest.write_text(json.dumps(data))

    def assertRestored(self):
        self.assertEqual(cache.require(), cache.restored_directory() / cache.LOCK["framework"])
        self.assertEqual((cache.require() / "Arx Framework").read_bytes(), b"fixture executable")

    def test_downloads_from_the_manifest_url_without_a_local_archive(self):
        self.assertFalse(self.archive.exists())
        fetch.main()
        self.assertRestored()
        self.assertEqual(cache.local_archive().read_bytes(), self.published.read_bytes())
        self.assertEqual(cache.local_archive().parent, self.root / "downloads" / ("a" * 64))
        # A second machine-local run needs no network: the restored engine and the download match.
        self.network.reset_mock()
        fetch.main()
        self.network.assert_not_called()

    def test_checksum_mismatch_fails_before_unpacking(self):
        self.write_manifest(self.published, sha256="b" * 64)
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            fetch.main()
        self.assertFalse(cache.local_archive().exists())
        self.assertFalse(cache.restored_directory().exists())
        self.assertEqual(list(cache.local_archive().parent.iterdir()), [])

    def test_size_mismatch_fails_before_unpacking(self):
        for size in (self.published.stat().st_size - 1, self.published.stat().st_size + 1):
            self.write_manifest(self.published, bytes=size)
            with self.assertRaisesRegex(ValueError, "size mismatch"):
                fetch.main()
            self.assertFalse(cache.local_archive().exists())
            self.assertFalse(cache.restored_directory().exists())

    def test_missing_asset_says_how_to_get_the_engine(self):
        self.published.unlink()
        with self.assertRaisesRegex(fetch.MissingAsset, "isn't published.*make engine-build and make engine-cache.*put it at"):
            fetch.main()
        self.assertFalse(cache.restored_directory().exists())

    def test_http_404_is_a_missing_asset(self):
        url = "https://github.com/capturecontext/arx-browser-engine/releases/download/engine-x/a.tar.gz"
        error = fetch.urllib.error.HTTPError(url, 404, "Not Found", {}, None)
        self.network.side_effect = error
        self.write_manifest(self.published, url=url)
        with self.assertRaisesRegex(fetch.MissingAsset, "isn't published"):
            fetch.main()
        request = self.network.call_args.args[0]
        self.assertIsNone(request.get_header("Authorization"))

    def test_only_https_and_file_urls_are_downloaded(self):
        self.write_manifest(self.published, url="http://example.com/engine.tar.gz")
        with self.assertRaisesRegex(ValueError, "only https and file"):
            fetch.main()
        self.network.assert_not_called()

    def test_lookup_prefers_the_local_archive_then_the_copy_beside_the_manifest_then_the_url(self):
        data = cache.metadata()
        local = cache.local_archive()
        local.parent.mkdir(parents=True)
        shutil.copyfile(self.published, local)
        shutil.copyfile(self.published, self.archive)
        self.assertEqual(cache.locate(data)[0], local)
        local.write_bytes(b"corrupt")
        archive, problems = cache.locate(data)
        self.assertEqual(archive, self.archive)
        self.assertIn("size mismatch", problems[0])
        self.archive.unlink()
        self.assertEqual(cache.locate(data)[0], None)
        fetch.main()
        self.network.assert_called_once()
        self.assertEqual(local.read_bytes(), self.published.read_bytes())
        self.assertRestored()

    def test_copy_beside_the_manifest_restores_offline(self):
        shutil.copyfile(self.published, self.archive)
        fetch.main()
        self.assertRestored()
        self.network.assert_not_called()

    def test_stale_manifest_fails_before_any_download(self):
        self.write_manifest(self.published, identity={"sources": "old", "architecture": "arm64"})
        with self.assertRaisesRegex(ValueError, "does not match"):
            fetch.main()
        self.network.assert_not_called()

    def test_release_url_names_the_fingerprint_and_architecture(self):
        self.assertEqual(
            cache.release_url(artifact.identity(), self.archive.name),
            "https://github.com/capturecontext/arx-browser-engine/releases/download/engine-aaaaaaaaaaaaaaaa/arx-engine-macos-arm64.tar.gz",
        )


class EngineArchiveTests(ArchiveFixture, unittest.TestCase):
    """make engine-cache writes outside the tracked tree and uploads nothing (DEV-1282)."""

    def package(self):
        (self.root / "source/out/Default").mkdir(parents=True)
        (self.root / "source/out/Default/args.gn").write_text("is_debug = false\n")
        self.archive.unlink()
        output = io.StringIO()
        with (
            patch.object(archive, "ROOT", self.root),
            patch.object(archive, "SOURCE", self.root / "source"),
            patch.object(archive, "WORK", self.root / "work"),
            patch.object(artifact, "require", return_value=self.root / "input" / cache.LOCK["framework"]),
            patch.object(artifact, "available", return_value=True),
            patch.object(archive, "run", side_effect=lambda command, **_: "arm64" if command[0] == "lipo" else "Xcode 27"),
            redirect_stdout(output),
        ):
            archive.main()
        return json.loads(self.manifest.read_text()), output.getvalue()

    def test_cache_writes_the_ignored_archive_and_the_manifest_url(self):
        data, output = self.package()
        local = cache.local_archive()
        self.assertEqual(local.parent, self.root / "downloads" / ("a" * 64))
        self.assertEqual((data["sha256"], data["bytes"]), (cache.checksum(local), local.stat().st_size))
        self.assertEqual(data["url"], cache.release_url(artifact.identity(), self.archive.name))
        self.assertFalse(self.archive.exists())
        self.assertIn("gh release create engine-aaaaaaaaaaaaaaaa " + str(local), output)
        self.assertIn("--repo capturecontext/arx-browser-engine", output)
        self.assertIn("gh release upload engine-aaaaaaaaaaaaaaaa", output)
        self.assertEqual(cache.locate(data)[0], local)
