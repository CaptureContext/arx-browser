"""Keep renderer-crash injection limited to the disposable smoke process."""

import signal
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from Scripts import app_smoke, test_runtime
from Scripts.app_smoke import terminate_smoke_renderers
from Scripts.core import smoke
from Scripts.engine import smoke as engine_smoke


class AppSmokeTests(unittest.TestCase):
    def test_automation_fixture_uses_private_fresh_profile_and_static_pages(self):
        with tempfile.TemporaryDirectory(prefix="app-smoke-") as directory:
            root = Path(directory)
            app_smoke.prepare_automation_fixture(root)
            app_smoke.download_smoke.prepare(root, root / "profile")
            self.assertEqual(app_smoke.media_smoke.prepare(root), {"ARX_MEDIA_SMOKE_ROOT": str(root)})
            self.assertEqual((root / ".arx-media-smoke").read_text(), app_smoke.media_smoke.SENTINEL)
            self.assertTrue((root / "profile/Default/Preferences").is_file())
            marker = root / ".arx-mcp-smoke"
            self.assertEqual(marker.read_text(), "Arx MCP disposable fixture v1\n")
            self.assertEqual(stat.S_IMODE(marker.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE((root / "profile").stat().st_mode), 0o700)
            for suffix in ("start", "next", "private", "excluded", "revoked"):
                page = (root / f"mcp-{suffix}.html").read_text()
                self.assertIn(f"<title>Arx MCP {suffix}</title>", page)
                self.assertNotIn("<script", page)

    def test_automation_fixture_does_not_adopt_an_existing_profile(self):
        with tempfile.TemporaryDirectory(prefix="app-smoke-") as directory:
            root = Path(directory)
            profile = root / "profile"
            profile.mkdir()
            (profile / "keep").write_text("existing profile")
            with self.assertRaises(FileExistsError):
                app_smoke.prepare_automation_fixture(root)
            self.assertFalse((root / ".arx-mcp-smoke").exists())
            self.assertEqual((profile / "keep").read_text(), "existing profile")

    def test_success_requires_mcp_and_allocator_evidence_even_with_zero_exit(self):
        stdout = "\n".join((
            "ARX_APP_SMOKE_SUCCESS", "ARX_APP_REOPEN_SMOKE_SUCCESS",
            "ARX_PROFILE_ISOLATION_SMOKE_SUCCESS", "ARX_CACHE_RELOAD_SMOKE_SUCCESS",
            "ARX_HISTORY_SMOKE_SUCCESS", "ARX_PROFILE_HISTORY_SMOKE_SUCCESS",
            "ARX_TAB_MOVE_SMOKE_SUCCESS", "ARX_SHARED_FAVORITE_SMOKE_SUCCESS", "ARX_INDEPENDENT_WINDOW_SMOKE_SUCCESS", "ARX_MCP_NATIVE_SMOKE_SUCCESS", "ARX_DOWNLOAD_SMOKE_SUCCESS",
            "ARX_MCP_ORGANIZATION_NATIVE_SMOKE_SUCCESS", "ARX_MCP_HOST_NATIVE_SMOKE_SUCCESS",
            "ARX_MCP_CAPTURE_NATIVE_SMOKE_SUCCESS",
            "ARX_APP_DOCUMENT_CAPTURE_SMOKE_SUCCESS", "ARX_MCP_DOCUMENT_CAPTURE_NATIVE_SMOKE_SUCCESS",
            "ARX_MCP_INSPECTION_NATIVE_SMOKE_SUCCESS", "ARX_MCP_CLICK_NATIVE_SMOKE_SUCCESS", "ARX_MCP_FORM_NATIVE_SMOKE_SUCCESS",
            "ARX_MCP_KEYPRESS_NATIVE_SMOKE_SUCCESS",
            "ARX_MCP_SCROLL_NATIVE_SMOKE_SUCCESS",
            "ARX_MCP_WAIT_NATIVE_SMOKE_SUCCESS", "ARX_MCP_DOWNLOAD_NATIVE_SMOKE_SUCCESS",
            "ARX_MCP_SETTINGS_NATIVE_SMOKE_SUCCESS", "ARX_MCP_DEVELOPER_NATIVE_SMOKE_SUCCESS", "ARX_MCP_PASSWORD_SIGN_IN_PHASE_NO_SAVED_PASSWORD",
            "ARX_ARCHIVE_SELECTED_SMOKE_SUCCESS", "ARX_ARCHIVE_CROSS_PROFILE_SMOKE_SUCCESS",
            "ARX_PRIVATE_DOWNLOAD_REOPEN_SMOKE_SUCCESS",
            "ARX_SPLIT_SMOKE_SUCCESS", "ARX_PAGE_DROP_SPLIT_SMOKE_SUCCESS", "ARX_PAGE_DROP_TARGETS_SMOKE_SUCCESS", "ARX_TAB_TEAR_OFF_SMOKE_SUCCESS",
            "ARX_PEEK_SMOKE_SUCCESS",
            "ARX_PRIVATE_PROFILE_SMOKE_SUCCESS", "ARX_SHORTCUTS_SMOKE_SUCCESS",
            "ARX_LITTLE_PROMOTION_SMOKE_SUCCESS", "ARX_RENDERER_RECOVERY_SMOKE_SUCCESS",
            "ARX_ROUTING_PROFILE_PICKER_SMOKE_SUCCESS",
            "ARX_PAGE_MENUS_SMOKE_LINK_ITEMS", "ARX_PAGE_MENUS_SMOKE_LINK_NEW_WINDOW",
            "ARX_PAGE_MENUS_SMOKE_SAVE_LOADING_PDF",
            "ARX_LOCAL_FILE_SMOKE_SUCCESS",
        ))
        stdout += "\n" + "\n".join(app_smoke.media_smoke.MARKERS)
        stdout += "\n" + "\n".join(app_smoke.site_icon_smoke.MARKERS)
        stdout += "\n" + "\n".join(app_smoke.little_peek_smoke.MARKERS)
        stdout += "\n" + "\n".join(app_smoke.site_shortcuts_smoke.MARKERS)
        stdout += "\n" + "\n".join(app_smoke.app_link_smoke.MARKERS)
        stdout += "\n" + "\n".join(app_smoke.member_sign_in_smoke.MARKERS)
        stdout += "\n" + "\n".join(app_smoke.bang_smoke.MARKERS)
        stdout += "\n" + "\n".join(app_smoke.hover_preview_smoke.MARKERS)
        stdout += "\n" + "\n".join(app_smoke.translation_smoke.MARKERS)
        stderr = "ARX_BOOTSTRAP_ENTRY threads=1\nARX_BOOTSTRAP_REGISTERED\nARX_BOOTSTRAP_FRAMEWORK_VERIFIED\n"
        good = subprocess.CompletedProcess("Arx", 0, stdout, stderr)
        app_smoke.verify_result(good, "fixture.log")
        # DEV-996: a Mac without the languages skips translation and says so.
        skipped = stdout
        for marker in app_smoke.translation_smoke.MARKERS:
            skipped = skipped.replace(marker, "")
        app_smoke.verify_result(
            subprocess.CompletedProcess("Arx", 0, skipped + "\nARX_TRANSLATE_SMOKE_SKIPPED languages", stderr), "fixture.log")
        for omitted in app_smoke.translation_smoke.MARKERS:
            result = subprocess.CompletedProcess("Arx", 0, stdout.replace(omitted, ""), stderr)
            with self.subTest(omitted=omitted), self.assertRaisesRegex(ValueError, "Translation smoke did not complete"):
                app_smoke.verify_result(result, "fixture.log")
        incomplete = (
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_ORGANIZATION_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_HOST_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_CAPTURE_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_APP_DOCUMENT_CAPTURE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_DOCUMENT_CAPTURE_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_INSPECTION_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_CLICK_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_FORM_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_KEYPRESS_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_SCROLL_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_WAIT_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_DOWNLOAD_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_SETTINGS_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_MCP_DEVELOPER_NATIVE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_ARCHIVE_SELECTED_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_ARCHIVE_CROSS_PROFILE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_DOWNLOAD_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_PRIVATE_DOWNLOAD_REOPEN_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_PAGE_DROP_SPLIT_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_PAGE_DROP_TARGETS_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_PAGE_MENUS_SMOKE_SAVE_LOADING_PDF", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout.replace("ARX_LOCAL_FILE_SMOKE_SUCCESS", ""), stderr),
            subprocess.CompletedProcess("Arx", 0, stdout, stderr.replace("ARX_BOOTSTRAP_FRAMEWORK_VERIFIED", "")),
            subprocess.CompletedProcess("Arx", 1, stdout, stderr),
        )
        for result in incomplete:
            with self.subTest(result=result), self.assertRaisesRegex(ValueError, "Arx smoke failed"):
                app_smoke.verify_result(result, "fixture.log")

        for omitted in app_smoke.site_icon_smoke.MARKERS:
            result = subprocess.CompletedProcess("Arx", 0, stdout.replace(omitted, ""), stderr)
            with self.subTest(omitted=omitted), self.assertRaisesRegex(ValueError, "Native site icon smoke incomplete"):
                app_smoke.verify_result(result, "fixture.log")

        for omitted in app_smoke.little_peek_smoke.MARKERS:
            result = subprocess.CompletedProcess("Arx", 0, stdout.replace(omitted, ""), stderr)
            with self.subTest(omitted=omitted), self.assertRaisesRegex(ValueError, "Little Peek smoke did not complete"):
                app_smoke.verify_result(result, "fixture.log")

        for omitted in app_smoke.app_link_smoke.MARKERS:
            result = subprocess.CompletedProcess("Arx", 0, stdout.replace(omitted, ""), stderr)
            with self.subTest(omitted=omitted), self.assertRaisesRegex(ValueError, "App link smoke did not complete"):
                app_smoke.verify_result(result, "fixture.log")

        for omitted in app_smoke.bang_smoke.MARKERS:
            result = subprocess.CompletedProcess("Arx", 0, stdout.replace(omitted, ""), stderr)
            with self.subTest(omitted=omitted), self.assertRaisesRegex(ValueError, "Bang navigation smoke did not complete"):
                app_smoke.verify_result(result, "fixture.log")

        for omitted in app_smoke.hover_preview_smoke.MARKERS:
            result = subprocess.CompletedProcess("Arx", 0, stdout.replace(omitted, ""), stderr)
            with self.subTest(omitted=omitted), self.assertRaisesRegex(ValueError, "Hover preview smoke did not complete"):
                app_smoke.verify_result(result, "fixture.log")

    def test_every_required_marker_is_still_printed_by_the_app(self):
        # 21 Nov: the command bar appearance smoke was removed with its marker still required, and
        # every app smoke failed after all its phases passed (DEV-1277).
        root = Path(__file__).resolve().parents[2] / "Packages"
        sources = "".join(
            path.read_text(errors="ignore")
            for pattern in ("*.swift", "*.mm", "*.cc", "*.c")
            for path in root.glob(f"*/Sources/**/{pattern}")
        )
        for marker in app_smoke.STDOUT_MARKERS + app_smoke.STDERR_MARKERS:
            with self.subTest(marker=marker):
                self.assertTrue(marker.strip() in sources, f"{marker} is printed nowhere in Packages")

    def test_failure_names_the_missing_markers(self):
        stdout = "\n".join(app_smoke.STDOUT_MARKERS).replace("ARX_PEEK_SMOKE_SUCCESS", "")
        stderr = "\n".join(app_smoke.STDERR_MARKERS)
        with self.assertRaisesRegex(ValueError, "missing ARX_PEEK_SMOKE_SUCCESS; inspect fixture.log"):
            app_smoke.verify_result(subprocess.CompletedProcess("Arx", 0, stdout, stderr), "fixture.log")

    def test_zero_exit_cannot_hide_missing_native_media_phases(self):
        ordinary = "\n".join((
            "ARX_APP_SMOKE_SUCCESS", "ARX_APP_REOPEN_SMOKE_SUCCESS",
            "ARX_PROFILE_ISOLATION_SMOKE_SUCCESS", "ARX_CACHE_RELOAD_SMOKE_SUCCESS",
            "ARX_HISTORY_SMOKE_SUCCESS", "ARX_PROFILE_HISTORY_SMOKE_SUCCESS",
            "ARX_TAB_MOVE_SMOKE_SUCCESS", "ARX_SHARED_FAVORITE_SMOKE_SUCCESS", "ARX_INDEPENDENT_WINDOW_SMOKE_SUCCESS", "ARX_MCP_NATIVE_SMOKE_SUCCESS", "ARX_DOWNLOAD_SMOKE_SUCCESS",
            "ARX_MCP_ORGANIZATION_NATIVE_SMOKE_SUCCESS", "ARX_MCP_HOST_NATIVE_SMOKE_SUCCESS",
            "ARX_MCP_CAPTURE_NATIVE_SMOKE_SUCCESS",
            "ARX_APP_DOCUMENT_CAPTURE_SMOKE_SUCCESS", "ARX_MCP_DOCUMENT_CAPTURE_NATIVE_SMOKE_SUCCESS",
            "ARX_MCP_INSPECTION_NATIVE_SMOKE_SUCCESS", "ARX_MCP_CLICK_NATIVE_SMOKE_SUCCESS", "ARX_MCP_FORM_NATIVE_SMOKE_SUCCESS",
            "ARX_MCP_KEYPRESS_NATIVE_SMOKE_SUCCESS",
            "ARX_MCP_SCROLL_NATIVE_SMOKE_SUCCESS",
            "ARX_MCP_WAIT_NATIVE_SMOKE_SUCCESS", "ARX_MCP_DOWNLOAD_NATIVE_SMOKE_SUCCESS",
            "ARX_MCP_SETTINGS_NATIVE_SMOKE_SUCCESS", "ARX_MCP_DEVELOPER_NATIVE_SMOKE_SUCCESS", "ARX_MCP_PASSWORD_SIGN_IN_PHASE_NO_SAVED_PASSWORD",
            "ARX_ARCHIVE_SELECTED_SMOKE_SUCCESS", "ARX_ARCHIVE_CROSS_PROFILE_SMOKE_SUCCESS",
            "ARX_PRIVATE_DOWNLOAD_REOPEN_SMOKE_SUCCESS",
            "ARX_SPLIT_SMOKE_SUCCESS", "ARX_PAGE_DROP_SPLIT_SMOKE_SUCCESS", "ARX_PAGE_DROP_TARGETS_SMOKE_SUCCESS", "ARX_TAB_TEAR_OFF_SMOKE_SUCCESS",
            "ARX_PEEK_SMOKE_SUCCESS",
            "ARX_PRIVATE_PROFILE_SMOKE_SUCCESS",
            "ARX_SHORTCUTS_SMOKE_SUCCESS", "ARX_LITTLE_PROMOTION_SMOKE_SUCCESS", "ARX_RENDERER_RECOVERY_SMOKE_SUCCESS",
            "ARX_ROUTING_PROFILE_PICKER_SMOKE_SUCCESS",
            "ARX_PAGE_MENUS_SMOKE_LINK_ITEMS", "ARX_PAGE_MENUS_SMOKE_LINK_NEW_WINDOW",
            "ARX_PAGE_MENUS_SMOKE_SAVE_LOADING_PDF",
            "ARX_LOCAL_FILE_SMOKE_SUCCESS",
        ))
        stderr = "ARX_BOOTSTRAP_ENTRY threads=1\nARX_BOOTSTRAP_REGISTERED\nARX_BOOTSTRAP_FRAMEWORK_VERIFIED\n"
        ordinary += "\n" + "\n".join(app_smoke.little_peek_smoke.MARKERS)
        ordinary += "\n" + "\n".join(app_smoke.app_link_smoke.MARKERS)
        for omitted in app_smoke.media_smoke.MARKERS:
            stdout = ordinary + "\n" + "\n".join(marker for marker in app_smoke.media_smoke.MARKERS if marker != omitted)
            with self.subTest(omitted=omitted), self.assertRaisesRegex(ValueError, "Native media smoke did not complete"):
                app_smoke.verify_result(subprocess.CompletedProcess("Arx", 0, stdout, stderr), "fixture.log")

    def test_crash_injection_ignores_other_processes_and_utility_children(self):
        process = Mock(pid=100)
        process.poll.return_value = None
        request = Mock()
        request.exists.return_value = True
        stopped = Mock()
        stopped.wait.return_value = False
        errors = []
        outputs = [
            "201\n202\n203\n",
            "100 Arx Helper --type=renderer",
            "100 Arx Helper --type=utility",
            "999 Other Browser --type=renderer",
        ]
        results = [subprocess.CompletedProcess([], 0, stdout=value) for value in outputs]

        with (
            patch("Scripts.app_smoke.subprocess.run", side_effect=results),
            patch("Scripts.app_smoke.os.kill") as terminate,
        ):
            terminate_smoke_renderers(process, request, stopped, errors)

        terminate.assert_called_once_with(201, signal.SIGKILL)
        self.assertEqual(errors, [])

    def test_app_preflight_failure_retains_a_failed_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with (
                patch.object(smoke, "ROOT", root),
                patch.object(app_smoke.build_app, "main", side_effect=ValueError("No matching engine")),
            ):
                with self.assertRaisesRegex(ValueError, "No matching engine"):
                    app_smoke.main()
            contents = (root / "build/logs/runtime/app-smoke.log").read_text()
            self.assertIn("FAILED: No matching engine", contents)
            self.assertNotIn("PASSED", contents)

    def test_every_run_keeps_its_own_log_and_the_fixed_path_shows_the_latest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "build/logs/runtime"
            runtime.mkdir(parents=True)
            (runtime / "app-smoke.log").write_text("pre-retention run\n")
            with patch.object(smoke, "ROOT", root):
                with self.assertRaisesRegex(ValueError, "first"):
                    with smoke.log("app-smoke"):
                        raise ValueError("first")
                with smoke.log("app-smoke") as second:
                    smoke.append(second, "second output\n")

            runs = sorted((runtime / "app-smoke").iterdir())
            contents = [run.read_text() for run in runs]
            self.assertEqual(len(runs), 3)
            self.assertTrue(any(text == "pre-retention run\n" for text in contents))
            self.assertTrue(any("FAILED: first" in text for text in contents))
            latest = runtime / "app-smoke.log"
            self.assertTrue(latest.is_symlink())
            self.assertFalse(Path(latest.readlink()).is_absolute())
            self.assertEqual(latest.resolve(), second.resolve())
            self.assertIn("second output", latest.read_text())
            self.assertIn("PASSED", latest.read_text())

    def test_engine_timeout_preserves_both_streams(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            timeout = subprocess.TimeoutExpired("ChromiumHost", 60, output=b"startup\n", stderr=b"crash detail\n")
            with (
                patch.object(smoke, "ROOT", root),
                patch.object(engine_smoke, "WORK", root),
                patch.object(engine_smoke.host, "main"),
                patch.object(engine_smoke.http.server, "ThreadingHTTPServer"),
                patch.object(engine_smoke.subprocess, "run", side_effect=timeout),
            ):
                with self.assertRaisesRegex(ValueError, "timed out"):
                    engine_smoke.main()
            contents = (root / "build/logs/runtime/engine-smoke.log").read_text()
            self.assertIn("startup\ncrash detail", contents)
            self.assertIn("FAILED:", contents)

    def test_engine_zero_exit_without_success_marker_is_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = subprocess.CompletedProcess("ChromiumHost", 0, stdout="exited early", stderr="")
            with (
                patch.object(smoke, "ROOT", root),
                patch.object(engine_smoke, "WORK", root),
                patch.object(engine_smoke.host, "main"),
                patch.object(engine_smoke.http.server, "ThreadingHTTPServer"),
                patch.object(engine_smoke.subprocess, "run", return_value=result),
            ):
                with self.assertRaisesRegex(ValueError, "smoke failed"):
                    engine_smoke.main()
            contents = (root / "build/logs/runtime/engine-smoke.log").read_text()
            self.assertIn("exited early", contents)
            self.assertNotIn("PASSED", contents)

    def test_runtime_gate_stops_after_failed_host(self):
        with (
            patch.object(test_runtime.engine_smoke, "main", side_effect=ValueError("host failed")),
            patch.object(test_runtime.app_smoke, "main") as app,
        ):
            with self.assertRaisesRegex(ValueError, "host failed"):
                test_runtime.main()
        app.assert_not_called()


if __name__ == "__main__":
    unittest.main()
