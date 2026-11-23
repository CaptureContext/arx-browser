"""Signed owned app acceptance through Settings; no real reboot or user storage.

With `clearing`, the same owned fixture runs the migration assistant's "Clear Arx data first"
(DEV-833) instead: three profiles are retired through it and a disposable archive is imported.
"""

import http.server
import os
import subprocess
import tempfile
import threading
from pathlib import Path

from . import build_app
from .core import profile_retirement_smoke as fixture, smoke
from .core.paths import ROOT
from .core.routing_smoke import is_owned_product
from .engine.config import WORK


def main(*, clearing=False):
    name = "migration-clear-smoke" if clearing else "profile-retirement-smoke"
    phases = fixture.CLEAR_PHASES if clearing else fixture.PHASES
    if os.environ.get("CONFIGURATION", "Debug") != "Debug":
        raise ValueError(f"{name} requires the Debug development configuration")
    with smoke.log(name) as log:
        app = build_app.main(log=f"{name}-build.log", signed=True, require_engine=True).resolve()
        if not is_owned_product(app, ROOT / "build"):
            raise ValueError("Retirement fixture requires this checkout's owned signed build")
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        WORK.mkdir(parents=True, exist_ok=True)
        root = Path(tempfile.mkdtemp(prefix="retirement-smoke-", dir=WORK)).resolve()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.split("?", 1)[0] != "/identity":
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(fixture.HTML)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(fixture.HTML)

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            fixture.prepare(root, app, server.server_port)
            smoke.append(log, f"Owned retained fixture: {root}\n")
            boot = fixture.kernel_boot_session()
            proof = None
            for phase in phases:
                if fixture.kernel_boot_session() != boot:
                    raise ValueError("Kernel boot changed; same-boot fixture proof is invalid")
                # The JSON workspace, which the checks read back: SQLite is on by default (DEV-1143).
                env = dict({key: value for key, value in os.environ.items() if not key.startswith("ARX_")},
                           ARX_ENGINE_PROFILE=str(root / "profile"), ARX_SQLITE_WORKSPACE="0",
                           ARX_RETIREMENT_SMOKE_ROOT=str(root), ARX_RETIREMENT_SMOKE_PHASE=phase)
                arguments = [str(app / "Contents/MacOS/Arx"), "--arx-retirement-smoke-root", str(root),
                             "--arx-retirement-smoke-phase", phase]
                with subprocess.Popen(arguments, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
                    try:
                        stdout, stderr = process.communicate(timeout=180)
                    except subprocess.TimeoutExpired:
                        # Only this runner's exact child. Never search for another app/helper PID.
                        process.kill()
                        stdout, stderr = process.communicate()
                        smoke.append(log, stdout, stderr)
                        raise ValueError(f"Owned retirement app timed out; retained evidence at {root}")
                    result = subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
                    smoke.append(log, stdout, stderr)
                    if fixture.kernel_boot_session() != boot:
                        raise ValueError("Kernel boot changed; cannot claim same-boot preservation")
                    if clearing:
                        fixture.verify_clear_phase(root, app, process.pid, result)
                    else:
                        proof = fixture.verify_phase(
                            root, app, phase, process.pid, result, prior=proof,
                            original=proof["original"] if proof else None,
                            quarantined=proof["quarantined"] if proof else None,
                        )
                smoke.append(log, f"ARX_RETIREMENT_{phase.upper()}_ACCEPTANCE_SUCCESS\n")
            if clearing:
                print(f"Owned clear-before-import acceptance passed. Evidence: {root}")
                return
            print(f"Owned Settings queue/quarantine/same-boot acceptance passed. Evidence: {root}")
            print("Actual later-kernel-boot verified absence still requires manual acceptance; no reboot was performed.")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
