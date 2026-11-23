"""Prepare and verify the disposable profile used by the real download smoke."""

import hashlib
import json
import sqlite3
import subprocess
import uuid
from pathlib import Path

from . import download_fixture, smoke


def prepare(root, profile):
    root, profile = Path(root).resolve(), Path(profile).resolve()
    directory = root / "downloads"
    directory.mkdir(parents=True, exist_ok=True)
    # Retirement-enabled runs parent private contexts to Arx-Bootstrap. Seed both
    # disposable parents so ordinary and private transfers stay inside this root.
    pending = []
    for parent in ("Default", "Arx-Bootstrap"):
        preferences = profile / parent / "Preferences"
        data = json.loads(preferences.read_text()) if preferences.exists() else {}
        download = data.setdefault("download", {})
        download.update(default_directory=str(directory), prompt_for_download=False, directory_upgrade=True)
        pending.append((preferences, json.dumps(data)))
    for preferences, contents in pending:
        preferences.parent.mkdir(parents=True, exist_ok=True)
        preferences.write_text(contents)
    return {
        "ARX_DOWNLOAD_SMOKE_DIRECTORY": str(directory),
        "ARX_DOWNLOAD_SMOKE_SHA256": download_fixture.PAYLOAD_SHA256,
        "ARX_DOWNLOAD_SMOKE_BYTES": str(len(download_fixture.PAYLOAD)),
        "ARX_DOWNLOAD_SMOKE_SLOW_SHA256": hashlib.sha256(b"x" * download_fixture.SLOW_BYTES).hexdigest(),
        "ARX_DOWNLOAD_SMOKE_SLOW_BYTES": str(download_fixture.SLOW_BYTES),
        "ARX_DOWNLOAD_SMOKE_PRIVATE_MARKER": "arx-private-download-" + uuid.uuid4().hex,
    }


def verify(profile, environment):
    """Run after the disposable app exits, including Chromium's download history."""
    profile = Path(profile).resolve()
    marker = environment["ARX_DOWNLOAD_SMOKE_PRIVATE_MARKER"]
    metadata = json.loads((profile / "arx-downloads.json").read_text())
    if marker in json.dumps(metadata) or any(record["isPrivate"] for record in metadata["records"]):
        raise ValueError("Private download was written to ordinary queue metadata")
    histories = list(profile.glob("*/History"))
    if not histories:
        raise ValueError("Download smoke produced no native profile history to verify")
    found_ordinary_download = False
    for history in histories:
        with sqlite3.connect(history.as_uri() + "?mode=ro", uri=True) as database:
            tables = {row[0] for row in database.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if "downloads_url_chains" not in tables:
                continue
            found_ordinary_download |= database.execute(
                "SELECT 1 FROM downloads_url_chains WHERE instr(url, '/downloads/complete?smoke=') > 0 LIMIT 1"
            ).fetchone() is not None
            if database.execute("SELECT 1 FROM downloads_url_chains WHERE instr(url, ?) > 0 LIMIT 1", (marker,)).fetchone():
                raise ValueError("Private download URL was written to native profile history")
    if not found_ordinary_download:
        raise ValueError("Native download history did not contain the ordinary fixture; privacy verification is incomplete")


PAUSED_MARKER = "ARX_DOWNLOAD_RESUME_SMOKE_PAUSED"
RESUMED_MARKER = "ARX_DOWNLOAD_RESUME_SMOKE_SUCCESS"


def verify_resume(paused, resumed, ranges):
    """DEV-892: the first launch paused, the second resumed from the bytes it kept."""
    if paused.returncode or PAUSED_MARKER not in paused.stdout.splitlines():
        raise ValueError("Download resume smoke did not pause before quitting")
    if resumed.returncode or RESUMED_MARKER not in resumed.stdout.splitlines():
        raise ValueError("Download resume smoke did not finish the resumed download")
    if not any(start > 0 for start in ranges):
        raise ValueError("Resumed download started over instead of asking for the rest")


# Arx's quit leaves the paused download interrupted and resumable, with or without a window, and
# never shows Chromium's quit-with-downloads alert (DEV-966). An engine built without that overlay
# still asks; the pause launch answers so it can't hang, prints this, and the smoke fails.
QUIT_ALERT_MARKER = "ARX_DOWNLOAD_RESUME_QUIT_ALERT exit"
QUIT_ALERT_FAILURE = ("Chromium's quit-with-downloads alert showed when Arx quit: the engine lacks "
                      "DEV-966's overlay; rebuild it with make engine-build")


def answered_quit_alert(paused):
    """Whether the pause launch had to answer Chromium's quit-with-downloads alert."""
    return QUIT_ALERT_MARKER in paused.stderr.splitlines()


def restart(app, environment, server, log):
    """Run only after the first signed process exits successfully; never rebuild or adopt another host."""
    server.download_ranges = []
    results = []
    for phase in ("pause", "resume"):
        if phase == "resume" and answered_quit_alert(results[0]):
            raise ValueError(QUIT_ALERT_FAILURE)
        # The engine says on stderr what each quit kept and each launch loaded (DEV-966).
        env = dict(environment, ARX_DOWNLOAD_RESUME_SMOKE=phase, ARX_DOWNLOAD_DIAGNOSTICS="1")
        env.pop("ARX_ENGINE_SMOKE_CRASH_REQUEST", None)
        with subprocess.Popen(
            [str(app / "Contents/MacOS/Arx")], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        ) as process:
            try:
                stdout, stderr = process.communicate(timeout=120)
            except subprocess.TimeoutExpired as error:
                process.kill()
                stdout, stderr = process.communicate()
                smoke.append(log, stdout, stderr)
                raise ValueError(f"Download resume smoke timed out in its {phase} launch") from error
            result = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
        smoke.append(log, result.stdout, result.stderr,
                     f"ARX_DOWNLOAD_RESUME_EXIT phase={phase} code={result.returncode}\n")
        results.append(result)
    verify_resume(results[0], results[1], server.download_ranges)
