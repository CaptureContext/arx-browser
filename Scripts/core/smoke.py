"""Retain runtime smoke diagnostics even when setup or a timed process fails.

Every run writes its own `build/logs/runtime/<name>/<UTC timestamp>.log`, so a one-off
failure isn't overwritten by the next run. `build/logs/runtime/<name>.log` is a relative
symlink to the latest run, for tooling that reads the fixed path.
"""

import os
from contextlib import contextmanager
from datetime import datetime, timezone

from .paths import ROOT


@contextmanager
def log(name):
    started = datetime.now(timezone.utc)
    destination = run_log(name, started)
    destination.write_text(f"{name} started {started.isoformat()}\n")
    link_latest(name, destination)
    print(f"Runtime log: {destination}", flush=True)
    try:
        yield destination
    except Exception as error:
        append(destination, f"\nFAILED: {error}\n")
        raise
    else:
        append(destination, "\nPASSED\n")


def run_log(name, started):
    """Returns a fresh log path for this run; never an earlier run's file."""
    directory = ROOT / "build/logs/runtime" / name
    directory.mkdir(parents=True, exist_ok=True)
    stamp = started.strftime("%Y%m%dT%H%M%S.%fZ")
    candidate = directory / f"{stamp}.log"
    suffix = 1
    while candidate.exists():
        candidate = directory / f"{stamp}-{suffix}.log"
        suffix += 1
    return candidate


def link_latest(name, destination):
    """Points `<name>.log` at this run, replacing an older link or a pre-retention file."""
    latest = destination.parent.parent / f"{name}.log"
    if latest.is_file() and not latest.is_symlink():
        modified = datetime.fromtimestamp(latest.stat().st_mtime, timezone.utc)
        os.replace(latest, run_log(name, modified))
    staging = latest.with_name(f".{name}.log.{os.getpid()}")
    staging.unlink(missing_ok=True)
    staging.symlink_to(destination.relative_to(latest.parent))
    os.replace(staging, latest)


def append(destination, *output):
    with destination.open("a") as stream:
        for value in output:
            if isinstance(value, bytes):
                value = value.decode("utf-8", errors="replace")
            stream.write(value or "")
