"""make cloudkit-probe: build the signed Debug app (the probe is compiled only in Debug) and check that it reaches its iCloud container."""

import argparse
import plistlib
import re
import subprocess
from pathlib import Path

from . import build_app
from .core.process import run


PROBE_ARGUMENT = "--arx-cloudkit-probe"
MARKER = re.compile(r"^ARX_CLOUDKIT_PROBE container=(\S+) result=(\S+)(?: status=(\S+))?", re.M)
CONTAINER = "iCloud.dev.capturecontext.arx"
TIMEOUT = 60


def parse(output):
    """The probe's verdict from the app's output: (status, None) on success, (None, problem) otherwise."""
    match = MARKER.search(output)
    if not match:
        return None, "the app printed no ARX_CLOUDKIT_PROBE line"
    container, result, status = match.groups()
    if container != CONTAINER:
        return None, f"the app probed {container}, not {CONTAINER}"
    if result != "returned" or not status:
        line = output[match.start():].splitlines()[0]
        return None, f"CloudKit did not answer: {line}"
    return status, None


def entitlements(app):
    output = subprocess.run(
        ["codesign", "--display", "--entitlements", "-", "--xml", str(app)],
        capture_output=True, check=True,
    ).stdout
    return plistlib.loads(output) if output.strip() else {}


def probe(app):
    app = Path(app)
    if not (app / "Contents/embedded.provisionprofile").is_file():
        raise ValueError(f"{app} has no embedded provisioning profile")
    signed = entitlements(app)
    containers = signed.get("com.apple.developer.icloud-container-identifiers", [])
    if CONTAINER not in containers:
        raise ValueError(f"{app.name} is not signed with the {CONTAINER} entitlement")
    print(
        "Entitlements: iCloud container environment "
        f"{signed.get('com.apple.developer.icloud-container-environment')}, "
        f"push {signed.get('com.apple.developer.aps-environment')}",
        flush=True,
    )
    executable = app / "Contents/MacOS/Arx"
    print(f"+ {executable} {PROBE_ARGUMENT}", flush=True)
    try:
        result = subprocess.run(
            [str(executable), PROBE_ARGUMENT],
            capture_output=True, text=True, timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired as error:
        raise ValueError(f"The CloudKit probe did not finish within {TIMEOUT} seconds") from error
    output = result.stdout + result.stderr
    status, problem = parse(output)
    if problem:
        # A missing or rejected profile kills the process before it prints anything.
        raise ValueError(f"CloudKit probe failed (exit {result.returncode}): {problem}")
    print(f"CloudKit account status for {CONTAINER}: {status}", flush=True)
    return status


def main(arguments=()):
    options = argparse.ArgumentParser(prog="make cloudkit-probe")
    options.add_argument("--app", type=Path, help="probe this signed Debug app instead of building one")
    options = options.parse_args(list(arguments))
    app = options.app.resolve() if options.app else build_app.main(log="cloudkit-probe-build.log", signed=True, require_profile=True, configuration="Debug")
    run(["codesign", "--verify", "--strict", str(app)])
    probe(app)
