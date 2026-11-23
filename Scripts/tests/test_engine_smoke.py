"""Require an explicit disposable fixture and native mock-Keychain evidence."""

import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from Scripts.core import smoke
from Scripts.engine import smoke as engine_smoke
from Scripts.engine import back_forward_cache_smoke, background_visibility_smoke, extension_install_smoke, reference_keypress_smoke, gesture_smoke, document_capture_smoke, link_context_smoke, focused_link_smoke, cross_site_link_smoke, site_settings_smoke, browsing_data_smoke, close_smoke, extensions_smoke, inspection_smoke, reference_click_smoke, reference_form_smoke, reference_scroll_smoke


class EngineSmokeTests(unittest.TestCase):
    def test_runner_owns_fresh_fixture_and_requires_both_exact_markers(self):
        cases = [
            (0, "ARX_ENGINE_SMOKE_SUCCESS\n", "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN\nARX_ENGINE_SMOKE_FIND_VERIFIED\n", True),
            (0, "ARX_ENGINE_SMOKE_SUCCESS\n", "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN\n", False),
            (1, "ARX_ENGINE_SMOKE_SUCCESS\n", "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN\n", False),
            (0, "ARX_ENGINE_SMOKE_SUCCESS\n", "", False),
            (0, "", "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN\n", False),
            (0, "expected ARX_ENGINE_SMOKE_SUCCESS\n", "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN\n", False),
            (0, "ARX_ENGINE_SMOKE_SUCCESS\n", "expected ARX_ENGINE_SMOKE_MOCK_KEYCHAIN\n", False),
        ]
        for returncode, stdout, stderr, expected_success in cases:
            with self.subTest(returncode=returncode, stdout=stdout, stderr=stderr):
                self.check_run(returncode, stdout, stderr, expected_success)

    def test_extension_runner_requires_every_marker_and_ignores_caller_profile(self):
        markers = [
            "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", "ARX_EXTENSION_FIXTURE_OWNED_STORAGE",
            "ARX_EXTENSION_SMOKE_WORKER_DNR", "ARX_EXTENSION_SMOKE_DISABLE_ENABLE_STALE",
            "ARX_EXTENSION_SMOKE_PROFILE_ISOLATION", "ARX_EXTENSION_SMOKE_OPTIONS_IDENTITY",
            "ARX_EXTENSION_SMOKE_OPTIONS_STALE", "ARX_EXTENSION_SMOKE_ACTION_IDENTITY",
            "ARX_EXTENSION_SMOKE_ACTION_STALE", "ARX_EXTENSION_SMOKE_POPUP_LINK", "ARX_EXTENSION_SMOKE_RUNTIME_OPTIONS",
            "ARX_EXTENSION_SMOKE_APP_ACTION", "ARX_EXTENSION_SMOKE_BUTTON_INVISIBLE",
            "ARX_EXTENSION_SMOKE_POPUP_WINDOW",
                       "ARX_EXTENSION_SMOKE_SHORTCUT_SCOPE", "ARX_EXTENSION_SMOKE_SHORTCUT_REPLAY",
            "ARX_EXTENSION_SMOKE_SHORTCUT_WITHOUT_FOCUS_WAIT", "ARX_EXTENSION_SMOKE_TABS_SCOPE", "ARX_EXTENSION_SMOKE_WINDOW_SCOPE", "ARX_EXTENSION_SMOKE_NATIVE_MESSAGING_SCOPE",
            "ARX_EXTENSION_SMOKE_NATIVE_MESSAGING_LIFECYCLE", "ARX_EXTENSION_SMOKE_PRIVATE_ACTION",
            "ARX_EXTENSION_SMOKE_PRIVATE_MENU", "ARX_EXTENSION_SMOKE_PRIVATE_GATE", "ARX_EXTENSION_SMOKE_PERMISSION_GUARD",
            "ARX_EXTENSION_SMOKE_REMOVE_ISOLATION", "ARX_EXTENSION_SMOKE_ELEMENT_PICKER",
            "ARX_EXTENSION_SMOKE_SITE_HIDING", "ARX_EXTENSION_SMOKE_SCRIPTLET",
            "ARX_EXTENSION_SMOKE_OWN_ELEMENT_PICKER", "ARX_EXTENSION_SMOKE_HIDE_ELEMENT_MODE",
            "ARX_EXTENSION_SMOKE_PRIVATE_DENIED",
            "ARX_EXTENSION_SMOKE_VERIFIED",
        ]
        self.check_run(0, "ARX_EXTENSION_SMOKE_SUCCESS\n", "\n".join(markers), True, extensions=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_EXTENSION_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, extensions=True)
        self.check_run(0, "ARX_EXTENSION_SMOKE_SUCCESS\n", "\n".join(markers),
                       False, extensions=True, touches_caller_profile=True)
        self.check_run(0, "ARX_ENGINE_SMOKE_SUCCESS\n", "\n".join(markers), False, extensions=True)

    def test_extension_install_requires_every_verified_consent_phase(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.EXTENSION_INSTALL_MARKERS]
        self.check_run(0, "ARX_EXTENSION_INSTALL_SMOKE_SUCCESS\n", "\n".join(markers), True, extension_install=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_EXTENSION_INSTALL_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, extension_install=True)
        self.check_run(0, "ARX_EXTENSION_INSTALL_SMOKE_SUCCESS\n", "\n".join(markers),
                       False, extension_install=True, touches_caller_profile=True)
        self.check_run(1, "ARX_EXTENSION_INSTALL_SMOKE_SUCCESS\n", "\n".join(markers), False, extension_install=True)

    def test_extensions_handler_serves_the_blocking_fixture_from_memory(self):
        handler = object.__new__(engine_smoke.ExtensionsHandler)
        handler.send_response = Mock()
        handler.send_header = Mock()
        handler.end_headers = Mock()
        handler.wfile = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            handler.path = "/blocking.html"
            handler.do_GET()
            serve_file.assert_not_called()
            handler.wfile.write.assert_called_once_with(engine_smoke.ExtensionsHandler.BLOCKING)
            handler.path = "/index.html"
            handler.do_GET()
            serve_file.assert_called_once()

    def test_extensions_handler_serves_the_picker_fixture_without_scripts_or_styles(self):
        handler = object.__new__(engine_smoke.ExtensionsHandler)
        handler.send_response = Mock()
        handler.send_header = Mock()
        handler.end_headers = Mock()
        handler.wfile = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            handler.path = "/picker.html"
            handler.do_GET()
            serve_file.assert_not_called()
            handler.wfile.write.assert_called_once_with(engine_smoke.ExtensionsHandler.PICKER)
            self.assertIn(b"class=arx-pick-target", engine_smoke.ExtensionsHandler.PICKER)
            self.assertIn(b"class=arx-mode-target", engine_smoke.ExtensionsHandler.PICKER)
            handler.send_header.assert_any_call("Content-Security-Policy",
                                                "default-src 'none'; script-src 'none'; style-src 'none'")
            handler.send_header.reset_mock()
            handler.path = "/blocking.html"
            handler.do_GET()
            headers = [call.args[0] for call in handler.send_header.call_args_list]
            self.assertNotIn("Content-Security-Policy", headers)

    def test_extension_install_handler_refuses_profile_files_and_queries(self):
        handler = object.__new__(engine_smoke.ExtensionInstallHandler)
        handler.send_error = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            for path in ("/", "/profile/Default/Preferences", "/.arx-engine-smoke", "/index.html?other", "/extension-blocked"):
                handler.path = path
                handler.do_GET()
            self.assertEqual(handler.send_error.call_count, 5)
            serve_file.assert_not_called()
            handler.path = "/index.html"
            handler.do_GET()
            serve_file.assert_called_once()

    def test_close_fixture_requires_every_native_marker(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", "ARX_CLOSE_SMOKE_CANCEL_OTHER_PAGE",
                   "ARX_CLOSE_SMOKE_NAVIGATION_STALE", "ARX_CLOSE_SMOKE_RELOAD_STALE",
                   "ARX_CLOSE_SMOKE_CONSUMED_ONCE", "ARX_CLOSE_SMOKE_VERIFIED"]
        self.check_run(0, "ARX_CLOSE_SMOKE_SUCCESS\n", "\n".join(markers), True, authorized_close=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_CLOSE_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, authorized_close=True)
        self.check_run(0, "ARX_ENGINE_SMOKE_SUCCESS\n", "\n".join(markers), False, authorized_close=True)

    def test_inspection_fixture_requires_every_phase_and_clean_shutdown(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.INSPECTION_MARKERS]
        self.check_run(0, "ARX_INSPECTION_SMOKE_SUCCESS\n", "\n".join(markers), True, inspection=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_INSPECTION_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, inspection=True)
        self.check_run(1, "ARX_INSPECTION_SMOKE_SUCCESS\n", "\n".join(markers), False, inspection=True)
        self.check_run(0, "expected ARX_INSPECTION_SMOKE_SUCCESS\n", "\n".join(markers), False, inspection=True)

    def test_reference_click_requires_all_effect_receipts_and_clean_shutdown(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.REFERENCE_CLICK_MARKERS]
        self.check_run(0, "ARX_REFERENCE_CLICK_SMOKE_SUCCESS\n", "\n".join(markers), True, reference_click=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_REFERENCE_CLICK_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, reference_click=True)
        self.check_run(1, "ARX_REFERENCE_CLICK_SMOKE_SUCCESS\n", "\n".join(markers), False, reference_click=True)
        self.check_run(0, "expected ARX_REFERENCE_CLICK_SMOKE_SUCCESS\n", "\n".join(markers), False, reference_click=True)

    def test_reference_scroll_requires_every_phase_and_clean_shutdown(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.REFERENCE_SCROLL_MARKERS]
        self.check_run(0, "ARX_REFERENCE_SCROLL_SMOKE_SUCCESS\n", "\n".join(markers), True, reference_scroll=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_REFERENCE_SCROLL_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, reference_scroll=True)
        self.check_run(1, "ARX_REFERENCE_SCROLL_SMOKE_SUCCESS\n", "\n".join(markers), False, reference_scroll=True)
        self.check_run(0, "expected ARX_REFERENCE_SCROLL_SMOKE_SUCCESS\n", "\n".join(markers), False, reference_scroll=True)

    def test_document_capture_requires_actual_pixel_state_and_invalidation_markers(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.DOCUMENT_CAPTURE_MARKERS]
        self.check_run(0, "ARX_DOCUMENT_CAPTURE_SMOKE_SUCCESS\n", "\n".join(markers), True, document_capture=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_DOCUMENT_CAPTURE_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, document_capture=True)
        self.check_run(0, "ARX_DOCUMENT_CAPTURE_SMOKE_SUCCESS\n", "\n".join(markers),
                       False, document_capture=True, touches_caller_profile=True)
        self.check_run(1, "ARX_DOCUMENT_CAPTURE_SMOKE_SUCCESS\n", "\n".join(markers), False, document_capture=True)

    def test_document_handler_never_serves_profile_data(self):
        handler = object.__new__(engine_smoke.DocumentCaptureHandler)
        handler.send_error = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            for path in ("/", "/profile/Default/Preferences", "/.arx-engine-smoke", "/other"):
                handler.path = path
                handler.do_GET()
            self.assertEqual(handler.send_error.call_count, 4)
            serve_file.assert_not_called()

    def test_gesture_requires_real_phase_markers_owned_storage_and_clean_shutdown(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.GESTURE_MARKERS]
        self.check_run(0, "ARX_GESTURE_SMOKE_SUCCESS\n", "\n".join(markers), True, gestures=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_GESTURE_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, gestures=True)
        self.check_run(1, "ARX_GESTURE_SMOKE_SUCCESS\n", "\n".join(markers), False, gestures=True)
        self.check_run(0, "expected ARX_GESTURE_SMOKE_SUCCESS\n", "\n".join(markers), False, gestures=True)
        self.check_run(0, "ARX_GESTURE_SMOKE_SUCCESS\n", "\n".join(markers),
                       False, gestures=True, touches_caller_profile=True)

    def test_background_visibility_requires_every_phase_and_clean_shutdown(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.BACKGROUND_VISIBILITY_MARKERS]
        self.check_run(0, "ARX_BACKGROUND_VISIBILITY_SMOKE_SUCCESS\n", "\n".join(markers), True,
                       background_visibility=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_BACKGROUND_VISIBILITY_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, background_visibility=True)
        self.check_run(1, "ARX_BACKGROUND_VISIBILITY_SMOKE_SUCCESS\n", "\n".join(markers), False,
                       background_visibility=True)
        self.check_run(0, "ARX_ENGINE_SMOKE_SUCCESS\n", "\n".join(markers), False, background_visibility=True)

    def test_background_visibility_handler_serves_only_fixture_routes(self):
        handler = object.__new__(engine_smoke.BackgroundVisibilityHandler)
        handler.send_error = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            for path in ("/", "/profile/Default/Preferences", "/.arx-engine-smoke", "/visibility/other"):
                handler.path = path
                handler.do_GET()
            self.assertEqual(handler.send_error.call_count, 4)
            serve_file.assert_not_called()
            handler.path = "/index.html"
            handler.do_GET()
            serve_file.assert_called_once()

    def test_link_context_requires_every_phase_and_clean_shutdown(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.LINK_CONTEXT_MARKERS]
        self.check_run(0, "ARX_LINK_CONTEXT_SMOKE_SUCCESS\n", "\n".join(markers), True, link_context=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_LINK_CONTEXT_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, link_context=True)
        self.check_run(1, "ARX_LINK_CONTEXT_SMOKE_SUCCESS\n", "\n".join(markers), False, link_context=True)
        self.check_run(0, "expected ARX_LINK_CONTEXT_SMOKE_SUCCESS\n", "\n".join(markers), False, link_context=True)

    def test_focused_link_requires_every_phase_and_clean_shutdown(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.FOCUSED_LINK_MARKERS]
        self.check_run(0, "ARX_FOCUSED_LINK_SMOKE_SUCCESS\n", "\n".join(markers), True, focused_link=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_FOCUSED_LINK_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, focused_link=True)
        self.check_run(1, "ARX_FOCUSED_LINK_SMOKE_SUCCESS\n", "\n".join(markers), False, focused_link=True)
        self.check_run(0, "expected ARX_FOCUSED_LINK_SMOKE_SUCCESS\n", "\n".join(markers), False, focused_link=True)

    def test_cross_site_link_requires_every_phase_and_clean_shutdown(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.CROSS_SITE_LINK_MARKERS]
        self.check_run(0, "ARX_CROSS_SITE_LINK_SMOKE_SUCCESS\n", "\n".join(markers), True, cross_site_link=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_CROSS_SITE_LINK_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, cross_site_link=True)
        self.check_run(1, "ARX_CROSS_SITE_LINK_SMOKE_SUCCESS\n", "\n".join(markers), False, cross_site_link=True)

    def test_back_forward_cache_requires_every_phase_and_clean_shutdown(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.BACK_FORWARD_CACHE_MARKERS]
        self.check_run(0, "ARX_BACK_FORWARD_CACHE_SMOKE_SUCCESS\n", "\n".join(markers), True, back_forward_cache=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_BACK_FORWARD_CACHE_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, back_forward_cache=True)
        self.check_run(1, "ARX_BACK_FORWARD_CACHE_SMOKE_SUCCESS\n", "\n".join(markers), False, back_forward_cache=True)

    def test_back_forward_cache_handler_never_serves_profile_data(self):
        handler = object.__new__(engine_smoke.BackForwardCacheHandler)
        handler.send_error = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            for path in ("/", "/profile/Default/Preferences", "/.arx-engine-smoke", "/other"):
                handler.path = path
                handler.do_GET()
            self.assertEqual(handler.send_error.call_count, 4)
            serve_file.assert_not_called()

    def test_back_forward_cache_handler_serves_only_the_fixture_video(self):
        handler = object.__new__(engine_smoke.BackForwardCacheHandler)
        handler.send_error = Mock()
        with patch.object(engine_smoke.media_fixture, "serve", return_value=True) as video:
            handler.path = "/media/pattern.webm"
            handler.do_GET()
            handler.path = "/media/normal.html"
            handler.do_GET()
        video.assert_called_once_with(handler)
        handler.send_error.assert_called_once_with(404)

    def test_back_forward_cache_handler_records_each_answer(self):
        engine_smoke.back_forward_cache_fixture.reset()
        handler = object.__new__(engine_smoke.BackForwardCacheHandler)
        handler.command = "GET"
        handler.path = "/media/pattern.webm"
        handler.headers = {"Range": "bytes=0-"}
        handler.log_request(engine_smoke.http.HTTPStatus.PARTIAL_CONTENT)
        handler.path = "/back-forward-cache/media"
        handler.headers = {}
        handler.log_request(200)
        lines = engine_smoke.back_forward_cache_fixture.request_log().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertRegex(lines[0], r"^ARX_BACK_FORWARD_CACHE_FIXTURE_REQUEST \d+\.\d{3}s GET /media/pattern\.webm 206 range=bytes=0-$")
        self.assertRegex(lines[1], r"^ARX_BACK_FORWARD_CACHE_FIXTURE_REQUEST \d+\.\d{3}s GET /back-forward-cache/media 200$")
        engine_smoke.back_forward_cache_fixture.reset()
        self.assertEqual(engine_smoke.back_forward_cache_fixture.request_log(), "")

    def test_back_forward_cache_log_holds_the_fixture_requests(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.BACK_FORWARD_CACHE_MARKERS]
        with patch.object(engine_smoke.back_forward_cache_fixture, "request_log",
                          return_value="ARX_BACK_FORWARD_CACHE_FIXTURE_REQUEST 0.100s GET /back-forward-cache/a 200\n"):
            self.check_run(1, "", "\n".join(markers), False, back_forward_cache=True,
                           expected_log="ARX_BACK_FORWARD_CACHE_FIXTURE_REQUEST 0.100s GET /back-forward-cache/a 200")

    def test_back_forward_cache_failure_names_what_the_host_saw(self):
        failure = ("ARX_BACK_FORWARD_CACHE_SMOKE_FAILED phase=first-load reason=timed-out wait=stored-icon "
                   "last=page=http://127.0.0.1:12345/back-forward-cache/a,"
                   "icon=http://127.0.0.1:12345/back-forward-cache/icon.png,store=missing,reads=51,"
                   "changes=1,reported=none")
        stderr = "\n".join(["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", failure])
        self.check_run(1, "", stderr, False, back_forward_cache=True,
                       expected_error=r"^Chromium smoke failed: " + re.escape(failure) + r"; inspect .+\.log$",
                       expected_log=failure)

    def test_back_forward_cache_failure_without_a_host_line_points_at_the_log(self):
        self.check_run(1, "", "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", False, back_forward_cache=True,
                       expected_error=r"^Chromium smoke failed; inspect .+\.log$")

    def test_failure_line_is_the_first_exact_marker(self):
        prefix = engine_smoke.BACK_FORWARD_CACHE_FAILED
        stderr = "\n".join([
            "ARX_BACK_FORWARD_CACHE_SMOKE_FIRST_LOAD",
            f"{prefix}_OTHER phase=leave",
            f"{prefix} phase=icon reason=timed-out wait=stored-icon",
            f"{prefix} phase=media reason=later",
        ])
        self.assertEqual(engine_smoke.failure_line(stderr, prefix),
                         f"{prefix} phase=icon reason=timed-out wait=stored-icon")
        self.assertIsNone(engine_smoke.failure_line("ARX_ENGINE_SMOKE_MOCK_KEYCHAIN\n", prefix))
        self.assertIsNone(engine_smoke.failure_line("", prefix))

    def test_cross_site_link_handler_never_serves_profile_data(self):
        handler = object.__new__(engine_smoke.CrossSiteLinkHandler)
        handler.send_error = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            for path in ("/", "/profile/Default/Preferences", "/.arx-engine-smoke", "/other"):
                handler.path = path
                handler.do_GET()
            self.assertEqual(handler.send_error.call_count, 4)
            serve_file.assert_not_called()

    def test_site_settings_requires_every_phase_and_clean_shutdown(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.SITE_SETTINGS_MARKERS]
        self.check_run(0, "ARX_SITE_SETTINGS_SMOKE_SUCCESS\n", "\n".join(markers), True, site_settings=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_SITE_SETTINGS_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, site_settings=True)
        self.check_run(1, "ARX_SITE_SETTINGS_SMOKE_SUCCESS\n", "\n".join(markers), False, site_settings=True)

    def test_browsing_data_requires_every_phase_and_clean_shutdown(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.BROWSING_DATA_MARKERS]
        self.check_run(0, "ARX_BROWSING_DATA_SMOKE_SUCCESS\n", "\n".join(markers), True, browsing_data=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_BROWSING_DATA_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, browsing_data=True)
        self.check_run(1, "ARX_BROWSING_DATA_SMOKE_SUCCESS\n", "\n".join(markers), False, browsing_data=True)

    def test_focused_link_handler_never_serves_profile_data(self):
        handler = object.__new__(engine_smoke.FocusedLinkHandler)
        handler.send_error = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            for path in ("/", "/profile/Default/Preferences", "/.arx-engine-smoke", "/other"):
                handler.path = path
                handler.do_GET()
            self.assertEqual(handler.send_error.call_count, 4)
            serve_file.assert_not_called()

    def test_link_context_handler_never_serves_profile_data(self):
        handler = object.__new__(engine_smoke.LinkContextHandler)
        handler.send_error = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            for path in ("/", "/profile/Default/Preferences", "/.arx-engine-smoke", "/other"):
                handler.path = path
                handler.do_GET()
            self.assertEqual(handler.send_error.call_count, 4)
            serve_file.assert_not_called()

    def test_reference_scroll_handler_never_serves_profile_data(self):
        handler = object.__new__(engine_smoke.ReferenceScrollHandler)
        handler.send_error = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            for path in ("/", "/profile/Default/Preferences", "/.arx-engine-smoke", "/other"):
                handler.path = path
                handler.do_GET()
            self.assertEqual(handler.send_error.call_count, 4)
            serve_file.assert_not_called()

    def test_reference_keypress_requires_every_hostile_phase_and_clean_shutdown(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.REFERENCE_KEYPRESS_MARKERS]
        self.check_run(0, "ARX_REFERENCE_KEYPRESS_SMOKE_SUCCESS\n", "\n".join(markers), True, reference_keypress=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_REFERENCE_KEYPRESS_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, reference_keypress=True)
        self.check_run(1, "ARX_REFERENCE_KEYPRESS_SMOKE_SUCCESS\n", "\n".join(markers), False, reference_keypress=True)
        self.check_run(0, "expected ARX_REFERENCE_KEYPRESS_SMOKE_SUCCESS\n", "\n".join(markers), False, reference_keypress=True)

    def test_reference_keypress_handler_never_serves_profile_data(self):
        handler = object.__new__(engine_smoke.ReferenceKeypressHandler)
        handler.send_error = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            for path in ("/", "/profile/Default/Preferences", "/.arx-engine-smoke", "/other"):
                handler.path = path
                handler.do_GET()
            self.assertEqual(handler.send_error.call_count, 4)
            serve_file.assert_not_called()

    def test_reference_form_requires_every_phase_and_clean_shutdown(self):
        markers = ["ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", *engine_smoke.REFERENCE_FORM_MARKERS]
        self.check_run(0, "ARX_REFERENCE_FORM_SMOKE_SUCCESS\n", "\n".join(markers), True, reference_form=True)
        for missing in markers:
            with self.subTest(missing=missing):
                self.check_run(0, "ARX_REFERENCE_FORM_SMOKE_SUCCESS\n",
                               "\n".join(marker for marker in markers if marker != missing),
                               False, reference_form=True)
        self.check_run(1, "ARX_REFERENCE_FORM_SMOKE_SUCCESS\n", "\n".join(markers), False, reference_form=True)
        self.check_run(0, "expected ARX_REFERENCE_FORM_SMOKE_SUCCESS\n", "\n".join(markers), False, reference_form=True)

    def test_reference_form_handler_never_serves_profile_data(self):
        handler = object.__new__(engine_smoke.ReferenceFormHandler)
        handler.send_error = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            for path in ("/", "/profile/Default/Preferences", "/.arx-engine-smoke", "/other"):
                handler.path = path
                handler.do_GET()
            self.assertEqual(handler.send_error.call_count, 4)
            serve_file.assert_not_called()

    def test_reference_click_handler_never_serves_profile_data(self):
        handler = object.__new__(engine_smoke.ReferenceClickHandler)
        handler.send_error = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            for path in ("/", "/profile/Default/Preferences", "/.arx-engine-smoke", "/other"):
                handler.path = path
                handler.do_GET()
            self.assertEqual(handler.send_error.call_count, 4)
            serve_file.assert_not_called()

    def test_mixed_inspection_modes_fail_before_host_build(self):
        with patch.object(engine_smoke.host, "main") as build:
            for option in ("extension_install", "extensions", "authorized_close", "reference_click", "reference_form", "reference_scroll", "link_context", "reference_keypress"):
                with self.assertRaisesRegex(ValueError, "one isolated"):
                    engine_smoke.run(Path("unused"), inspection=True, **{option: True})
            build.assert_not_called()

    def test_inspection_handler_never_serves_profile_files_or_directory_listing(self):
        handler = object.__new__(engine_smoke.InspectionHandler)
        handler.send_error = Mock()
        with patch.object(engine_smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            for path in ("/", "/profile/Default/Preferences", "/.arx-engine-smoke", "/other"):
                handler.path = path
                handler.do_GET()
            self.assertEqual(handler.send_error.call_count, 4)
            serve_file.assert_not_called()
            handler.path = "/index.html"
            handler.do_GET()
            serve_file.assert_called_once()

    def check_run(self, returncode, stdout, stderr, expected_success, *, extension_install=False, extensions=False, authorized_close=False, inspection=False, reference_click=False, reference_form=False, reference_scroll=False, link_context=False, document_capture=False, gestures=False, reference_keypress=False,
                  focused_link=False, site_settings=False, browsing_data=False, cross_site_link=False, background_visibility=False, back_forward_cache=False,
                  touches_caller_profile=False, expected_log=None, expected_error=None):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory).resolve()
            fixture = None

            def run(command, *, env, capture_output, text, timeout):
                nonlocal fixture
                self.assertEqual(command[1], "--disposable-smoke-root")
                self.assertEqual(len(command), 4 if extension_install or extensions or authorized_close or inspection or reference_click or reference_form or reference_scroll or link_context or document_capture or gestures or reference_keypress or focused_link or site_settings or browsing_data or cross_site_link or background_visibility or back_forward_cache else 3)
                if document_capture:
                    self.assertEqual(command[-1], "--document-capture-fixture")
                if gestures:
                    self.assertEqual(command[-1], "--gesture-fixture")
                if background_visibility:
                    self.assertEqual(command[-1], "--background-visibility-fixture")
                if extension_install:
                    self.assertEqual(command[-1], "--extension-install-fixture")
                if link_context:
                    self.assertEqual(command[-1], "--link-context-fixture")
                if focused_link:
                    self.assertEqual(command[-1], "--focused-link-fixture")
                if cross_site_link:
                    self.assertEqual(command[-1], "--cross-site-link-fixture")
                if back_forward_cache:
                    self.assertEqual(command[-1], "--back-forward-cache-fixture")
                if site_settings:
                    self.assertEqual(command[-1], "--site-settings-fixture")
                if browsing_data:
                    self.assertEqual(command[-1], "--browsing-data-fixture")
                if extensions:
                    self.assertEqual(command[-1], "--extension-fixture")
                if authorized_close:
                    self.assertEqual(command[-1], "--close-fixture")
                if inspection:
                    self.assertEqual(command[-1], "--inspection-fixture")
                if reference_click:
                    self.assertEqual(command[-1], "--reference-click-fixture")
                if reference_keypress:
                    self.assertEqual(command[-1], "--reference-keypress-fixture")
                if reference_form:
                    self.assertEqual(command[-1], "--reference-form-fixture")
                if reference_scroll:
                    self.assertEqual(command[-1], "--reference-scroll-fixture")
                fixture = Path(command[2])
                self.assertEqual(fixture.parent, work)
                self.assertEqual(fixture.resolve(), fixture)
                self.assertTrue(fixture.name.startswith("smoke-"))
                self.assertEqual(stat.S_IMODE(fixture.stat().st_mode), 0o700)
                # The host refuses a root holding anything else (HostSmokeConfiguration).
                self.assertEqual({p.name for p in fixture.iterdir()}, {".arx-engine-smoke", "index.html"})
                self.assertEqual((fixture / ".arx-engine-smoke").read_text(), "Arx disposable engine smoke\n")
                self.assertIn("<title>Arx engine smoke</title>", (fixture / "index.html").read_text())
                self.assertEqual(env["ARX_ENGINE_PROFILE"], str(fixture / "profile"))
                self.assertEqual(env["ARX_ENGINE_URL"], "http://127.0.0.1:12345/index.html")
                self.assertEqual(env["ARX_ENGINE_SMOKE_TITLE"], "Arx engine smoke")
                # Content blocking stays on only where it's under test.
                self.assertEqual(env["ARX_ENGINE_CONTENT_BLOCKING"],
                                 "1" if extensions or extension_install or site_settings else "0")
                self.assertTrue(capture_output and text)
                self.assertEqual(timeout, 180 if extension_install or extensions or authorized_close or inspection or reference_click or reference_form or reference_scroll or link_context or document_capture or gestures or reference_keypress or focused_link or site_settings or browsing_data or cross_site_link or background_visibility or back_forward_cache else 60)
                if touches_caller_profile:
                    (fixture / "profile").mkdir()
                return subprocess.CompletedProcess(command, returncode, stdout=stdout, stderr=stderr)

            with (
                patch.object(smoke, "ROOT", work),
                patch.object(engine_smoke, "WORK", work),
                patch.object(engine_smoke.host, "main") as build,
                patch.object(engine_smoke.http.server, "ThreadingHTTPServer") as server,
                patch.object(engine_smoke.subprocess, "run", side_effect=run),
            ):
                server.return_value.server_port = 12345
                main = back_forward_cache_smoke.main if back_forward_cache else background_visibility_smoke.main if background_visibility else cross_site_link_smoke.main if cross_site_link else browsing_data_smoke.main if browsing_data else site_settings_smoke.main if site_settings else focused_link_smoke.main if focused_link else extension_install_smoke.main if extension_install else reference_keypress_smoke.main if reference_keypress else gesture_smoke.main if gestures else document_capture_smoke.main if document_capture else link_context_smoke.main if link_context else reference_scroll_smoke.main if reference_scroll else reference_form_smoke.main if reference_form else reference_click_smoke.main if reference_click else inspection_smoke.main if inspection else close_smoke.main if authorized_close else extensions_smoke.main if extensions else engine_smoke.main
                if expected_success:
                    main()
                else:
                    with self.assertRaises(ValueError) as raised:
                        main()
                    if expected_error:
                        self.assertRegex(str(raised.exception), expected_error)
                build.assert_called_once_with(native_messaging_fixture=extensions)
                server.return_value.shutdown.assert_called_once()
                server.return_value.server_close.assert_called_once()
            self.assertIsNotNone(fixture)
            self.assertFalse(fixture.exists())
            name = "back-forward-cache-smoke" if back_forward_cache else "background-visibility-smoke" if background_visibility else "cross-site-link-smoke" if cross_site_link else "browsing-data-smoke" if browsing_data else "site-settings-smoke" if site_settings else "focused-link-smoke" if focused_link else "extension-install-smoke" if extension_install else "reference-keypress-smoke" if reference_keypress else "gesture-smoke" if gestures else "document-capture-smoke" if document_capture else "link-context-smoke" if link_context else "reference-scroll-smoke" if reference_scroll else "reference-form-smoke" if reference_form else "reference-click-smoke" if reference_click else "inspection-smoke" if inspection else "close-smoke" if authorized_close else "extensions-smoke" if extensions else "engine-smoke"
            contents = (work / f"build/logs/runtime/{name}.log").read_text()
            self.assertEqual("PASSED" in contents, expected_success)
            if expected_log:
                self.assertIn(expected_log, contents)


if __name__ == "__main__":
    unittest.main()
