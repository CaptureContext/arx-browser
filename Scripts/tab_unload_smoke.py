"""Check tab unloading (DEV-873) and live connections (DEV-879) in the signed app.

A tab opens a first loopback page and goes on to a second, so it has history. Another
tab hides it, and the engine unloads it as critical memory pressure would. The unloaded
tab must keep its address, title and back entry, look unloaded in the sidebar, load
again when it's selected, and still go back to the first page. Pages are served with
no-store, so the server sees the second page requested again by the reload.

Then a page opens a WebSocket to the fixture server and five more tabs push it out of
the five most recently used, where infinite tabs freezing would freeze it. The engine
must refuse to unload it, and past the freeze delay and an unfreeze the server must see its one
connection stay open: no close, no second connection and no report from the page that
it was frozen. `ARX_SPARE_LIVE_CONNECTIONS=off` in the environment reproduces the
disconnect the exemption prevents.

Then (DEV-1326) the tab goes forward again, is hidden and unloaded once more, and is archived
unloaded. Restored from the Tab Archive, it must show the second page with the first as its
back entry.

Last (DEV-1107), a page whose before-unload asks while its text area holds text gets a click
and a typed letter. Closing the main window must ask it while the window stays open: Stay
keeps the window and the page, and a second close with Leave closes the window and unloads
the page. This phase clicks and types into the window, so it needs the screen.
"""

import base64
import hashlib
import http.server
import os
import subprocess
import tempfile
import threading
import time
from collections import Counter
from pathlib import Path

from . import build_app
from .core import smoke
from .engine.config import WORK


PAGES = {
    "/first": "Arx unload fixture first",
    "/second": "Arx unload fixture second",
    "/other": "Arx unload fixture other",
}


LIVE_TITLE = "Arx live connection open"

ASK_TITLE = "Arx ask fixture"
ASK_TYPED_TITLE = "Arx ask fixture typed"

# A text area filling the page; once it holds text, leaving asks (DEV-1107).
ASK_PAGE = """<!doctype html><title>%s</title>
<style>html,body{margin:0;height:100%%}textarea{box-sizing:border-box;width:100%%;height:100%%}</style>
<textarea aria-label="Arx ask fixture"></textarea>
<script>
const field = document.querySelector("textarea");
field.addEventListener("input", () => { document.title = field.value ? "%s" : "%s"; });
addEventListener("beforeunload", (event) => { if (field.value) { event.preventDefault(); event.returnValue = ""; } });
</script>""" % (ASK_TITLE, ASK_TYPED_TITLE, ASK_TITLE)

# The page opens one WebSocket and never reconnects. It names its state in its title, and
# reports a freeze or a closed connection to the server once it runs again.
LIVE_PAGE = """<!doctype html><title>Arx live connection connecting</title>
<p>Arx live connection fixture</p>
<script>
const socket = new WebSocket(`ws://${location.host}/socket`);
socket.onopen = () => { document.title = "%s"; };
socket.onclose = () => { document.title = "Arx live connection closed"; fetch("/closed"); };
document.addEventListener("freeze", () => { sessionStorage.setItem("frozen", "1"); });
document.addEventListener("resume", () => { fetch("/frozen"); });
</script>""" % LIVE_TITLE

# Seconds between the server's messages; a live connection keeps receiving them.
TICK = 5
# Chromium freezes a hidden page outside the five most recent tabs 5 minutes after it was last
# visible; a frozen page notices its closed socket at its next periodic unfreeze, within a
# minute. Both, and some to spare.
LIVE_WAIT = 400


def accept_key(key):
    """RFC 6455's Sec-WebSocket-Accept for a client's Sec-WebSocket-Key."""
    digest = hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
    return base64.b64encode(digest).decode()


def text_frame(text):
    """An unmasked, final text frame shorter than 126 bytes, as a server sends it."""
    payload = text.encode()
    return bytes([0x81, len(payload)]) + payload


class Fixture(http.server.BaseHTTPRequestHandler):
    # A WebSocket upgrade must answer HTTP/1.1 101; Chromium rejects HTTP/1.0's.
    protocol_version = "HTTP/1.1"
    requests = Counter()
    # WebSocket connections opened, and those whose end the server noticed.
    sockets = Counter()
    lock = threading.Lock()

    def do_GET(self):
        if self.path == "/socket":
            self.serve_socket()
            return
        if self.path == "/ask":
            with self.lock:
                self.requests[self.path] += 1
            self.serve(ASK_PAGE)
            return
        if self.path in ("/live", "/closed", "/frozen"):
            with self.lock:
                self.requests[self.path] += 1
            self.serve("Arx live connection fixture" if self.path != "/live" else None)
            return
        # The live phase opens /other again with a query, so each is a tab of its own.
        path = self.path.split("?", 1)[0]
        title = PAGES.get(path)
        if title is None:
            self.send_error(404)
            return
        with self.lock:
            self.requests[path] += 1
        body = f"<!doctype html><title>{title}</title><p>{title}</p>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve(self, text):
        body = (LIVE_PAGE if text is None else text).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_socket(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key or self.headers.get("Upgrade", "").lower() != "websocket":
            self.send_error(400)
            return
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept_key(key))
        self.end_headers()
        self.wfile.flush()
        with self.lock:
            self.sockets["opened"] += 1
        count = 0
        try:
            while not self.server.stopping.is_set():
                count += 1
                self.wfile.write(text_frame(f"tick {count}"))
                self.wfile.flush()
                self.server.stopping.wait(TICK)
        except OSError:
            with self.lock:
                self.sockets["ended"] += 1

    def log_message(self, *_):
        pass


def server():
    """A loopback server for the three pages, counting requests per path."""
    Fixture.requests = Counter()
    Fixture.sockets = Counter()
    instance = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    instance.daemon_threads = True
    instance.stopping = threading.Event()
    threading.Thread(target=instance.serve_forever, daemon=True).start()
    return instance


def stop(instance):
    """Ends the WebSocket loops and the server."""
    instance.stopping.set()
    instance.shutdown()


def environment(profile, port):
    base = f"http://127.0.0.1:{port}"
    return {
        "ARX_TAB_UNLOAD_SMOKE": "1",
        "ARX_ENGINE_PROFILE": str(profile),
        "ARX_ENGINE_URL": f"{base}/first",
        "ARX_TAB_UNLOAD_SECOND_URL": f"{base}/second",
        "ARX_TAB_UNLOAD_OTHER_URL": f"{base}/other",
        "ARX_TAB_UNLOAD_FIRST_TITLE": PAGES["/first"],
        "ARX_TAB_UNLOAD_SECOND_TITLE": PAGES["/second"],
        "ARX_TAB_UNLOAD_LIVE_URL": f"{base}/live",
        "ARX_TAB_UNLOAD_LIVE_TITLE": LIVE_TITLE,
        "ARX_TAB_UNLOAD_LIVE_WAIT": str(LIVE_WAIT),
        "ARX_TAB_UNLOAD_ARCHIVE": "1",
        "ARX_TAB_UNLOAD_ASK_URL": f"{base}/ask",
        "ARX_TAB_UNLOAD_ASK_TITLE": ASK_TITLE,
        "ARX_TAB_UNLOAD_ASK_TYPED_TITLE": ASK_TYPED_TITLE,
    }


def reloaded(requests):
    """The unloaded second page was fetched again when it was selected."""
    return requests["/second"] >= 2


def stayed_connected(requests, sockets):
    """The live page's one WebSocket stayed open while it was out of the most recent tabs: it
    never reconnected, and the page never reported a freeze or a closed socket. (Quitting ends
    the connection without running the page's handlers, so that end isn't counted.)"""
    return sockets["opened"] == 1 and requests["/closed"] == 0 and requests["/frozen"] == 0


def main():
    if os.environ.get("CONFIGURATION", "Debug") != "Debug":
        raise ValueError("tab-unload-smoke uses the Debug development configuration")
    with smoke.log("tab-unload-smoke") as log:
        app = build_app.main(log="tab-unload-smoke-build.log", signed=True, require_engine=True)
        WORK.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="tab-unload-", dir=WORK) as directory:
            fixture = server()
            try:
                env = dict(os.environ, **environment(Path(directory) / "profile", fixture.server_port))
                process = subprocess.run([str(app / "Contents/MacOS/Arx")], env=env, capture_output=True,
                                         text=True, timeout=150 + LIVE_WAIT)
            except subprocess.TimeoutExpired as error:
                raise ValueError(f"Tab unload smoke timed out; inspect {log}") from error
            finally:
                stop(fixture)
        smoke.append(log, process.stdout, process.stderr)
        smoke.append(log, f"Requests: {dict(Fixture.requests)}; sockets: {dict(Fixture.sockets)}\n", "")
        if process.returncode != 0 or "ARX_TAB_UNLOAD_SMOKE_SUCCESS\n" not in process.stdout:
            raise ValueError(f"Tab unload smoke failed; inspect {log}")
        if "ARX_TAB_UNLOAD_PHASE_ARCHIVE_RESTORED\n" not in process.stdout:
            raise ValueError(f"The unloaded tab didn't come back from the Tab Archive with its history; inspect {log}")
        if not reloaded(Fixture.requests):
            raise ValueError(f"The unloaded tab didn't load its page again; inspect {log}")
        if not stayed_connected(Fixture.requests, Fixture.sockets):
            raise ValueError(f"The page with a WebSocket lost its connection out of the recent tabs; inspect {log}")
        print("A hidden tab unloads in place, keeps its address, title and history, looks unloaded "
              "in the sidebar, and loads again when it's selected. Archived unloaded, it comes back from the "
              "Tab Archive with its history. A page with an open WebSocket stays "
              "loaded and connected outside the five most recent tabs. Closing the window asks a page "
              "with unsaved input first: Stay keeps the window, Leave closes it and unloads the page.")
