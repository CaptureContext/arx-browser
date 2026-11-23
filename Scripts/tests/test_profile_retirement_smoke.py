"""Owned acceptance oracle regressions. These do not launch the app or reboot."""

import copy
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from uuid import UUID

from Scripts.core import profile_retirement_smoke as fixture


class ProfileRetirementSmokeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="retirement-smoke-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.app = self.root / "Arx.app"
        self.app.mkdir()
        fixture.prepare(self.root, self.app, 48123)
        self.profile = self.root / "profile"
        self.requests = [str(UUID(int=index)) for index in (21, 22)]
        self.installation = str(UUID(int=23))
        self.original = []
        for name in fixture.ORIGINAL_NAMES:
            (self.profile / name).mkdir(mode=0o700)
            (self.profile / name / "owned-storage").write_text("fixture data")
            self.original.append(fixture.directory_identity(self.profile / name))
        self.identity = {"version": 2, "installationID": self.installation,
                         "legacyProfileID": fixture.LEGACY, "rootPath": str(self.profile),
                         "volume": str(UUID(int=24)), "inode": self.profile.stat().st_ino}
        self.intents = {"version": 1, "installationID": self.installation, "values": [
            {"profileID": profile, "requestID": request, "expectedRevision": 12 + index,
             "attemptRevision": 12 + index, "acknowledged": True}
            for index, (profile, request) in enumerate(zip(fixture.TARGETS, self.requests))]}
        self.workspace = {"organization": {"profiles": [{"id": fixture.SURVIVOR}],
                          "legacyProfileID": fixture.LEGACY, "retiredProfileIDs": list(fixture.TARGETS)}}
        self.write(self.profile / ".arx-installation-v1", self.identity)
        self.write(self.profile / ".arx-profile-retirement-intents-v1", self.intents)
        self.write(self.profile / "arx-workspace.json", self.workspace)
        journal = self.profile / ".arx-profile-erasure-v1"
        journal.write_bytes(b"owned binary journal is interpreted only by the production snapshot")
        journal.chmod(0o600)

    @staticmethod
    def write(path, value):
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    def phase(self, phase, prior=None):
        result = {"version": 1, "status": "passed", "phase": phase, "pid": 12345,
                  "application": str(self.app), "profile": str(self.profile), "requests": self.requests,
                  "progress": "awaitingStartup" if phase == "queue" else "restartRequired",
                  "survivorStorage": True, "retiredAdmissionDenied": True, "settingsDoesNotClaimErased": True}
        completion = {"status": "cleanExit", "phase": phase, "pid": 12345, "application": str(self.app)}
        self.write(self.root / f"result-{phase}.json", result)
        self.write(self.root / f"completion-{phase}.json", completion)
        process = subprocess.CompletedProcess([], 0, f"ARX_RETIREMENT_{phase.upper()}_SMOKE_SUCCESS\n",
                                              "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN\n")
        return fixture.verify_phase(self.root, self.app, phase, 12345, process, prior=prior,
                                    original=prior["original"] if prior else None,
                                    quarantined=prior["quarantined"] if prior else None)

    def quarantine(self):
        for name, request in zip(fixture.ORIGINAL_NAMES, self.requests):
            (self.profile / name).rename(self.profile / (".arx-erasing-" + request))

    def test_survivor_cookie_is_persistent_for_clean_restart_acceptance(self):
        page = fixture.HTML.decode("utf-8")
        self.assertIn("document.cookie = 'identity=' + seed + '; path=/; Max-Age=3600; SameSite=Lax'", page)
        self.assertIn("localStorage.setItem('identity', seed)", page)
        self.assertIn("cookie ? cookie.split('=')[1] : 'empty'", page)
        # The production fixture still requires both independent storage forms.
        source = (Path(__file__).parents[2] / "Packages/features/Sources/AppFeature/ProfileRetirementSmoke.swift").read_text()
        self.assertIn('loaded(Self.survivorTab, title: "survivor|survivor", engine: engine)', source)

    def test_exact_queue_quarantine_and_same_boot_inodes_and_consent(self):
        queue = self.phase("queue")
        self.quarantine()
        quarantine = self.phase("quarantine", queue)
        same_boot = self.phase("sameBoot", quarantine)
        self.assertEqual(same_boot["quarantined"], self.original)
        self.assertEqual(queue["requests"], same_boot["requests"])
        self.assertEqual((self.root / "fixture.json").stat().st_mode & 0o777, 0o600)

    def test_recreated_original_replaced_quarantine_and_changed_consent_fail(self):
        queue = self.phase("queue")
        self.quarantine()
        quarantine = self.phase("quarantine", queue)
        original_path = self.profile / fixture.ORIGINAL_NAMES[0]
        original_path.mkdir(mode=0o700)
        with self.assertRaisesRegex(ValueError, "recreated"):
            self.phase("sameBoot", quarantine)
        original_path.rmdir()
        path = self.profile / (".arx-erasing-" + self.requests[0])
        path.rename(self.profile / "preserved-prior-quarantine")
        path.mkdir(mode=0o700)
        with self.assertRaisesRegex(ValueError, "inode"):
            self.phase("sameBoot", quarantine)
        path.rmdir()
        (self.profile / "preserved-prior-quarantine").rename(path)
        self.intents["values"][0]["expectedRevision"] = 1
        self.write(self.profile / ".arx-profile-retirement-intents-v1", self.intents)
        with self.assertRaisesRegex(ValueError, "Original consent"):
            self.phase("sameBoot", quarantine)

    def test_missing_native_marker_or_unknown_phase_never_passes(self):
        self.phase("queue")
        for process in (subprocess.CompletedProcess([], 0, "", "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN\n"),
                        subprocess.CompletedProcess([], 0, "ARX_RETIREMENT_QUEUE_SMOKE_SUCCESS\n", ""),
                        subprocess.CompletedProcess([], 1, "ARX_RETIREMENT_QUEUE_SMOKE_SUCCESS\n", "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN\n")):
            with self.assertRaises(ValueError):
                fixture.verify_phase(self.root, self.app, "queue", 12345, process)
        with self.assertRaises(ValueError):
            self.phase("erased")

    def test_private_binding_foreign_application_and_unacknowledged_intent_fail(self):
        original = copy.deepcopy(self.identity)
        self.identity["inode"] += 1
        self.write(self.profile / ".arx-installation-v1", self.identity)
        with self.assertRaisesRegex(ValueError, "exact owned root"):
            self.phase("queue")
        self.write(self.profile / ".arx-installation-v1", original)
        self.intents["values"][0]["acknowledged"] = False
        self.write(self.profile / ".arx-profile-retirement-intents-v1", self.intents)
        with self.assertRaisesRegex(ValueError, "consent"):
            self.phase("queue")

    def test_kernel_epoch_uses_exact_authoritative_uuid_and_never_uptime(self):
        valid = "11111111-1111-4111-8111-111111111111"
        with patch("Scripts.core.profile_retirement_smoke.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, valid.upper() + "\n", "")
            self.assertEqual(fixture.kernel_boot_session(), valid)
            self.assertEqual(run.call_args.args[0], ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"])
            for invalid in ("0", "1234 seconds", str(UUID(int=0))):
                run.return_value.stdout = invalid
                with self.assertRaises(ValueError):
                    fixture.kernel_boot_session()

    def test_private_records_reject_symlink_and_overbroad_permissions(self):
        path = self.profile / ".arx-installation-v1"
        original = self.profile / "preserved-identity"
        path.rename(original)
        path.symlink_to(original)
        with self.assertRaises(OSError):
            self.phase("queue")
        path.unlink()
        original.rename(path)
        path.chmod(0o644)
        with self.assertRaises(ValueError):
            self.phase("queue")

    # "Clear Arx data first" before an import (DEV-833), `make migration-clear-smoke`.

    def clear(self, *, profiles=None, requests=None, acknowledged=True, retired=None):
        requests = requests or [str(UUID(int=index)) for index in (31, 32, 33)]
        fresh = str(UUID(int=40))
        profiles = profiles if profiles is not None else [fresh]
        self.write(self.profile / ".arx-profile-retirement-intents-v1", {
            "version": 1, "installationID": self.installation, "values": [
                {"profileID": profile, "requestID": request, "expectedRevision": 12 + index,
                 "attemptRevision": 12 + index, "acknowledged": acknowledged}
                for index, (profile, request) in enumerate(zip(fixture.CLEAR_TARGETS, requests))]})
        self.write(self.profile / "arx-workspace.json", {"organization": {
            "profiles": [{"id": profile} for profile in profiles], "legacyProfileID": fixture.LEGACY,
            "retiredProfileIDs": list(retired if retired is not None else fixture.CLEAR_TARGETS)}})
        phase = fixture.CLEAR_PHASES[0]
        result = {"version": 1, "status": "passed", "phase": phase, "pid": 12345,
                  "application": str(self.app), "profile": str(self.profile), "requests": requests,
                  "progress": "awaitingStartup", "importCompleted": True, "profiles": [fresh]}
        completion = {"status": "cleanExit", "phase": phase, "pid": 12345, "application": str(self.app)}
        self.write(self.root / f"result-{phase}.json", result)
        self.write(self.root / f"completion-{phase}.json", completion)
        process = subprocess.CompletedProcess([], 0, f"ARX_RETIREMENT_{phase.upper()}_SMOKE_SUCCESS\n",
                                              "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN\n")
        return fixture.verify_clear_phase(self.root, self.app, 12345, process)

    def test_clear_for_import_retires_every_fixture_profile_and_keeps_only_the_fresh_one(self):
        proof = self.clear()
        self.assertEqual(proof["installation"], self.installation)
        self.assertEqual(proof["profiles"], [str(UUID(int=40))])

    def test_clear_for_import_rejects_a_restored_profile_or_an_unacknowledged_retirement(self):
        with self.assertRaisesRegex(ValueError, "restored"):
            self.clear(profiles=[str(UUID(int=40)), fixture.SURVIVOR])
        with self.assertRaisesRegex(ValueError, "consent"):
            self.clear(acknowledged=False)
        with self.assertRaisesRegex(ValueError, "restored"):
            self.clear(retired=[fixture.LEGACY, fixture.ORDINARY])

    def test_clear_for_import_rejects_storage_moved_before_restart(self):
        requests = [str(UUID(int=index)) for index in (31, 32, 33)]
        (self.profile / (".arx-erasing-" + requests[0])).mkdir(mode=0o700)
        with self.assertRaisesRegex(ValueError, "before restart"):
            self.clear(requests=requests)
