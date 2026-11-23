"""Check web notifications in the signed Arx Dev (the web-notifications ticket, DEV-885).

Serves a loopback page, starts this checkout's signed Debug app (Arx Dev,
`dev.capturecontext.arx.dev`, never the installed Arx) on a fresh profile with
`ARX_NOTIFICATION_SMOKE=1`, and requires the app's `NotificationSmoke` phases:

* the page gets the notification permission through Arx's site settings, not a prompt, and its
  `new Notification(...)` reaches Notification Center: the app reads it back with
  `UNUserNotificationCenter.deliveredNotifications()` and prints title, subtitle (the site),
  body and attachment count as JSON, which this runner checks;
* from another space, the page's `window.focus()` in its `onclick` and a click the site didn't
  answer each show the site's tab in its own space and bring Arx forward;
* with the tab closed, a click on its notification opens the site again;
* a private window's page is denied the permission.

What it can't automate, and a person checks by hand:

* a real click on the Notification Center banner. That needs Accessibility control of
  Notification Center; the smoke sends the app what the engine reports for a click instead
  (`pageActivationRequested`, `notificationClicked`), so Chromium's own click dispatch to the
  page's `onclick` is not covered;
* macOS's first prompt to let Arx Dev post notifications. Until a person allows it once
  (System Settings › Notifications › Arx Dev), the smoke reports NOT RUN and exits with
  `NOT_RUN_EXIT` (77; Make reports it as `Error 77`) rather than failing or passing.

The banner appears on screen, so the coordinator runs it with the window smokes on an idle Mac.
"""

import http.server
import json
import os
import struct
import subprocess
import tempfile
import uuid
import zlib
from collections import Counter
from pathlib import Path

from . import build_app
from .core import smoke
from .core.loopback_server import LoopbackServer
from .engine.config import WORK

NOT_RUN_EXIT = 77
NOT_RUN = "ARX_NOTIFICATION_SMOKE_NOT_RUN"
DELIVERED = "ARX_NOTIFICATION_SMOKE_DELIVERED "
MARKERS = (
    "ARX_NOTIFICATION_SMOKE_PHASE_AUTHORIZED",
    "ARX_NOTIFICATION_SMOKE_PHASE_PERMISSION",
    "ARX_NOTIFICATION_SMOKE_PHASE_SHOWN",
    "ARX_NOTIFICATION_SMOKE_PHASE_ACTIVATION",
    "ARX_NOTIFICATION_SMOKE_PHASE_CLICK",
    "ARX_NOTIFICATION_SMOKE_PHASE_REOPENED",
    "ARX_NOTIFICATION_SMOKE_PHASE_PRIVATE",
    "ARX_NOTIFICATION_SMOKE_SUCCESS",
)
BODY = "Arx notification smoke body"
TIMEOUT = 180

# Titles `NotificationSmoke.PageTitle` waits for.
PAGE = """<!doctype html><title>Arx notification loading</title><p>Arx notification fixture</p>
<script>
const permission = Notification.permission;
document.title = "Arx notification fixture " + permission;
if (permission === "granted" && new URLSearchParams(location.search).has("fire")) {
  // No requireInteraction: Chromium posts it as a banner from Arx's own process.
  const notification = new Notification(%(title)s, {body: %(body)s, icon: "/icon.png"});
  notification.onshow = () => { document.title = "Arx notification shown"; };
  notification.onerror = () => { document.title = "Arx notification error"; };
  notification.onclick = () => { window.focus(); notification.close(); };
}
</script>"""
HOME = "<!doctype html><title>Arx notification fixture home</title><p>Arx notification fixture home</p>"
PRIVATE = """<!doctype html><title>Arx notification private asking</title><p>Arx notification private</p>
<script>
Notification.requestPermission().then(
  (answer) => { document.title = "Arx notification private " + answer; },
  () => { document.title = "Arx notification private error"; });
</script>"""


class NotRun(subprocess.CalledProcessError):
    """Arx Dev may not post notifications on this Mac: not a failure, and not a pass."""

    def __init__(self, detail):
        super().__init__(NOT_RUN_EXIT, "notification-smoke")
        self.detail = detail

    def __str__(self):
        return ("NOT RUN: Arx Dev is not allowed to post notifications — allow it once in "
                f"System Settings › Notifications ({self.detail})")


def icon():
    """A 32-pixel solid PNG for the notification's icon."""
    size = 32
    rows = b"".join(b"\x00" + b"\x2f\x6f\xeb" * size for _ in range(size))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows))
            + chunk(b"IEND", b""))


def page(title, body=BODY):
    # json.dumps makes JavaScript strings; "</" can't end the script early.
    return PAGE % {"title": json.dumps(title).replace("</", "<\\/"), "body": json.dumps(body).replace("</", "<\\/")}


class Fixture(http.server.BaseHTTPRequestHandler):
    title = ""
    requests = Counter()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        self.requests[path] += 1
        if path == "/page":
            self.reply(page(self.title).encode(), "text/html; charset=utf-8")
        elif path == "/":
            self.reply(HOME.encode(), "text/html; charset=utf-8")
        elif path == "/private":
            self.reply(PRIVATE.encode(), "text/html; charset=utf-8")
        elif path == "/icon.png":
            self.reply(icon(), "image/png")
        else:
            self.send_error(404)

    def reply(self, body, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def environment(profile, port, title):
    base = f"http://127.0.0.1:{port}"
    return {
        "ARX_NOTIFICATION_SMOKE": "1",
        "ARX_ENGINE_PROFILE": str(profile),
        "ARX_ENGINE_URL": f"{base}/page",
        "ARX_NOTIFICATION_SMOKE_ORIGIN": base,
        "ARX_NOTIFICATION_SMOKE_PRIVATE_URL": f"{base}/private",
        "ARX_NOTIFICATION_SMOKE_TITLE": title,
    }


def delivery(stdout):
    """The JSON the app printed for the delivered notification, or None."""
    for line in stdout.splitlines():
        if line.startswith(DELIVERED):
            return json.loads(line[len(DELIVERED):])
    return None


def verify(code, stdout, title, site):
    """Raises NotRun or ValueError; returns notes on what passed with a caveat."""
    for line in stdout.splitlines():
        if line.startswith(NOT_RUN):
            raise NotRun(line[len(NOT_RUN):].strip())
    delivered = delivery(stdout)
    if delivered is None:
        raise ValueError("Notification Center didn't list the page's notification")
    if delivered.get("title") != title or delivered.get("body") != BODY:
        raise ValueError(f"The delivered notification has the wrong title or body: {delivered}")
    if site not in delivered.get("subtitle", ""):
        raise ValueError(f"The delivered notification doesn't name the site {site}: {delivered}")
    missing = [marker for marker in MARKERS if marker not in stdout.splitlines()]
    if code != 0 or missing:
        raise ValueError(f"Arx failed the notification smoke (exit {code}, missing {', '.join(missing) or 'none'})")
    notes = []
    if not delivered.get("attachments"):
        notes.append("The delivered notification has no attachment, so its icon isn't observable from "
                     "Notification Center's records; look at the banner.")
    return notes


def main():
    if os.environ.get("CONFIGURATION", "Debug") != "Debug":
        raise ValueError("notification-smoke uses the Debug development configuration (Arx Dev)")
    with smoke.log("notification-smoke") as log:
        app = build_app.main(log="notification-smoke-build.log", signed=True, require_engine=True)
        WORK.mkdir(parents=True, exist_ok=True)
        title = f"Arx notification smoke {uuid.uuid4().hex[:8]}"
        Fixture.title = title
        Fixture.requests = Counter()
        fixture = LoopbackServer(Fixture).start()
        port = fixture.server.server_port
        try:
            with tempfile.TemporaryDirectory(prefix="notification-", dir=WORK) as directory:
                env = dict(os.environ, **environment(Path(directory) / "profile", port, title))
                process = subprocess.run([str(app / "Contents/MacOS/Arx")], env=env, capture_output=True,
                                         text=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired as error:
            raise ValueError(f"Notification smoke timed out; inspect {log}") from error
        finally:
            fixture.stop()
        smoke.append(log, process.stdout, process.stderr, f"Requests: {dict(Fixture.requests)}\n")
        try:
            notes = verify(process.returncode, process.stdout, title, f"127.0.0.1:{port}")
        except NotRun as error:
            smoke.append(log, f"{error}\n")
            print(error)
            raise
        except ValueError as error:
            raise ValueError(f"{error}; inspect {log}") from error
        for note in notes:
            print(note)
        print("A site's notification reached Notification Center with its title, body and site; a click's "
              "routes showed the site's tab from another space and reopened it once closed; a private "
              "window was denied the permission. Not automated: a real click on the banner.")
