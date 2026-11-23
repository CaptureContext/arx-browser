"""Open Chromium DevTools in the signed app against disposable loopback fixtures.

Checks developer-mode gating, the separate inspector window, its binding across
navigation and cache-bypassing reload, exact binding for a Split View pane,
Peek, Little Arx and a private window (another browsing context), a
cross-site navigation to an explicit localhost port, a WebSocket live reload,
the inspector closing when every renderer of this run is terminated and
reopening bound to the recovered page, and closing with the page.

Each inspector window title ends with the host of its inspected page, so pages
on 127.0.0.1 and on localhost tell inspectors apart without screenshots.
The frontend counts as loaded only once it has attached to its page's target
(DevTools' readyForTest), so an inspector whose panels stay empty fails the
FRONTEND_LOADED phase (DEV-785). Panel workflows (console, network, breakpoints,
Inspect Element) remain manual acceptance: the inspector exposes no protocol
endpoint to drive its frontend.
"""

import base64
import hashlib
import http.server
import os
import signal
import socket
import subprocess
import tempfile
import threading
from pathlib import Path

from . import build_app
from .core import smoke
from .core.paths import ROOT
from .engine.config import WORK

TIMEOUT = 300

PAGES = {
    "/index.html": "<!doctype html><title>Arx developer fixture</title><h1 id=target>Inspect me</h1>"
                   "<script>console.log('arx developer fixture')</script>",
    "/second.html": "<!doctype html><title>Arx developer fixture 2</title><p>Navigated</p>",
    "/pane.html": "<!doctype html><title>Arx developer pane</title><p>Split View pane</p>",
    "/peek.html": "<!doctype html><title>Arx developer peek</title><p>Peek</p>",
    "/little.html": "<!doctype html><title>Arx developer little</title><p>Little Arx</p>",
    "/private.html": "<!doctype html><title>Arx developer private</title><p>Private window</p>",
}

LIVE_PATH = "/live.html"
LIVE_SOCKET = "/live"
LIVE_TITLE = "Arx live fixture"
RELOAD = "reload"
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# Printed by DeveloperToolsSmoke in this order; each names one checked phase.
PHASES = (
    "ARX_DEVTOOLS_PHASE_GATED",
    "ARX_DEVTOOLS_PHASE_FRONTEND_LOADED",
    "ARX_DEVTOOLS_PHASE_NAVIGATED",
    "ARX_DEVTOOLS_PHASE_SPLIT_BOUND",
    "ARX_DEVTOOLS_PHASE_PEEK_BOUND",
    "ARX_DEVTOOLS_PHASE_LITTLE_BOUND",
    "ARX_DEVTOOLS_PHASE_PRIVATE_BOUND",
    "ARX_DEVTOOLS_PHASE_LOCALHOST_BOUND",
    "ARX_DEVTOOLS_PHASE_LIVE_RELOADED",
    "ARX_DEVTOOLS_PHASE_RENDERER_RECOVERED",
    "ARX_DEVTOOLS_PHASE_HEADER",
    "ARX_DEVTOOLS_SMOKE_SUCCESS",
)
LIVE_RELOAD_REQUEST = "ARX_DEVTOOLS_LIVE_RELOAD_REQUEST"
CRASH_REQUEST = "ARX_DEVTOOLS_CRASH_REQUEST"
WINDOW = "ARX_DEVTOOLS_WINDOW "


def live_page(generation):
    """Each load has its own generation; the title gains `connected` once its socket opens."""
    title = f"{LIVE_TITLE} {generation}"
    return (f"<!doctype html><title>{title}</title><p>Live reload</p><script>"
            f"const socket = new WebSocket(`ws://${{location.host}}{LIVE_SOCKET}`);"
            f"socket.onopen = () => {{ document.title = '{title} connected' }};"
            f"socket.onmessage = event => {{ if (event.data === '{RELOAD}') location.reload() }};"
            f"</script>")


def accept_key(key):
    return base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode()).digest()).decode()


def text_frame(text):
    """One final unmasked server text frame; fixture messages stay under 126 bytes."""
    payload = text.encode()
    if len(payload) > 125:
        raise ValueError("Fixture WebSocket messages must be shorter than 126 bytes")
    return bytes([0x81, len(payload)]) + payload


class LiveReload:
    """Counts live page loads and sends one reload to the first socket once requested."""

    def __init__(self):
        self._lock = threading.Lock()
        self._loads = 0
        self._connections = 0
        self._requested = threading.Event()

    def load(self):
        with self._lock:
            self._loads += 1
            return self._loads

    def connect(self):
        """True only for the first socket; later generations never reload again."""
        with self._lock:
            self._connections += 1
            return self._connections == 1

    def request(self):
        self._requested.set()

    def wait(self, timeout):
        return self._requested.wait(timeout)


class Fixture(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == LIVE_SOCKET and self.headers.get("Upgrade", "").lower() == "websocket":
            self.serve_socket()
            return
        if self.path == LIVE_PATH:
            page = live_page(self.server.live.load())
        else:
            page = PAGES.get(self.path)
        if page is None:
            self.send_error(404)
            return
        body = page.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_socket(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            self.send_error(400)
            return
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept_key(key))
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        if self.server.live.connect() and self.server.live.wait(TIMEOUT):
            self.wfile.write(text_frame(RELOAD))
            self.wfile.flush()
        # Hold the socket until the page goes away; client frames are ignored.
        self.connection.settimeout(TIMEOUT)
        try:
            while self.connection.recv(1024):
                pass
        except OSError:
            pass

    def log_message(self, *_):
        pass


class IPv6Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


def serve(server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def fixture_servers():
    """127.0.0.1 plus ::1 on the same port when available, sharing one live-reload state."""
    live = LiveReload()
    servers = [http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)]
    port = servers[0].server_port
    try:
        servers.append(IPv6Server(("::1", port), Fixture))
    except OSError:
        pass  # Chromium falls back to 127.0.0.1 for localhost when ::1 refuses.
    for server in servers:
        server.live = live
        serve(server)
    return servers, live


def environment(profile, port):
    return {
        "ARX_DEVTOOLS_SMOKE": "1",
        "ARX_ENGINE_PROFILE": str(profile),
        "ARX_ENGINE_URL": f"http://127.0.0.1:{port}/index.html",
        "ARX_DEVTOOLS_LOCAL_URL": f"http://localhost:{port}/",
    }


def renderer_children(parent, listing):
    """Renderer helpers whose parent is exactly this run's Arx process, from `ps -A -o pid=,ppid=,args=`."""
    pids = []
    for row in listing.splitlines():
        fields = row.split(maxsplit=2)
        if len(fields) == 3 and fields[1] == str(parent) and "--type=renderer" in fields[2]:
            pids.append(int(fields[0]))
    return pids


def terminate_renderers(parent):
    listing = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,args="], capture_output=True, text=True,
                             check=True).stdout
    pids = renderer_children(parent, listing)
    if not pids:
        raise ValueError("No renderer belongs to the developer tools smoke process")
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return pids


def missing_phases(output):
    """Phase markers absent or out of order, as whole lines."""
    lines = [line.rstrip("\n") for line in output]
    missing, position = [], 0
    for phase in PHASES:
        try:
            position = lines.index(phase, position) + 1
        except ValueError:
            missing.append(phase)
    return missing


def main():
    if os.environ.get("CONFIGURATION", "Debug") != "Debug":
        raise ValueError("developer-tools-smoke uses the Debug development configuration")
    with smoke.log("developer-tools-smoke") as log:
        app = build_app.main(log="developer-tools-smoke-build.log", signed=True, require_engine=True)
        WORK.mkdir(parents=True, exist_ok=True)
        servers, live = fixture_servers()
        screenshot = ROOT / "build/logs/runtime/developer-tools.png"
        try:
            with tempfile.TemporaryDirectory(prefix="devtools-smoke-", dir=WORK) as directory:
                env = dict(os.environ, **environment(Path(directory) / "profile", servers[0].server_port))
                with subprocess.Popen([str(app / "Contents/MacOS/Arx")], env=env, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True) as process:
                    watchdog = threading.Timer(TIMEOUT, process.kill)
                    watchdog.start()
                    output, errors = [], []
                    try:
                        for line in process.stdout:
                            output.append(line)
                            if line.startswith(WINDOW):
                                number = line.split()[1]
                                subprocess.run(["screencapture", "-x", "-o", "-l", number, str(screenshot)], check=False)
                            elif line.rstrip("\n") == LIVE_RELOAD_REQUEST:
                                live.request()
                            elif line.rstrip("\n") == CRASH_REQUEST:
                                try:
                                    terminate_renderers(process.pid)
                                except (OSError, ValueError, subprocess.CalledProcessError) as error:
                                    errors.append(str(error))
                        _, stderr = process.communicate(timeout=60)
                    except subprocess.TimeoutExpired as error:
                        process.kill()
                        raise ValueError(f"Developer tools smoke timed out; inspect {log}") from error
                    finally:
                        watchdog.cancel()
                smoke.append(log, "".join(output), stderr)
                missing = missing_phases(output)
                if process.returncode != 0 or missing or errors:
                    raise ValueError(f"Developer tools smoke failed (missing {missing}, errors {errors}); inspect {log}")
        finally:
            for server in servers:
                server.shutdown()
                server.server_close()
        print("Developer tools opened, stayed bound to their exact pages across navigation, panes, Peek, "
              f"Little Arx, a private window, live reload and renderer recovery, and closed with their page. "
              f"Screenshot: {screenshot}")
