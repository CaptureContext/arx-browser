"""Build checks cover every native bridge object and retain disk headroom."""

import signal
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from Scripts.engine import build


class EngineBuildTests(unittest.TestCase):
    sources = ["engine_bridge", "popup_host", "page_consent_host", "downloads_bridge", "capture_bridge", "page_capture_bridge", "media_bridge",
               "extensions_bridge", "extensions_install_bridge", "site_icons_bridge", "inspection_bridge", "pdf_bridge", "devtools_bridge", "developer_bridge", "network_capture_bridge", "focused_link_bridge", "page_zoom_bridge", "page_unload_bridge", "page_menu_bridge", "context_menu_bridge", "webstore_install_bridge", "link_navigation_bridge", "autofill_bridge", "autofill_settings", "password_bridge", "password_settings", "credential_import", "site_settings_bridge", "browsing_data_bridge", "content_blocking_bridge", "extension_menu_items", "private_download_prefs", "protected_media_bridge", "page_media_bridge", "battery_saver_bridge", "dark_pages_bridge", "device_chooser_bridge", "cast_bridge", "hovered_link_bridge", "browser_scheme_link_bridge",
               "profile_erasure/journal", "profile_erasure/bridge",
               "form_edits_bridge",
               # DEV-1264, DEV-1073.
               "page_command_key",
               # DEV-1309.
               "file_chooser_bridge",
               # DEV-1240.
               "extension_window_bridge",
               "gestures/controller", "gestures/panel", "gestures/fixture", "render_frame_host_impl", "navigation_request", "inspector", "script_runner", "page_media_agent",
               "frame_loader", "create_window", "remote_frame", "chrome_browser_interface_binders",
               "web_document", "web_element", "web_form_control_element", "chrome_content_renderer_client", "crx_installer", "webstore_private_api", "chrome_runtime_api_delegate", "extension_keybinding_registry", "extension_tab_util", "tabs_api", "windows_api", "http_auth_coordinator", "chrome_password_manager_client", "chrome_autofill_client", "chrome_payments_autofill_client", "configuration_policy_handler_list_factory", "chrome_authenticator_request_delegate", "identity_dialog_controller", "shutdown_watchdog_mac", "extension_prefs", "permission_request_manager", "web_contents_modal_dialog_manager_delegate",
               "external_protocol_handler", "external_protocol_dialog",
               "child_process_launcher_helper", "process_singleton_posix", "chrome_process_singleton",
               "profile_manager", "chrome_main_delegate", "chrome_content_browser_client", "gesture_event_queue", "render_input_router",
               "input_router_impl", "render_widget_host_impl", "chrome_render_widget_host_view_mac_delegate",
               "document_capture", "document_recorder", "record_admission", "png_encoding",
               "document_capture_fixture", "paint_preview_compositor_impl", "record_paint_canvas", "paint_controller", "paint_chunker",
               "paint_preview_recorder_utils", "web_local_frame_impl",
               "arx_local_volume", "output_controller", "stream_factory", "forwarding_audio_stream_factory",
               "web_contents_impl", "key_system_support_impl",
               "media_factory", "web_encrypted_media_client_impl", "navigator_request_media_key_system_access",
               "html_media_element_encrypted_media",
               "key_system_support_update", "media_interface_proxy", "chrome_content_browser_client_receiver_bindings",
               "chooser_bubble_ui",
               "dns_sd_device_lister", "dns_sd_registry", "dial_registry", "service_discovery_client_mac",
               "chrome_browser_main_extra_parts_views",
               "media_session_impl", "media_session_service_impl",
               "file_stream_context_posix"]

    def test_checks_every_bridge_and_renderer_object(self):
        outputs = [source + ".o" for source in self.sources]
        replies = ["", "", "", "", "", "", *(output + "\n" for output in outputs)]
        with patch.object(build, "run", side_effect=replies) as run, patch.object(build, "compile_targets") as compile:
            build.check_native({"PATH": "test"})
        compile.assert_called_once_with(outputs, {"PATH": "test"})
        self.assertEqual(run.call_args_list[0].args[0][-1], "//chrome/browser/arx:arx")
        self.assertEqual(run.call_args_list[1].args[0][-1], "//components/arx_inspection:renderer")
        self.assertEqual(run.call_args_list[2].args[0][-1], "//components/arx_page_media:renderer")

    def test_every_missing_source_fails_before_compilation(self):
        for index, source in enumerate(self.sources):
            replies = ["", "", "", "", "", "", *(name + ".o\n" for name in self.sources[:index]), ""]
            with self.subTest(source=source), patch.object(build, "run", side_effect=replies), patch.object(build, "compile_targets") as compile:
                with self.assertRaisesRegex(ValueError, source):
                    build.check_native({})
                compile.assert_not_called()

    def test_low_disk_does_not_start_build(self):
        with patch.dict("os.environ", {"ENGINE_MIN_FREE_GIB": "40"}), patch.object(build.shutil, "disk_usage", return_value=SimpleNamespace(free=39 * 1024 ** 3)), patch.object(build.subprocess, "Popen") as start:
            with self.assertRaisesRegex(ValueError, "headroom"):
                build.run_guarded(["compile"], {})
        start.assert_not_called()

    def test_disk_guard_interrupts_only_its_own_build_group(self):
        process = Mock(pid=12345)
        process.wait.side_effect = [subprocess.TimeoutExpired("compile", 15), 0]
        process.poll.return_value = None
        with patch.dict("os.environ", {"ENGINE_MIN_FREE_GIB": "40"}), patch.object(build.shutil, "disk_usage", side_effect=[SimpleNamespace(free=50 * 1024 ** 3), SimpleNamespace(free=39 * 1024 ** 3)]), patch.object(build.subprocess, "Popen", return_value=process) as start, patch.object(build.os, "killpg") as kill:
            with self.assertRaisesRegex(ValueError, "preserve disk"):
                build.run_guarded(["compile"], {})
        self.assertTrue(start.call_args.kwargs["start_new_session"])
        kill.assert_called_once_with(12345, signal.SIGINT)

    def test_build_failure_is_propagated_without_killing_finished_process(self):
        process = Mock(pid=12345)
        process.wait.return_value = 2
        process.poll.return_value = 2
        with patch.object(build.shutil, "disk_usage", return_value=SimpleNamespace(free=100 * 1024 ** 3)), patch.object(build.subprocess, "Popen", return_value=process), patch.object(build.os, "killpg") as kill:
            with self.assertRaises(subprocess.CalledProcessError):
                build.run_guarded(["compile"], {})
        kill.assert_not_called()
