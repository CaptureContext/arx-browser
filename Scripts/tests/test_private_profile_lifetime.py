"""Execute production profile retirement and download observation with queued callbacks."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine.overlay import PACKAGE


def section(source: str, start: str, end: str) -> str:
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


class PrivateProfileLifetimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        root = Path(cls.directory.name)
        engine = (PACKAGE / "Native/engine_bridge.mm").read_text()
        downloads = (PACKAGE / "Native/downloads_bridge.mm").read_text()
        harness = (Path(__file__).parent / "fixtures/private_profile_lifetime.cc").read_text()
        replacements = {
            "ENGINE_STATE": section(engine, "struct RetiredPrivateProfile", "EngineState& State()"),
            "DOWNLOADS_IMPLEMENTATION": (
                section(downloads, "struct Snapshot", "\n}\n\nvoid ObserveDownloads")
                + "\n" + section(downloads, "void ObserveDownloads", "\nvoid StopAllDownloads")
                + "\n" + section(downloads, "void StopAllDownloads", "\n}\n") + "\n}"
            ),
            "PROFILE_IMPLEMENTATION": section(engine, "void PrepareProfile", "\nbool StartDownloadObservation"),
            "ACTIVITY_IMPLEMENTATION": section(engine, "void DownloadActivityChanged", "\nbool PageConsentRetainsProfile"),
            "SHUTDOWN_IMPLEMENTATION": section(engine, "  void PostMainMessageLoopRun()", "\n};"),
        }
        # StopAllDownloads is the last function: include its body but not arx's
        # closing namespace. Anonymous namespace state is visible to the harness.
        for marker, implementation in replacements.items():
            harness = harness.replace("// " + marker, implementation)
        source = root / "lifetime.cc"
        source.write_text('#include "adoption_scope.h"\nusing arx::AdoptionScope;\n' + harness)
        cls.executable = root / "lifetime"
        result = subprocess.run(
            ["xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
             "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
             "-I", str(PACKAGE / "Native"),
             str(source), "-o", str(cls.executable)],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode:
            raise AssertionError(result.stderr)

    def run_scenario(self, name, environment=None):
        result = subprocess.run([str(self.executable), name], capture_output=True, text=True, timeout=5,
                                env=environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_pending_media_consent_holds_exact_private_profile_until_physical_drain(self):
        self.run_scenario("consent")

    def test_immediate_reopen_uses_fresh_context_and_old_cleanup_is_scoped(self):
        self.run_scenario("reopen")

    def test_old_and_new_transfers_share_key_but_cancel_routes_by_guid(self):
        self.run_scenario("transfers")

    def test_terminal_delivery_precedes_retirement_in_both_queue_orders(self):
        self.run_scenario("delivery")

    def test_multiple_retirements_and_reused_pointer_ignore_stale_task(self):
        self.run_scenario("generations")

    def test_release_with_live_page_is_rejected(self):
        self.run_scenario("live-page")

    def test_private_keys_never_become_ordinary_and_pending_ordinary_keys_stay_reserved(self):
        self.run_scenario("storage-kind")

    def test_cancel_all_tolerates_observer_removal_and_replacement(self):
        self.run_scenario("cancel-all")

    def test_cancel_guid_tolerates_removed_observer_and_borrowed_callback_state(self):
        self.run_scenario("cancel-guid")

    def test_pause_resume_control_and_removal_follow_the_item(self):
        self.run_scenario("pause-resume")

    def test_external_callbacks_can_stop_observation_during_delivery_and_initialization(self):
        self.run_scenario("reentrant-delivery")

    def test_shutdown_invalidates_queued_delivery_and_retirement(self):
        self.run_scenario("shutdown")

    def test_private_prompt_inherits_before_publication_and_is_not_reset_by_reobservation(self):
        self.run_scenario("prompt-inheritance")

    def test_private_prompt_preserves_parent_user_enabled_preference(self):
        self.run_scenario("prompt-enabled")

    def test_private_prompt_preserves_managed_precedence_and_updates(self):
        self.run_scenario("prompt-managed")

    def test_ordinary_prompt_is_not_changed(self):
        self.run_scenario("prompt-ordinary")

    def test_started_downloads_reply_once_after_delivery_and_cancel_late_items(self):
        self.run_scenario("start-downloads")

    def test_a_quit_loses_private_and_unresumable_transfers(self):
        self.run_scenario("lost-on-quit")

    def test_a_quit_interrupts_continuable_transfers_before_the_shutdown_cancel(self):
        self.run_scenario("quit-interrupts")

    def test_a_quit_says_what_it_kept_with_download_diagnostics(self):
        quiet = self.run_scenario("quit-interrupts")
        self.assertNotIn("ARX_DOWNLOAD_QUIT", quiet.stderr)
        result = self.run_scenario("quit-interrupts", dict(os.environ, ARX_DOWNLOAD_DIAGNOSTICS="1"))
        lines = result.stderr.splitlines()
        self.assertIn("ARX_DOWNLOAD_QUIT observers=2", lines)
        self.assertEqual(sum(line.startswith("ARX_DOWNLOAD_QUIT kept guid=") for line in lines), 2)
        self.assertIn("ARX_DOWNLOAD_QUIT kept=2 cancelled=6", lines)
        self.assertIn("ARX_DOWNLOAD_QUIT files=released", lines)
        found = [line for line in lines if line.startswith("ARX_DOWNLOAD_QUIT found guid=dated-paused ")]
        self.assertEqual(len(found), 1)
        self.assertIn(" paused=1 writing=1 all_data=0 dangerous=0 etag=0 last_modified=1 continues=1 ", found[0])

    def test_a_late_download_sequence_reply_after_the_quit_stopped_waiting_is_safe(self):
        environment = dict(os.environ, ARX_DOWNLOAD_DIAGNOSTICS="1",
                           ASAN_OPTIONS="detect_stack_use_after_return=1")
        result = self.run_scenario("quit-times-out", environment)
        self.assertIn("ARX_DOWNLOAD_QUIT files=timed-out", result.stderr.splitlines())

    def test_a_profile_torn_down_while_running_cancels_every_transfer(self):
        self.run_scenario("teardown-cancels")

    def test_private_profile_follows_only_a_prepared_ordinary_opener(self):
        self.run_scenario("opener")
