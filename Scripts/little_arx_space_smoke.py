"""Check that Little Arx opens on the macOS desktop Space where a link was clicked (DEV-931).

Starts the signed Debug app on a fresh profile with `ARX_LITTLE_ARX_SPACE_SMOKE=1`, then an
AppKit fixture app that sends two loopback links through LaunchServices, as Slack or Mail would:
one from the desktop Space with Arx's main window, one from the fixture's own full-screen Space.
Both Arx and the fixture check that each link opened a new Little Arx on its own Space and that
the second link didn't switch Spaces. It needs a logged-in session with a screen and nobody using
the Mac, so it isn't part of `make app-smoke`.
"""

import http.server
import os
import subprocess
import tempfile
import threading
from pathlib import Path

from . import build_app
from .core import smoke
from .core.paths import ROOT
from .core.process import run
from .engine.config import WORK

READY = "ARX_LITTLE_ARX_SPACE_SMOKE_READY"
ARX_MARKERS = ("ARX_LITTLE_ARX_SPACE_PHASE_DESKTOP", "ARX_LITTLE_ARX_SPACE_PHASE_FULL_SCREEN",
               "ARX_LITTLE_ARX_SPACE_SMOKE_SUCCESS")
FIXTURE_MARKER = "ARX_SPACE_LINK_FIXTURE_SUCCESS"


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"<!doctype html><title>Space link {self.path}</title><p>Little Arx Space fixture</p>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def verify(arx_code, arx_stdout, fixture_code, fixture_stdout):
    """Both sides must pass: Arx sees its panels' Spaces, the fixture sees what's on screen."""
    if fixture_code != 0 or FIXTURE_MARKER not in fixture_stdout:
        raise ValueError("The fixture app saw Little Arx on the wrong Space or a Space switch")
    if arx_code != 0 or any(marker not in arx_stdout for marker in ARX_MARKERS):
        raise ValueError("Arx saw Little Arx on the wrong Space, a reused window or a Space switch")


def main():
    if os.environ.get("CONFIGURATION", "Debug") != "Debug":
        raise ValueError("little-arx-space-smoke uses the Debug development configuration")
    with smoke.log("little-arx-space-smoke") as log:
        WORK.mkdir(parents=True, exist_ok=True)
        fixture = WORK / "space-link-fixture"
        run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
             str(ROOT / "Scripts/fixtures/SpaceLinkFixture.swift"), "-o", str(fixture)],
            log="space-link-fixture-build.log")
        app = build_app.main(log="little-arx-space-smoke-build.log", signed=True, require_engine=True).resolve()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            with tempfile.TemporaryDirectory(prefix="little-arx-space-", dir=WORK) as directory:
                arx_code, arx_stdout, arx_stderr, result = exercise(app, fixture, Path(directory), base)
        finally:
            server.shutdown()
        smoke.append(log, arx_stdout, arx_stderr, result.stdout if result else "", result.stderr if result else "")
        if result is None:
            raise ValueError(f"Arx did not get ready, or the fixture app timed out; inspect {log}")
        verify(arx_code, arx_stdout, result.returncode, result.stdout)
        print("Little Arx opened on the Space of each link, and a link from a full-screen app didn't switch Spaces.")


def exercise(app, fixture, directory, base):
    done = directory / "fixture-done"
    environment = dict(os.environ, ARX_LITTLE_ARX_SPACE_SMOKE="1", ARX_ENGINE_PROFILE=str(directory / "profile"),
                       ARX_LITTLE_ARX_SPACE_SMOKE_DONE=str(done))
    arx = subprocess.Popen([str(app / "Contents/MacOS/Arx")], env=environment, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    lines, errors, ready = [], [], threading.Event()

    def read_stdout():
        for line in arx.stdout:
            lines.append(line)
            if line.strip() == READY:
                ready.set()

    readers = [threading.Thread(target=read_stdout, daemon=True),
               threading.Thread(target=lambda: errors.extend(arx.stderr), daemon=True)]
    for reader in readers:
        reader.start()
    result, code = None, None
    try:
        if ready.wait(timeout=180):
            result = subprocess.run([str(fixture), str(app), str(arx.pid), f"{base}/space/1", f"{base}/space/2",
                                     str(done)],
                                    capture_output=True, text=True, timeout=240)
            code = arx.wait(timeout=90)
    except subprocess.TimeoutExpired:
        pass
    finally:
        if code is None:
            arx.terminate()
            try:
                code = arx.wait(timeout=30)
            except subprocess.TimeoutExpired:
                arx.kill()
                code = arx.wait()
        for reader in readers:
            reader.join(timeout=5)
    if not ready.is_set():
        errors.append("Arx did not get ready for the Space links\n")
    return code, "".join(lines), "".join(errors), result
