"""Launch two fresh signed Arx instances through LaunchServices, never by bundle ID."""

import http.server
import os
import subprocess
import tempfile
import threading
from pathlib import Path

from . import build_app
from .core import routing_smoke, smoke
from .core.paths import ROOT
from .core.process import run
from .engine.config import WORK


def main():
    if os.environ.get("CONFIGURATION", "Debug") != "Debug":
        raise ValueError("routing-smoke requires the Debug development configuration")
    with smoke.log("routing-smoke") as log:
        WORK.mkdir(parents=True, exist_ok=True)
        launcher = WORK / "routing-launcher"
        run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
             str(ROOT / "Scripts/fixtures/RoutingLauncher.swift"), "-o", str(launcher)],
            log="routing-launcher-build.log")
        # Refuse to rebuild a bundle currently running from this checkout.
        run([str(launcher), "--preflight", str(ROOT / "build")])
        app = build_app.main(log="routing-smoke-build.log", signed=True, require_engine=True).resolve()
        if not routing_smoke.is_owned_product(app, ROOT / "build"):
            raise ValueError("Routing fixture requires this checkout's own build product")

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                routing_smoke.serve(self)

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for mode in routing_smoke.MODES:
                # Retain evidence, even on failure. Nothing refers to user profile storage.
                root = Path(tempfile.mkdtemp(prefix="routing-smoke-", dir=WORK)).resolve()
                configuration = routing_smoke.prepare(root, app, mode, server.server_port)
                with log.open("a") as output:
                    output.write(f"Fixture {mode}: {root}\n")
                try:
                    result = subprocess.run([str(launcher), str(root)], capture_output=True, text=True, timeout=100)
                except subprocess.TimeoutExpired as error:
                    # subprocess kills only our launcher. Never guess an app PID if LS did not return it.
                    smoke.append(log, error.stdout, error.stderr, "Launcher timed out; inspect retained fixture ownership.\n")
                    raise ValueError(f"Routing launcher deadline exceeded; inspect {root}") from error
                with log.open("a") as output:
                    output.write(result.stdout + result.stderr)
                routing_smoke.verify(root, app, mode, configuration["urls"], result)
                marker = f"ARX_EXTERNAL_ROUTING_{mode.upper()}_SMOKE_SUCCESS"
                with log.open("a") as output:
                    output.write(marker + "\n")
                print(marker, flush=True)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
