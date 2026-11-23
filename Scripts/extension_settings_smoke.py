"""Owned signed-app Settings intake/consent acceptance; never uses a user profile."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit
import uuid

from . import build_app
from .core import extension_install_app_fixture as fixture
from .core import smoke
from .engine.config import WORK

MARKERS = (
    "ARX_EXTENSION_SETTINGS_APP_DECLINED_REPLAY",
    "ARX_EXTENSION_SETTINGS_APP_INSTALLED_WORKER",
    "ARX_EXTENSION_SETTINGS_APP_ESCALATION_DECLINED",
    "ARX_EXTENSION_SETTINGS_APP_INVALID_PACKAGES",
    "ARX_EXTENSION_SETTINGS_APP_PROFILE_CANCELLED",
    "ARX_EXTENSION_SETTINGS_APP_NO_EXTENSIONS_PILL",
    "ARX_EXTENSION_SETTINGS_APP_SITE_MENU_POPUP",
    "ARX_EXTENSION_SETTINGS_APP_EXTENSION_WINDOW",
    "ARX_EXTENSION_SETTINGS_APP_EXTENSION_TAB",
    "ARX_EXTENSION_SETTINGS_APP_UPDATED_ISOLATED_CLEANED",
    "ARX_EXTENSION_SETTINGS_APP_UNPACKED_HIDDEN",
    "ARX_EXTENSION_SETTINGS_APP_UNPACKED_ERRORS",
    "ARX_EXTENSION_SETTINGS_APP_UNPACKED_LOADED_ISOLATED",
    "ARX_EXTENSION_SETTINGS_APP_UNPACKED_RELOADED",
    "ARX_EXTENSION_SETTINGS_APP_UNPACKED_DEVELOPER_OFF_KEPT",
    "ARX_EXTENSION_SETTINGS_APP_VERIFIED",
)
# The second process reopens the same disposable profile. The unpacked folder
# the first process left loaded must come back from its path.
RELAUNCH_MARKERS = (
    "ARX_EXTENSION_SETTINGS_APP_UNPACKED_RELAUNCH_RESTORED",
    "ARX_EXTENSION_SETTINGS_APP_UNPACKED_RELAUNCH_RELOADED",
    "ARX_EXTENSION_SETTINGS_APP_UNPACKED_REMOVED",
    "ARX_EXTENSION_SETTINGS_APP_RELAUNCH_VERIFIED",
)
RELAUNCH_ARGUMENT = "--arx-extension-settings-smoke-relaunch"
COMPLETION = "completion.json"
RELAUNCH_COMPLETION = "relaunch-completion.json"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        request = urlsplit(self.path)
        query = parse_qs(request.query, keep_blank_values=True)
        valid = request.path == "/index.html" and not request.query
        probes = ("/extension-settings-probe.html", "/extension-window-probe.html", "/extension-tab-probe.html")
        if request.path in probes and set(query) == {"run"} and len(query["run"]) == 1:
            try:
                valid = str(uuid.UUID(query["run"][0])) == query["run"][0]
            except ValueError:
                valid = False
        valid = valid and not request.scheme and not request.netloc and not request.fragment
        body = b"<!doctype html><meta charset=utf-8><title>Arx extension Settings fixture</title>" if valid else b""
        self.send_response(200 if valid else 404)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def verify(result, root, markers=MARKERS, completion_name=COMPLETION):
    output = set(result.stdout.splitlines())
    if (result.returncode or any(marker not in output for marker in markers)
            or "ARX_EXTENSION_SETTINGS_APP_FAILED" in result.stderr
            or "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN" not in result.stderr
            or "ARX_BOOTSTRAP_FRAMEWORK_VERIFIED" not in result.stderr):
        raise ValueError("Extension Settings signed-app acceptance failed; inspect its owned log")
    completion = root / completion_name
    if (not completion.is_file() or completion.is_symlink() or completion.stat().st_uid != os.getuid()
            or completion.stat().st_mode & 0o777 != 0o600 or completion.stat().st_size > 128
            or json.loads(completion.read_bytes()) != {"status": "cleanExit"}):
        raise ValueError("Extension Settings app did not exit cleanly")


def launch(arguments, environment, log):
    with subprocess.Popen(arguments, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(timeout=150)
        except subprocess.TimeoutExpired as error:
            # This group belongs exclusively to the app started above.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                stdout, stderr = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                stdout, stderr = process.communicate()
            smoke.append(log, stdout, stderr)
            raise ValueError("Owned Extension Settings app timed out") from error
        result = subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
    smoke.append(log, stdout, stderr)
    return result


def run(log):
    if os.environ.get("CONFIGURATION", "Debug") != "Debug":
        raise ValueError("Extension Settings app fixture requires Debug")
    app = build_app.main(log="extension-settings-smoke-build.log", signed=True, require_engine=True).resolve()
    WORK.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="app-extension-install-smoke-", dir=WORK.resolve()) as temp:
        root = Path(temp)
        configuration = {"version": 1, "application": app.as_uri(), **fixture.prepare(root)}
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base_url = f"http://127.0.0.1:{server.server_port}/index.html"
            configuration["baseURL"] = base_url
            fixture._exclusive(root / "fixture.json", json.dumps(configuration).encode())
            environment = {key: value for key, value in os.environ.items() if not key.startswith("ARX_")}
            # The relaunch checks for the JSON workspace: SQLite is on by default (DEV-1143).
            environment.update(ARX_EXTENSION_SETTINGS_SMOKE_ROOT=str(root),
                               ARX_ENGINE_PROFILE=str(root / "profile"), ARX_ENGINE_URL=base_url,
                               ARX_SQLITE_WORKSPACE="0")
            arguments = [str(app / "Contents/MacOS/Arx"), "--arx-extension-settings-smoke-root", str(root)]
            verify(launch(arguments, environment, log), root)
            # Same root, profile and loopback server; only the phase argument differs.
            verify(launch(arguments + [RELAUNCH_ARGUMENT], environment, log), root,
                   RELAUNCH_MARKERS, RELAUNCH_COMPLETION)
        finally:
            fixture.restore_permissions(root)
            server.shutdown()
            server.server_close()
            thread.join()


def main():
    with smoke.log("extension-settings-smoke") as log:
        run(log)
