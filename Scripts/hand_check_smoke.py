"""The hand checks owed on five merged fixes, as one window smoke in the signed Arx Dev.

`make hand-check-smoke [ARGS='--phase NAME ...']` runs every phase, or the ones named:

- `find`: ⌘F refocuses the find field and selects its text after focus went to the page, the URL
  bar or the sidebar, also in reading mode (the find refocus ticket, DEV-1222).
- `full-screen`: entering and leaving macOS full screen closes and restores the traffic lights'
  space in step, and hovering the top edge doesn't move the page (the full-screen layout ticket,
  DEV-912).
- `address`: an address wider than the expanded URL bar shows no inline suffix, and its text and
  caret scroll normally (the inline completion ticket, DEV-1223).
- `private-save`: Save Page As in a private window, through AppKit's real save panel, into a new
  folder (the private Save Page As ticket, DEV-816). Once Arx has quit, this runner checks
  `defaults read dev.capturecontext.arx.dev NSOSPLastRootDirectory` doesn't name that folder and
  `xattr -l` on each saved file has no `kMDItemWhereFroms`.
- `hide-element-toast`: with Hide Element on, over a page whose footer runs under the toast, the
  pointer over the toast outlines nothing and the toast holds still and solid; clicks on its
  padding, corners, title and the gaps between its controls hide and show nothing, and the chevron,
  an entry's eye, Undo and Done each do their own thing (the Hide Element toast clicks ticket,
  DEV-1315). It posts the mouse as a person's, so it moves the real pointer.

Arx runs on a fresh profile with `ARX_HAND_CHECK_SMOKE=<phases>` and drives its own window: real
key presses through the menu, clicks, the pointer at the top edge. It needs a logged-in session
with a screen and nobody using the Mac, so it isn't part of `make app-smoke`.
"""

import argparse
import hashlib
import http.server
import os
import plistlib
import subprocess
import tempfile
import threading
import uuid
from pathlib import Path

from . import build_app, signing
from .core import smoke
from .engine.config import WORK

PHASES = ("find", "full-screen", "address", "private-save", "hide-element-toast")
APP_KEY = "NSOSPLastRootDirectory"
WHERE_FROMS = "com.apple.metadata:kMDItemWhereFroms"
FAILED = "ARX_HAND_CHECK_SMOKE_FAILED"
SAVED = "ARX_HAND_CHECK_PRIVATE_SAVE_FILE path="
TIMEOUT_SECONDS = 300

ARTICLE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Arx hand check article</title></head><body><article>
<h1>Arx hand check article</h1><p class="byline">By the Arx smoke</p>
%s
</article></body></html>""" % "\n".join(
    f"<p>Paragraph {n}. Arx reads this article in reading mode, and Find searches it for the word Arx. "
    "It is long enough for a reader to take it for an article rather than a page of links, with "
    "sentences that go on for a while about browsers, windows, sidebars and the keyboard.</p>"
    for n in range(1, 13)
)

# Hide Element's toast check: a paragraph across the top to pick, and a footer across the bottom
# with a box in its right corner, under both of the toast's places.
HIDE = """<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Arx hide element</title>
<style>body{margin:0;font:18px system-ui}p.pick{margin:0;padding:24px;height:72px}
footer{position:fixed;left:0;right:0;bottom:0;height:160px;background:#ddd}
footer div{position:absolute;right:20px;bottom:20px;width:200px;height:60px;background:#bbb}</style></head>
<body><p class="pick">Arx hide element: pick this paragraph.</p>
<p class="pick">Arx hide element: then this one.</p>
<footer><div>Under the toast</div></footer></body></html>"""


def phase_marker(phase):
    """The line Arx prints when a phase passes; `HandCheckSmoke.Phase.successMarker`."""
    return f"ARX_HAND_CHECK_{phase.upper().replace('-', '_')}_SUCCESS"


def pdf_document():
    """A one-page PDF with a correct cross-reference table."""
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        None,
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    stream = b"BT /F1 24 Tf 72 700 Td (Arx hand check PDF) Tj ET"
    objects[3] = b"<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream)
    body = b"%PDF-1.4\n"
    offsets = []
    for number, content in enumerate(objects, start=1):
        offsets.append(len(body))
        body += b"%d 0 obj\n%s\nendobj\n" % (number, content)
    xref = len(body)
    body += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    body += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
    body += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return body


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self.reply("text/html; charset=utf-8",
                       b"<!doctype html><title>Arx hand check</title><p>Arx hand check start page</p>")
        elif path == "/article.html":
            self.reply("text/html; charset=utf-8", ARTICLE.encode())
        elif path == "/hide.html":
            self.reply("text/html; charset=utf-8", HIDE.encode())
        elif path.startswith("/address/"):
            self.reply("text/html; charset=utf-8",
                       b"<!doctype html><title>Arx long address</title><p>Arx long address</p>")
        elif path == "/document.pdf":
            self.reply("application/pdf", pdf_document())
        else:
            self.send_error(404)

    def reply(self, content_type, body):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def parse(arguments):
    parser = argparse.ArgumentParser(prog="make hand-check-smoke ARGS=")
    parser.add_argument("--phase", action="append", choices=PHASES,
                        help="a phase to run; repeat for more; every phase when left out")
    phases = parser.parse_args(list(arguments)).phase or list(PHASES)
    return [phase for phase in PHASES if phase in phases]


def environment(profile, port, phases, folder):
    return {
        "ARX_HAND_CHECK_SMOKE": ",".join(phases),
        "ARX_ENGINE_PROFILE": str(profile),
        "ARX_ENGINE_URL": f"http://127.0.0.1:{port}/index.html",
        "ARX_HAND_CHECK_PRIVATE_FOLDER": str(folder),
        "ARX_HAND_CHECK_PDF_SHA256": hashlib.sha256(pdf_document()).hexdigest(),
    }


def verify(returncode, stdout, stderr, phases):
    """Every named phase passed, and Arx quit cleanly after them."""
    failures = [line for line in stderr.splitlines() if line.startswith(FAILED)]
    if failures:
        raise ValueError(failures[0])
    missing = [phase for phase in phases if phase_marker(phase) not in stdout.splitlines()]
    if missing:
        raise ValueError(f"Arx didn't finish the phases {', '.join(missing)}")
    if returncode != 0 or "ARX_HAND_CHECK_SMOKE_SUCCESS" not in stdout.splitlines():
        raise ValueError(f"Arx exited with {returncode} after its phases")


def saved_files(stdout):
    """The files the private-save phase wrote."""
    return [Path(line[len(SAVED):]) for line in stdout.splitlines() if line.startswith(SAVED)]


def remembered_folder(exported):
    """AppKit's remembered folder, a bookmark, from `defaults export <domain> -`; None without one."""
    if not exported:
        return None
    return plistlib.loads(exported).get(APP_KEY)


def names_folder(bookmark, folder):
    """Whether a bookmark's bytes name `folder`: its path components are stored as UTF-8."""
    return bookmark is not None and Path(folder).name.encode() in bookmark


def where_froms(xattr_listing):
    """The `kMDItemWhereFroms` line of `xattr -l`, or None."""
    return next((line for line in xattr_listing.splitlines() if line.startswith(WHERE_FROMS)), None)


def check_traces(domain, folder, files, log):
    """Nothing outside the saved files says where they came from or which folder they went to."""
    read = subprocess.run(["defaults", "read", domain, APP_KEY], capture_output=True, text=True)
    smoke.append(log, f"$ defaults read {domain} {APP_KEY}\n{read.stdout}", read.stderr)
    exported = subprocess.run(["defaults", "export", domain, "-"], capture_output=True).stdout
    if names_folder(remembered_folder(exported), folder):
        raise ValueError(f"{APP_KEY} in {domain} names the private folder {folder}")
    if not files:
        raise ValueError("The private-save phase reported no saved files")
    for file in files:
        listing = subprocess.run(["xattr", "-l", str(file)], capture_output=True, text=True)
        smoke.append(log, f"$ xattr -l {file}\n{listing.stdout}", listing.stderr)
        if listing.returncode != 0:
            raise ValueError(f"xattr couldn't read {file}")
        line = where_froms(listing.stdout)
        if line:
            raise ValueError(f"{file.name} records where it came from: {line}")


def text(output):
    """A timed-out process's output, which can come back as bytes even with text=True."""
    if isinstance(output, bytes):
        return output.decode(errors="replace")
    return output or ""


def main(arguments=()):
    phases = parse(arguments)
    if os.environ.get("CONFIGURATION", "Debug") != "Debug":
        raise ValueError("hand-check-smoke uses the Debug development configuration")
    domain = signing.bundle_id("Debug")
    with smoke.log("hand-check-smoke") as log:
        app = build_app.main(log="hand-check-smoke-build.log", signed=True, require_engine=True)
        WORK.mkdir(parents=True, exist_ok=True)
        # Resolved: a worktree may link .build/engine, and AppKit reports a folder by its real path.
        with tempfile.TemporaryDirectory(prefix="hand-check-", dir=WORK.resolve()) as directory:
            root = Path(directory)
            # A new folder no save panel has seen, with a name nothing else uses.
            folder = root / f"arx-private-save-{uuid.uuid4().hex[:12]}"
            folder.mkdir()
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
            server.daemon_threads = True
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                env = dict(os.environ, **environment(root / "profile", server.server_port, phases, folder))
                process = subprocess.run([str(app / "Contents/MacOS/Arx")], env=env, capture_output=True,
                                         text=True, timeout=TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired as error:
                smoke.append(log, text(error.stdout), text(error.stderr))
                raise ValueError(f"Hand check smoke timed out; inspect {log}") from error
            finally:
                server.shutdown()
            smoke.append(log, process.stdout, process.stderr)
            verify(process.returncode, process.stdout, process.stderr, phases)
            if "private-save" in phases:
                check_traces(domain, folder, saved_files(process.stdout), log)
        print(f"Hand checks passed: {', '.join(phases)}. Log: {log}")
