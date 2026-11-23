"""Acceptance oracle regressions; these never launch an application."""

import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from uuid import UUID

from Scripts.core import routing_smoke


class RoutingSmokeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="routing-smoke-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.app = self.root / "Arx.app"
        self.app.mkdir()
        self.configuration = routing_smoke.prepare(self.root, self.app, "mainBrowser", 48123)
        self.urls = self.configuration["urls"]
        self.result = {
            "status": "passed", "pid": 12345, "application": str(self.app),
            "profile": str(self.root / "profile"), "mode": "mainBrowser",
            "received": self.urls, "committed": self.urls,
            "tabIDs": [str(UUID(int=index)).upper() for index in range(1, 5)],
        }
        self.launch = {"pid": 12345, "application": str(self.app)}
        self.completion = {key: self.result[key] for key in ("pid", "application", "profile", "mode")}
        self.completion["status"] = "cleanExit"
        self.workspace = {"organization": {"tabs": [
            {"id": identifier, "restoration": {"url": url}}
            for identifier, url in zip(self.result["tabIDs"], self.urls)
        ]}}
        self.process = subprocess.CompletedProcess([], 0, "ARX_ROUTING_LAUNCHER_EXIT_SUCCESS\n", "")

    def write(self):
        for path, data in (("launch.json", self.launch), ("result.json", self.result),
                           ("completion.json", self.completion),
                           ("profile/arx-workspace.json", self.workspace)):
            (self.root / path).write_text(json.dumps(data))

    def verify(self):
        return routing_smoke.verify(self.root, self.app, self.result["mode"], self.urls, self.process)

    def test_product_ownership_uses_directory_identity_not_a_text_prefix(self):
        build = self.root / "Build"
        build.mkdir()
        alias = self.root / "build-alias"
        alias.symlink_to(build, target_is_directory=True)
        app = build / "Products/Debug/Arx.app"
        app.mkdir(parents=True)
        self.assertTrue(routing_smoke.is_owned_product(app, alias))
        outside = self.root / "Build-other/Arx.app"
        outside.mkdir(parents=True)
        self.assertFalse(routing_smoke.is_owned_product(outside, build))


    def test_application_receipts_accept_file_alias_but_reject_distinct_sibling(self):
        alias = self.root / "Alias.app"
        alias.symlink_to(self.app, target_is_directory=True)
        self.result["application"] = str(alias)
        self.write()
        self.verify()
        alternate_case = self.root / "arx.app"
        if alternate_case.exists():
            self.result["application"] = str(alternate_case)
            self.write()
            self.verify()
        sibling = self.root / "Other.app"
        sibling.mkdir()
        self.result["application"] = str(sibling)
        self.write()
        with self.assertRaises(ValueError):
            self.verify()


    def test_exact_order_preserves_duplicate_url_with_independent_sessions(self):
        self.write()
        self.assertEqual(self.verify(), self.result)
        self.assertEqual(self.urls[0], self.urls[2])
        self.assertEqual(len(set(self.result["tabIDs"])), 4)
        self.assertIn("%E6%9D%B1%E4%BA%AC", self.urls[0])
        for name in (".arx-routing-smoke", "fixture.json"):
            self.assertEqual((self.root / name).stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / "profile").stat().st_mode & 0o777, 0o700)

    def test_missing_reordered_deduplicated_or_foreign_result_cannot_pass(self):
        original = copy.deepcopy(self.result)
        changes = (
            lambda value: value.update(status="timedOut"),
            lambda value: value.update(pid=12346),
            lambda value: value.update(application="/unrelated/Arx.app"),
            lambda value: value.update(profile="/unrelated/profile"),
            lambda value: value.update(received=self.urls[:3]),
            lambda value: value.update(received=list(reversed(self.urls))),
            lambda value: value.update(committed=list(dict.fromkeys(self.urls))),
            lambda value: value.update(tabIDs=[value["tabIDs"][0]] * 4),
        )
        for change in changes:
            with self.subTest(change=change):
                self.result = copy.deepcopy(original)
                change(self.result)
                self.write()
                with self.assertRaises(ValueError):
                    self.verify()

    def test_normal_metadata_must_preserve_exact_url_and_session_order(self):
        self.workspace["organization"]["tabs"].reverse()
        self.write()
        with self.assertRaisesRegex(ValueError, "persisted in order"):
            self.verify()

    def test_little_pages_leave_no_workspace_tabs_and_only_their_own_history(self):
        self.result["mode"] = "littleArx"
        self.completion["mode"] = "littleArx"
        self.workspace["organization"]["tabs"] = []
        self.write()
        self.verify()
        history = self.root / "profile/History"
        history.mkdir()
        # DEV-728: Little Arx pages reach their profile's history.
        (history / "profile.json").write_text(json.dumps({"snapshot": {"entries": [{"url": self.urls[0]}]}}))
        self.verify()
        (history / "profile.json").write_text(json.dumps({"snapshot": {"entries": [{"url": "https://other.example/"}]}}))
        with self.assertRaisesRegex(ValueError, "ordinary browsing history"):
            self.verify()
        (history / "profile.json").unlink()
        self.workspace["organization"]["tabs"] = [{"id": self.result["tabIDs"][0]}]
        self.write()
        with self.assertRaisesRegex(ValueError, "durable workspace"):
            self.verify()

    def test_launcher_completion_is_required_even_if_app_claims_success(self):
        self.write()
        for process in (subprocess.CompletedProcess([], 1, "", ""),
                        subprocess.CompletedProcess([], 0, "", "")):
            self.process = process
            with self.assertRaisesRegex(ValueError, "launcher failed"):
                self.verify()

    def test_page_success_without_matching_clean_runtime_return_cannot_pass(self):
        self.write()
        (self.root / "completion.json").unlink()
        with self.assertRaises(FileNotFoundError):
            self.verify()
        original = copy.deepcopy(self.completion)
        for key, changed in (("status", "crashed"), ("pid", 12346), ("mode", "littleArx"),
                             ("profile", "/unrelated/profile"), ("application", "/unrelated/Arx.app")):
            with self.subTest(key=key):
                self.completion = dict(original, **{key: changed})
                self.write()
                with self.assertRaisesRegex(ValueError, "matching clean exit"):
                    self.verify()

    def test_refuses_symlinked_or_oversized_result(self):
        self.write()
        result = self.root / "result.json"
        result.unlink()
        result.symlink_to(self.root / "launch.json")
        with self.assertRaisesRegex(ValueError, "Invalid routing result"):
            self.verify()
        result.unlink()
        result.write_bytes(b" " * 65537)
        with self.assertRaisesRegex(ValueError, "Invalid routing result"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
