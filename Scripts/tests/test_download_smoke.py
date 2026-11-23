"""The real-runtime smoke owns its destination and checks both history stores."""

import json
import sqlite3
import tempfile
import subprocess
import unittest
from pathlib import Path

from Scripts.core import download_smoke


class DownloadSmokeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.profile = self.root / "profile"

    def prepare_history(self, marker=None):
        metadata = {"version": 1, "records": [{"isPrivate": False, "url": "https://capturecontext.dev/ordinary"}]}
        (self.profile / "arx-downloads.json").write_text(json.dumps(metadata))
        with sqlite3.connect(self.profile / "Default/History") as database:
            database.execute("CREATE TABLE downloads_url_chains(url TEXT)")
            database.execute("INSERT INTO downloads_url_chains VALUES (?)", (marker or "http://127.0.0.1/downloads/complete?smoke=ordinary",))

    def test_preparation_preserves_existing_preferences_and_has_known_payloads(self):
        for parent in ("Default", "Arx-Bootstrap"):
            preferences = self.profile / parent / "Preferences"
            preferences.parent.mkdir(parents=True)
            preferences.write_text(json.dumps({"custom": parent, "download": {"extensions_to_open": ""}}))
        environment = download_smoke.prepare(self.root, self.profile)
        for parent in ("Default", "Arx-Bootstrap"):
            with self.subTest(parent=parent):
                result = json.loads((self.profile / parent / "Preferences").read_text())
                self.assertEqual(result["custom"], parent)
                self.assertEqual(result["download"]["extensions_to_open"], "")
                self.assertFalse(result["download"]["prompt_for_download"])
                self.assertEqual(result["download"]["default_directory"], environment["ARX_DOWNLOAD_SMOKE_DIRECTORY"])
        self.assertTrue(Path(environment["ARX_DOWNLOAD_SMOKE_DIRECTORY"]).is_dir())
        self.assertEqual(len(environment["ARX_DOWNLOAD_SMOKE_SHA256"]), 64)
        self.assertEqual(int(environment["ARX_DOWNLOAD_SMOKE_SLOW_BYTES"]), 8 * 1024 * 1024)

    def test_corrupt_preferences_are_not_silently_overwritten(self):
        preferences = self.profile / "Default/Preferences"
        preferences.parent.mkdir(parents=True)
        preferences.write_text("invalid")
        with self.assertRaises(json.JSONDecodeError):
            download_smoke.prepare(self.root, self.profile)
        self.assertEqual(preferences.read_text(), "invalid")

    def test_corrupt_private_parent_preferences_leave_ordinary_parent_untouched(self):
        ordinary = self.profile / "Default/Preferences"
        ordinary.parent.mkdir(parents=True)
        original = json.dumps({"download": {"default_directory": "preserve"}})
        ordinary.write_text(original)
        private = self.profile / "Arx-Bootstrap/Preferences"
        private.parent.mkdir(parents=True)
        private.write_text("invalid")
        with self.assertRaises(json.JSONDecodeError):
            download_smoke.prepare(self.root, self.profile)
        self.assertEqual(ordinary.read_text(), original)
        self.assertEqual(private.read_text(), "invalid")

    def test_ordinary_history_passes_post_exit_check(self):
        environment = download_smoke.prepare(self.root, self.profile)
        self.prepare_history()
        download_smoke.verify(self.profile, environment)

    def test_private_url_in_chromium_history_fails(self):
        environment = download_smoke.prepare(self.root, self.profile)
        self.prepare_history("http://127.0.0.1/downloads/slow?" + environment["ARX_DOWNLOAD_SMOKE_PRIVATE_MARKER"])
        with self.assertRaisesRegex(ValueError, "native profile history"):
            download_smoke.verify(self.profile, environment)

    def test_private_queue_record_fails(self):
        environment = download_smoke.prepare(self.root, self.profile)
        self.prepare_history()
        (self.profile / "arx-downloads.json").write_text(json.dumps({"records": [{"isPrivate": True}]}))
        with self.assertRaisesRegex(ValueError, "ordinary queue metadata"):
            download_smoke.verify(self.profile, environment)

    def test_unrelated_history_does_not_claim_download_privacy_verification(self):
        environment = download_smoke.prepare(self.root, self.profile)
        self.prepare_history("https://capturecontext.dev/page")
        with self.assertRaisesRegex(ValueError, "privacy verification is incomplete"):
            download_smoke.verify(self.profile, environment)

    def test_missing_native_history_does_not_claim_verification(self):
        environment = download_smoke.prepare(self.root, self.profile)
        (self.profile / "arx-downloads.json").write_text(json.dumps({"records": []}))
        with self.assertRaisesRegex(ValueError, "no native profile history"):
            download_smoke.verify(self.profile, environment)

    def test_quit_alert_is_recognized_only_from_the_pause_launch_marker(self):
        # DEV-966: a windowed quit cancels the paused download, so the resume launch is skipped.
        answered = subprocess.CompletedProcess([], 0, download_smoke.PAUSED_MARKER + "\n",
                                               download_smoke.QUIT_ALERT_MARKER + "\n")
        self.assertTrue(download_smoke.answered_quit_alert(answered))
        quiet = subprocess.CompletedProcess([], 0, download_smoke.PAUSED_MARKER + "\n", "")
        self.assertFalse(download_smoke.answered_quit_alert(quiet))
        quoted = subprocess.CompletedProcess([], 0, "", "said " + download_smoke.QUIT_ALERT_MARKER + "\n")
        self.assertFalse(download_smoke.answered_quit_alert(quoted))

    def test_resume_needs_both_launches_and_a_range_request(self):
        def result(code, stdout):
            return subprocess.CompletedProcess([], code, stdout, "")
        paused = result(0, download_smoke.PAUSED_MARKER + "\n")
        resumed = result(0, download_smoke.RESUMED_MARKER + "\n")
        download_smoke.verify_resume(paused, resumed, [1048576])
        with self.assertRaisesRegex(ValueError, "started over"):
            download_smoke.verify_resume(paused, resumed, [])
        with self.assertRaisesRegex(ValueError, "did not pause"):
            download_smoke.verify_resume(result(1, ""), resumed, [1048576])
        with self.assertRaisesRegex(ValueError, "resumed download"):
            download_smoke.verify_resume(paused, result(0, ""), [1048576])
