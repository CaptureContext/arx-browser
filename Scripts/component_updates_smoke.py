"""Check that a fresh profile fetches a CRLSet newer than the build (DEV-874).

Runs the signed app headless on an isolated profile (fresh, deleted at exit, with the
mock Keychain), with network access, until the
component updater has installed the CRLSet, PKI metadata and certificate error help
(its first check runs a minute after launch). A fresh profile ships with none of them,
so each one found was downloaded by this run. The CRLSet must parse, and its NotAfter
must be later than the engine build. No other component may be installed or even named
in an update check (the profile's `updateclientdata`).

Needs the internet and reaches update.googleapis.com and Google's download hosts.
The user's own profile is never touched.
"""

import json
import signal
import struct
import time
from pathlib import Path

from . import build_app
from .core import smoke
from .engine.config import WORK
from .headless_smoke import Run

CRL_SET = "hfnkpimlhhgieaddgfemjhofmfblmnib"
PKI_METADATA = "efniojlnjndmcbiieegkicadnoecjjef"
SSL_ERROR_ASSISTANT = "giekcmmlnklenlaomppkphknjmnnpneh"
# Install directory and the file each component must hold, matching
# Packages/engine/Native/component_updates.h and BrowserSecurityComponent.Kind.
COMPONENTS = {
    CRL_SET: ("CertificateRevocation", "crl-set"),
    PKI_METADATA: ("PKIMetadata", "manifest.json"),
    SSL_ERROR_ASSISTANT: ("SSLErrorAssistant", "manifest.json"),
}
DEADLINE = 300


def is_version(name):
    parts = name.split(".")
    return all(part.isdigit() for part in parts)


def newest_version(directory):
    """The newest installed version directory (one with a manifest), or None."""
    if not directory.is_dir():
        return None
    versions = [path for path in directory.iterdir()
                if path.is_dir() and is_version(path.name) and (path / "manifest.json").is_file()]
    return max(versions, key=lambda path: [int(part) for part in path.name.split(".")], default=None)


def crl_set_header(path):
    """The JSON header of a CRLSet file: uint16le length, then that many bytes of JSON."""
    data = path.read_bytes()
    if len(data) < 2:
        raise ValueError(f"{path} is too short to be a CRLSet")
    (length,) = struct.unpack("<H", data[:2])
    if len(data) < 2 + length:
        raise ValueError(f"{path} ends inside its header")
    header = json.loads(data[2:2 + length])
    if header.get("ContentType") != "CRLSet" or not isinstance(header.get("Sequence"), int):
        raise ValueError(f"{path} isn't a CRLSet: {header.get('ContentType')!r}")
    return header


def installed(profile):
    """{component id: its newest version directory} for every Arx component present."""
    found = {}
    for component, (directory, required) in COMPONENTS.items():
        version = newest_version(profile / directory)
        if version and (version / required).is_file():
            found[component] = version
    return found


def unexpected_components(profile):
    """Top-level directories that hold a component version Arx doesn't update."""
    ours = {directory for directory, _ in COMPONENTS.values()}
    return sorted(path.name for path in profile.iterdir()
                  if path.is_dir() and path.name not in ours and newest_version(path))


def checked_components(profile):
    """Component IDs the updater has persisted data for: every one it asked about."""
    state = profile / "Local State"
    if not state.is_file():
        return set()
    return set(json.loads(state.read_text()).get("updateclientdata", {}).get("apps", {}))


def problems(profile, build_time):
    """Why this profile doesn't show a working security-only updater; empty when it does."""
    found = installed(profile)
    issues = [f"{COMPONENTS[component][0]} was not downloaded"
              for component in COMPONENTS if component not in found]
    if CRL_SET in found:
        header = crl_set_header(found[CRL_SET] / "crl-set")
        not_after = header.get("NotAfter")
        if not_after is not None and not_after <= build_time:
            issues.append(f"the CRLSet (sequence {header['Sequence']}) expired before the engine was built")
    extra = unexpected_components(profile)
    if extra:
        issues.append("other components were installed: " + ", ".join(extra))
    named = checked_components(profile) - set(COMPONENTS)
    if named:
        issues.append("update checks named other components: " + ", ".join(sorted(named)))
    return issues


def engine_build_time(app):
    framework = app / "Contents/Frameworks/Arx Framework.framework/Arx Framework"
    return framework.resolve().stat().st_mtime


def main():
    with smoke.log("component-updates-smoke") as log:
        WORK.mkdir(parents=True, exist_ok=True)
        app = build_app.main(log="component-updates-smoke-build.log", signed=True, require_engine=True).resolve()
        build_time = engine_build_time(app)
        with log.open("a") as output:
            # An isolated run: a fresh profile Arx deletes at exit, and Chromium's mock
            # Keychain, so the person's real "Arx Storage Key" is never read or created.
            run = Run(app, output, "--timeout", str(DEADLINE + 120))
            try:
                ready = run.wait_for("ready")
                if ready.get("profile", {}).get("mode") != "isolated":
                    raise ValueError("The run didn't use an isolated profile: " + json.dumps(ready))
                profile = Path(ready["profile"]["path"])
                deadline = time.monotonic() + DEADLINE
                while time.monotonic() < deadline and len(installed(profile)) < len(COMPONENTS):
                    time.sleep(5)
                # Local State, where the updater persists what it checked, commits every
                # ten seconds. The profile is gone once the run stops, so read it now.
                time.sleep(15)
                issues = problems(profile, build_time)
                found = installed(profile)
                for component, version in found.items():
                    output.write(f"{COMPONENTS[component][0]} {version.name}\n")
                if CRL_SET in found:
                    header = crl_set_header(found[CRL_SET] / "crl-set")
                    output.write(f"CRLSet sequence {header['Sequence']}, NotAfter {header.get('NotAfter')}\n")
            finally:
                if run.process.poll() is None:
                    run.process.send_signal(signal.SIGINT)
                run.finish()
            if issues:
                raise ValueError("; ".join(issues))
            output.write("ARX_COMPONENT_UPDATES_SMOKE_SUCCESS\n")
        print("ARX_COMPONENT_UPDATES_SMOKE_SUCCESS")
