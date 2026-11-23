"""`make engine-upstream` and `make engine-bump` (DEV-955): finding a newer helium-macos release,
classifying it, and moving the pins. GitHub is a fake; nothing reaches the network."""

import base64
import contextlib
import datetime
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from Scripts.engine import upstream

LOCK = {
    "schema": 1,
    "helium_macos": {"repository": "https://github.com/imputnet/helium-macos.git",
                     "version": "0.21.3.1", "revision": "da5fcc2c78e760e4383fe4d15f230158f3dbe9a4"},
    "helium": {"version": "0.21.3", "revision": "a2d96a753a3e9f10e10170615f8eaed6b159e85b"},
    "chromium": "157.0.8103.78",
    "architectures": ["arm64", "x86_64"],
    "bundle_id": "dev.capturecontext.arx",
    "framework": "Arx Framework.framework",
    "abi": 44,
}
MACOS = "1" * 40
HELIUM = "2" * 40


def release(tag, draft=False, prerelease=False, published="2026-11-20T10:00:00Z"):
    return {"tag_name": tag, "draft": draft, "prerelease": prerelease, "published_at": published,
            "html_url": f"https://github.com/imputnet/helium-macos/releases/tag/{tag}",
            "body": "## Helium macOS\r\nChanges since last build:\r\n"}


def api(releases, chromium="157.0.8103.92", annotated=False):
    """A fake GitHub API over one helium-macos tag."""
    def get(path):
        if path.startswith("repos/imputnet/helium-macos/releases?"):
            return releases
        if path.startswith("repos/imputnet/helium-macos/git/ref/tags/"):
            return {"object": {"type": "tag", "sha": "3" * 40} if annotated else {"type": "commit", "sha": MACOS}}
        if path == f"repos/imputnet/helium-macos/git/tags/{'3' * 40}":
            return {"object": {"type": "commit", "sha": MACOS}}
        if path == f"repos/imputnet/helium-macos/contents/helium-chromium?ref={MACOS}":
            return {"type": "submodule", "sha": HELIUM, "submodule_git_url": "https://github.com/imputnet/helium.git"}
        if path == f"repos/imputnet/helium/contents/chromium_version.txt?ref={HELIUM}":
            return {"encoding": "base64", "content": base64.b64encode(f"{chromium}\n".encode()).decode()}
        raise AssertionError(f"Unexpected GitHub request: {path}")
    return get


class ReleaseTests(unittest.TestCase):
    def test_versions_compare_as_numbers(self):
        self.assertGreater(upstream.version_key("0.21.10.1"), upstream.version_key("0.21.9.1"))
        self.assertIsNone(upstream.version_key("nightly"))
        self.assertIsNone(upstream.version_key("v0.21.3.1"))

    def test_the_newest_published_release_past_the_lock(self):
        releases = [release("0.21.2.1"), release("0.22.1.1", draft=True), release("0.22.1.2", prerelease=True),
                    release("nightly"), release("0.21.10.1"), release("0.21.4.1")]
        self.assertEqual(upstream.newest(releases, LOCK)["tag_name"], "0.21.10.1")

    def test_nothing_newer_than_the_lock(self):
        self.assertIsNone(upstream.newest([release("0.21.3.1"), release("0.21.2.1")], LOCK))
        self.assertIsNone(upstream.newest([], LOCK))

    def test_kinds(self):
        self.assertEqual(upstream.kind("157.0.8103.78", "158.0.8150.20"), "minor")
        self.assertEqual(upstream.kind("157.0.8103.78", "157.0.8103.92"), "security")
        self.assertEqual(upstream.kind("157.0.8103.78", "157.0.8103.78"), "helium")
        with self.assertRaises(ValueError):
            upstream.kind("157.0.8103.78", "unknown")

    def test_deadlines_follow_the_cadence(self):
        published = "2026-11-20T10:00:00Z"
        start = datetime.datetime(2026, 11, 20, 10, tzinfo=datetime.timezone.utc)
        self.assertEqual(upstream.due(published, "security"), start + datetime.timedelta(hours=48))
        self.assertEqual(upstream.due(published, "minor"), start + datetime.timedelta(days=7))


class ResolveTests(unittest.TestCase):
    def test_reads_the_tag_commit_submodule_and_chromium_version(self):
        identity = upstream.resolve(release("0.21.4.1"), api([]))
        self.assertEqual(identity["helium_macos"], {"version": "0.21.4.1", "revision": MACOS})
        self.assertEqual(identity["helium"], {"version": "0.21.4", "revision": HELIUM, "repository": "imputnet/helium"})
        self.assertEqual(identity["chromium"], "157.0.8103.92")

    def test_follows_an_annotated_tag(self):
        self.assertEqual(upstream.resolve(release("0.21.4.1"), api([], annotated=True))["helium_macos"]["revision"], MACOS)

    def test_rejects_a_tag_without_a_platform_revision(self):
        with self.assertRaisesRegex(ValueError, "four-part"):
            upstream.resolve(release("0.21.4"), api([]))

    def test_rejects_a_chromium_version_that_isnt_one(self):
        with self.assertRaisesRegex(ValueError, "isn't a version"):
            upstream.resolve(release("0.21.4.1"), api([], chromium="main"))


class CheckTests(unittest.TestCase):
    def test_reports_a_security_respin_due_in_48_hours(self):
        result = upstream.check(LOCK, api([release("0.21.4.1"), release("0.21.3.1")]))
        update = result["update"]
        self.assertEqual(update["kind"], "security")
        self.assertEqual(update["due"], "2026-11-22T10:00:00Z")
        self.assertEqual(update["chromium"], "157.0.8103.92")
        self.assertEqual(update["notes"], "## Helium macOS\nChanges since last build:")
        self.assertEqual(result["current"], {"helium_macos": "0.21.3.1", "chromium": "157.0.8103.78"})

    def test_reports_no_update(self):
        self.assertIsNone(upstream.check(LOCK, api([release("0.21.3.1")]))["update"])

    def test_main_hands_the_result_to_later_workflow_steps(self):
        with tempfile.TemporaryDirectory() as directory:
            output, report = Path(directory) / "output", Path(directory) / "update.json"
            result = upstream.check(LOCK, api([release("0.22.1.1")], chromium="158.0.8150.20"))
            with mock.patch.object(upstream, "check", return_value=result), \
                    mock.patch.object(upstream, "_lock", return_value=LOCK), \
                    mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}), \
                    contextlib.redirect_stdout(io.StringIO()) as printed:
                upstream.main(["--json", str(report)])
            self.assertIn("update=true\nversion=0.22.1.1\nchromium=158.0.8150.20\nkind=minor\n", output.read_text())
            self.assertEqual(json.loads(report.read_text())["update"]["helium_macos"]["version"], "0.22.1.1")
            self.assertIn("Helium minor release on a new Chromium major", printed.getvalue())


class PullRequestTests(unittest.TestCase):
    def result(self):
        return upstream.check(LOCK, api([release("0.21.4.1")]))

    def test_carries_the_kind_deadline_report_and_notes(self):
        title, body = upstream.pull_request(self.result(), "### Overlay anchors\n\n**2 missing anchors**\n", clean=False)
        self.assertEqual(title, "Pin the engine to Chromium 157.0.8103.92 on Helium 0.21.4 (helium-macos 0.21.4.1)")
        self.assertIn("a **chromium security respin**, Chromium 157.0.8103.78 → 157.0.8103.92", body)
        self.assertIn("by **2026-11-22T10:00:00Z**", body)
        self.assertIn("- [ ] Re-anchor the overlays the report lists", body)
        self.assertIn("Label this pull request `engine-build`", body)
        self.assertIn("**2 missing anchors**\n\n<details>", body)
        self.assertIn("## Helium macOS\nChanges since last build:", body)

    def test_an_unfinished_anchor_check_says_so(self):
        _, body = upstream.pull_request(self.result(), None)
        self.assertIn("The anchor check didn't finish", body)

    def test_writes_the_title_and_body_for_the_workflow(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "update.json").write_text(json.dumps(self.result()))
            (root / "anchors.md").write_text("### Overlay anchors\n\nEvery overlay applies.\n")
            upstream.pull_request_main([str(root / "update.json"), str(root / "anchors.md"), "clean", str(root / "out")])
            self.assertTrue((root / "out/title.txt").read_text().startswith("Pin the engine to Chromium 157.0.8103.92"))
            body = (root / "out/body.md").read_text()
            self.assertIn("Every overlay anchor was found", body)
            self.assertIn("Every overlay applies.", body)


class AutomationTests(unittest.TestCase):
    def test_runs_without_macos_libraries(self):
        """The nightly workflow runs on Ubuntu: nothing the bump commands import, the overlays
        included, may load a macOS library through ctypes."""
        root = Path(__file__).resolve().parents[2]
        modules = ["Scripts.engine.automation", "Scripts.credits"] + sorted(
            f"Scripts.engine.{path.stem}" for path in (root / "Scripts/engine").glob("*_overlay.py"))
        script = "import importlib, sys\nsys.modules['ctypes'] = None\n" + "".join(
            f"importlib.import_module({name!r})\n" for name in modules)
        result = subprocess.run([sys.executable, "-c", script], cwd=root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_dispatches_and_reports_usage(self):
        from Scripts.engine import automation
        with contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(automation.main([]), 2)
        self.assertIn("engine-upstream|engine-bump|engine-anchor-check|pull-request", error.getvalue())
        with mock.patch.dict(automation.COMMANDS, {"engine-upstream": mock.Mock(side_effect=ValueError("offline"))}), \
                contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(automation.main(["engine-upstream"]), 1)
        self.assertIn("offline", error.getvalue())


class BumpTests(unittest.TestCase):
    def tree(self, root):
        (root / "Packages/engine/Sources/ChromiumBootstrap/Upstream").mkdir(parents=True)
        (root / "Packages/engine/Sources/ChromiumBootstrap/Config/partition_alloc").mkdir(parents=True)
        (root / "Packages/engine/engine.lock.json").write_text(json.dumps(LOCK, indent=2) + "\n")
        (root / "README.md").write_text("The pins are helium-macos `da5fcc2`, Helium `a2d96a7` and Chromium 157.0.8103.78.\n")
        (root / "THIRD_PARTY_NOTICES.md").write_text("helium-macos `da5fcc2`, Helium `a2d96a7`, Chromium 157.0.8103.78.\n"
                                                     "Not a pin: 1157.0.8103.789.\n")
        (root / "Packages/engine/README.md").write_text("`Versions/157.0.8103.78`\n")
        (root / "Packages/engine/Sources/ChromiumBootstrap/Upstream/source-manifest.json").write_text(json.dumps({
            "chromium": "157.0.8103.78", "helium_macos_revision": LOCK["helium_macos"]["revision"],
            "helium_revision": LOCK["helium"]["revision"]}, indent=2) + "\n")
        (root / "Packages/engine/Sources/ChromiumBootstrap/Config/partition_alloc/buildflags.h").write_text(
            "// engine.lock.json Chromium 157.0.8103.78 enables USE_PARTITION_ALLOC_AS_MALLOC.\n")

    def identity(self, version="0.21.4.1"):
        return {"helium_macos": {"version": version, "revision": MACOS},
                "helium": {"version": version.rsplit(".", 1)[0], "revision": HELIUM}, "chromium": "157.0.8103.92"}

    def test_moves_the_lock_and_every_file_naming_the_pins(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.tree(root)
            changed = upstream.bump(self.identity(), root=root, regenerate_credits=False)
            lock = json.loads((root / "Packages/engine/engine.lock.json").read_text())
            self.assertEqual(lock, {**LOCK, "helium_macos": {**LOCK["helium_macos"], "version": "0.21.4.1", "revision": MACOS},
                                    "helium": {"version": "0.21.4", "revision": HELIUM}, "chromium": "157.0.8103.92"})
            self.assertEqual(changed, ["Packages/engine/engine.lock.json", *upstream.PINNED_FILES])
            self.assertEqual((root / "README.md").read_text(),
                             "The pins are helium-macos `1111111`, Helium `2222222` and Chromium 157.0.8103.92.\n")
            self.assertIn("Not a pin: 1157.0.8103.789.", (root / "THIRD_PARTY_NOTICES.md").read_text())
            manifest = json.loads((root / "Packages/engine/Sources/ChromiumBootstrap/Upstream/source-manifest.json").read_text())
            self.assertEqual(manifest, {"chromium": "157.0.8103.92", "helium_macos_revision": MACOS, "helium_revision": HELIUM})

    def test_refuses_a_release_that_isnt_newer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.tree(root)
            with self.assertRaisesRegex(ValueError, "isn't newer"):
                upstream.bump(self.identity("0.21.3.1"), root=root, regenerate_credits=False)


if __name__ == "__main__":
    unittest.main()
