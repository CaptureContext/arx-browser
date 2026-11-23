"""Check that profiles load on first use and are released when idle (DEV-880).

Seeds four profiles in a fresh profile directory and shows one. Launch must load only
that one. A profile setting and a page then use two others for the first time, and both
must be released once they've gone unused for a short grace period, and Chromium must
destroy them (the app asks the engine's ArxEngineProfileIsLoaded, which watches
OnProfileWillBeDestroyed), while the shown one stays. A session cookie the page set
before its profile went is still there when it opens again. Used again, the released profile loads with the setting it saved. The fourth
profile is never used: its Chromium directory must never be created.
"""

import http.server
import os
import subprocess
import tempfile
import threading
from pathlib import Path

from . import build_app
from .core import smoke
from .engine.config import WORK

# Must match ProfileReleaseSmoke.swift.
SHOWN = "00000000-0000-4000-8000-000000000001"
SETTINGS = "00000000-0000-4000-8000-000000000002"
PAGE = "00000000-0000-4000-8000-000000000003"
UNTOUCHED = "00000000-0000-4000-8000-000000000004"
GRACE_SECONDS = 4
PHASES = ("LAUNCH", "FIRST_USE", "RELEASED", "DESTROYED", "RELOADED", "SESSION_KEPT")


class Fixture(http.server.BaseHTTPRequestHandler):
    # A session cookie (no expiry) the first time; then the title says it was kept.
    # The titles must match ProfileReleaseSmoke.swift.
    body = b"""<!doctype html><title>Arx profile release</title><script>
const kept = document.cookie.split('; ').includes('arx_session=1');
if (!kept) document.cookie = 'arx_session=1; path=/; SameSite=Lax';
document.title = kept ? 'Arx profile release: kept' : 'Arx profile release: set';
</script>"""

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(self.body)))
        self.end_headers()
        self.wfile.write(self.body)

    def log_message(self, *_):
        pass


def environment(profile, port):
    return {
        "ARX_PROFILE_RELEASE_SMOKE": "1",
        "ARX_ENGINE_PROFILE": str(profile),
        "ARX_PROFILE_RELEASE_SMOKE_URL": f"http://127.0.0.1:{port}/",
        "ARX_PROFILE_RELEASE_GRACE_SECONDS": str(GRACE_SECONDS),
    }


def verify(process, profile):
    lines = process.stdout.splitlines()
    if process.returncode != 0 or "ARX_PROFILE_RELEASE_SMOKE_SUCCESS" not in lines:
        raise ValueError("Profile release smoke failed")
    missing = [phase for phase in PHASES if f"ARX_PROFILE_RELEASE_PHASE_{phase}" not in lines]
    if missing:
        raise ValueError(f"Profile release smoke skipped {', '.join(missing)}")
    # Chromium creates a profile's directory when it first loads it.
    for key in (SETTINGS, PAGE):
        if not (profile / f"Arx-{key}").is_dir():
            raise ValueError(f"Profile {key} never loaded on first use")
    if (profile / f"Arx-{UNTOUCHED}").exists():
        raise ValueError("A profile nothing used was loaded")


def main():
    if os.environ.get("CONFIGURATION", "Debug") != "Debug":
        raise ValueError("profile-release-smoke uses the Debug development configuration")
    with smoke.log("profile-release-smoke") as log:
        app = build_app.main(log="profile-release-smoke-build.log", signed=True, require_engine=True)
        WORK.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="profile-release-", dir=WORK) as directory:
            profile = Path(directory) / "profile"
            profile.mkdir(mode=0o700)
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                env = {key: value for key, value in os.environ.items() if not key.startswith("ARX_")}
                env.update(environment(profile, server.server_port))
                process = subprocess.run([str(app / "Contents/MacOS/Arx")], env=env, capture_output=True,
                                         text=True, timeout=180)
            except subprocess.TimeoutExpired as error:
                raise ValueError(f"Profile release smoke timed out; inspect {log}") from error
            finally:
                server.shutdown()
            smoke.append(log, process.stdout, process.stderr)
            try:
                verify(process, profile)
            except ValueError as error:
                raise ValueError(f"{error}; inspect {log}") from error
        print("Launch loaded only the shown profile; two others loaded on first use and were released "
              f"after {GRACE_SECONDS} s unused, and one came back with its setting; an unused profile never loaded.")
