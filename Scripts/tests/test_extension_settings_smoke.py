"""Owned-runner guards and HTTP oracle; no application or real process is launched."""
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest import mock

from Scripts import extension_settings_smoke as smoke


class ExtensionSettingsSmokeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = "\n".join(smoke.MARKERS) + "\n"
        self.error = "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN\nARX_BOOTSTRAP_FRAMEWORK_VERIFIED\n"
        self.completion = self.root / "completion.json"
        self.completion.write_text(json.dumps({"status": "cleanExit"}))
        self.completion.chmod(0o600)

    def result(self, **changes):
        values = {"returncode": 0, "stdout": self.output, "stderr": self.error}
        values.update(changes)
        return subprocess.CompletedProcess([], **values)

    def test_every_exact_phase_and_runtime_marker_is_required(self):
        smoke.verify(self.result(), self.root)
        for marker in smoke.MARKERS:
            for replacement in ("", marker + "_not_complete"):
                with self.subTest(marker=marker, replacement=replacement), self.assertRaises(ValueError):
                    smoke.verify(self.result(stdout=self.output.replace(marker, replacement)), self.root)
        for changed in (self.result(returncode=1), self.result(stderr=self.error + "ARX_EXTENSION_SETTINGS_APP_FAILED:worker"),
                        self.result(stderr=self.error.replace("ARX_ENGINE_SMOKE_MOCK_KEYCHAIN", "")),
                        self.result(stderr=self.error.replace("ARX_BOOTSTRAP_FRAMEWORK_VERIFIED", ""))):
            with self.assertRaises(ValueError):
                smoke.verify(changed, self.root)

    def test_relaunch_requires_its_own_markers_and_completion_record(self):
        relaunch = "\n".join(smoke.RELAUNCH_MARKERS) + "\n"
        record = self.root / smoke.RELAUNCH_COMPLETION
        with self.assertRaises(ValueError):
            smoke.verify(self.result(stdout=relaunch), self.root, smoke.RELAUNCH_MARKERS, smoke.RELAUNCH_COMPLETION)
        record.write_text(json.dumps({"status": "cleanExit"}))
        record.chmod(0o600)
        smoke.verify(self.result(stdout=relaunch), self.root, smoke.RELAUNCH_MARKERS, smoke.RELAUNCH_COMPLETION)
        with self.assertRaises(ValueError):
            smoke.verify(self.result(), self.root, smoke.RELAUNCH_MARKERS, smoke.RELAUNCH_COMPLETION)
        for marker in smoke.RELAUNCH_MARKERS:
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                smoke.verify(self.result(stdout=relaunch.replace(marker, "")), self.root,
                             smoke.RELAUNCH_MARKERS, smoke.RELAUNCH_COMPLETION)
        # Removal now happens after the relaunch, never in the first process.
        self.assertNotIn("ARX_EXTENSION_SETTINGS_APP_UNPACKED_REMOVED", smoke.MARKERS)
        self.assertFalse(set(smoke.MARKERS) & set(smoke.RELAUNCH_MARKERS))

    def test_clean_exit_requires_owned_regular_private_bounded_exact_record(self):
        for data in (b"{}", b'{"status":"pending"}', b" " * 129):
            self.completion.write_bytes(data)
            with self.assertRaises(ValueError):
                smoke.verify(self.result(), self.root)
        self.completion.write_text('{"status":"cleanExit"}')
        self.completion.chmod(0o644)
        with self.assertRaises(ValueError):
            smoke.verify(self.result(), self.root)
        self.completion.unlink()
        with self.assertRaises(ValueError):
            smoke.verify(self.result(), self.root)
        target = self.root / "foreign.json"
        target.write_text('{"status":"cleanExit"}')
        target.chmod(0o600)
        self.completion.symlink_to(target)
        with self.assertRaises(ValueError):
            smoke.verify(self.result(), self.root)

    def test_http_handler_serves_only_fixed_pages_and_never_private_files(self):
        class Socket:
            def __init__(self, path):
                self.request = io.BytesIO(f"GET {path} HTTP/1.0\r\n\r\n".encode())
                self.output = bytearray()

            def makefile(self, *_):
                return self.request

            def sendall(self, data):
                self.output.extend(data)

        for path, status in (
            ("/index.html", 200),
            ("/extension-settings-probe.html?run=00000000-0000-0000-0000-000000000001", 200),
            ("/extension-settings-probe.html?run=not-a-uuid", 404),
            ("/extension-settings-probe.html?run=00000000-0000-0000-0000-000000000001&run=2", 404),
            ("/extension-settings-probe.html?run=00000000-0000-0000-0000-000000000001&foreign=1", 404),
            ("/extension-window-probe.html?run=00000000-0000-0000-0000-000000000001", 200),
            ("/extension-window-probe.html?run=not-a-uuid", 404),
            ("/extension-window-probe.html", 404),
            ("/extension-tab-probe.html?run=00000000-0000-0000-0000-000000000001", 200),
            ("/extension-tab-probe.html?run=not-a-uuid", 404),
            ("/fixture-key.pem", 404), ("/profile/arx-workspace.json", 404),
            ("/../fixture-key.pem", 404), ("/index.html?foreign=1", 404),
            ("http://capturecontext.dev/index.html", 404), ("/index.html#foreign", 404),
        ):
            with self.subTest(path=path):
                connection = Socket(path)
                smoke.Handler(connection, ("127.0.0.1", 123), object())
                self.assertTrue(connection.output.startswith(f"HTTP/1.0 {status} ".encode()))
                self.assertIn(b"Cache-Control: no-store", connection.output)
                if status == 404:
                    self.assertTrue(connection.output.endswith(b"\r\n\r\n"))

    @mock.patch.dict(os.environ, {"CONFIGURATION": "Release"})
    def test_release_run_refuses_before_build_or_launch(self):
        with mock.patch.object(smoke.build_app, "main") as build:
            with self.assertRaisesRegex(ValueError, "Debug"):
                smoke.run("unused")
            build.assert_not_called()

    @mock.patch.dict(os.environ, {"CONFIGURATION": "Debug", "ARX_FOREIGN_SECRET": "unused"})
    def test_timeout_targets_only_the_explicitly_started_owned_process_group(self):
        process = mock.MagicMock()
        process.pid = 424242
        process.__enter__.return_value = process
        process.communicate.side_effect = [subprocess.TimeoutExpired([], 150),
                                          subprocess.TimeoutExpired([], 5), ("bounded", "failure")]
        server = mock.MagicMock(server_port=48123)
        with mock.patch.object(smoke, "WORK", self.root), \
                mock.patch.object(smoke.build_app, "main", return_value=self.root / "Arx.app"), \
                mock.patch.object(smoke.fixture, "prepare", return_value={"extensionID": "a" * 32, "packages": {}}), \
                mock.patch.object(smoke.http.server, "ThreadingHTTPServer", return_value=server), \
                mock.patch.object(smoke.subprocess, "Popen", return_value=process) as launch, \
                mock.patch.object(smoke.os, "killpg") as terminate, mock.patch.object(smoke.smoke, "append"):
            with self.assertRaisesRegex(ValueError, "timed out"):
                smoke.run("unused")
        self.assertEqual(terminate.call_args_list, [mock.call(424242, signal.SIGTERM), mock.call(424242, signal.SIGKILL)])
        options = launch.call_args.kwargs
        self.assertTrue(options["start_new_session"])
        self.assertNotIn("ARX_FOREIGN_SECRET", options["env"])
        self.assertEqual(set(key for key in options["env"] if key.startswith("ARX_")),
                         {"ARX_EXTENSION_SETTINGS_SMOKE_ROOT", "ARX_ENGINE_PROFILE", "ARX_ENGINE_URL",
                          "ARX_SQLITE_WORKSPACE"})
        self.assertEqual(options["env"]["ARX_SQLITE_WORKSPACE"], "0")
        server.shutdown.assert_called_once()
        server.server_close.assert_called_once()

    @mock.patch.dict(os.environ, {"CONFIGURATION": "Debug"})
    def test_relaunch_reuses_the_same_root_profile_and_server_after_a_verified_first_run(self):
        server = mock.MagicMock(server_port=48123)
        first = subprocess.CompletedProcess([], 0, "first", "")
        second = subprocess.CompletedProcess([], 0, "second", "")
        with mock.patch.object(smoke, "WORK", self.root), \
                mock.patch.object(smoke.build_app, "main", return_value=self.root / "Arx.app"), \
                mock.patch.object(smoke.fixture, "prepare", return_value={"extensionID": "a" * 32, "packages": {}}), \
                mock.patch.object(smoke.http.server, "ThreadingHTTPServer", return_value=server), \
                mock.patch.object(smoke, "launch", side_effect=[first, second]) as launch, \
                mock.patch.object(smoke, "verify") as verify:
            smoke.run("unused")
        (initial_arguments, initial_environment, _), (relaunch_arguments, relaunch_environment, _) = (
            call.args for call in launch.call_args_list)
        self.assertEqual(relaunch_arguments, initial_arguments + [smoke.RELAUNCH_ARGUMENT])
        self.assertNotIn(smoke.RELAUNCH_ARGUMENT, initial_arguments)
        self.assertEqual(relaunch_environment, initial_environment)
        root = Path(initial_environment["ARX_EXTENSION_SETTINGS_SMOKE_ROOT"])
        self.assertEqual(initial_environment["ARX_ENGINE_PROFILE"], str(root / "profile"))
        self.assertEqual(verify.call_args_list, [
            mock.call(first, root),
            mock.call(second, root, smoke.RELAUNCH_MARKERS, smoke.RELAUNCH_COMPLETION),
        ])
        server.shutdown.assert_called_once()

    @mock.patch.dict(os.environ, {"CONFIGURATION": "Debug"})
    def test_failed_first_run_never_relaunches(self):
        server = mock.MagicMock(server_port=48123)
        with mock.patch.object(smoke, "WORK", self.root), \
                mock.patch.object(smoke.build_app, "main", return_value=self.root / "Arx.app"), \
                mock.patch.object(smoke.fixture, "prepare", return_value={"extensionID": "a" * 32, "packages": {}}), \
                mock.patch.object(smoke.http.server, "ThreadingHTTPServer", return_value=server), \
                mock.patch.object(smoke, "launch", return_value=self.result(returncode=1)) as launch, \
                mock.patch.object(smoke.fixture, "restore_permissions") as restore:
            with self.assertRaises(ValueError):
                smoke.run("unused")
        launch.assert_called_once()
        restore.assert_called_once()
        server.shutdown.assert_called_once()
