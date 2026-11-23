"""Find, verify and restore a prebuilt development engine without fetching Chromium sources.

An archive is looked for in this order (DEV-1282):

1. ``.build/engine-archives/<source fingerprint>/``: built here by ``make engine-cache`` or
   downloaded earlier by ``make engine-fetch``.
2. ``Artifacts/Engine/``: a copy placed beside the manifest by hand. Git ignores it.
3. The manifest's ``url``, a GitHub release asset, downloaded by ``make engine-fetch``.

Each candidate must match the manifest's size and SHA-256 before anything is unpacked.
"""

import hashlib
import json
import shutil
import tarfile
import tempfile
from pathlib import Path, PurePosixPath

from ..core.paths import ROOT
from . import artifact
from .config import LOCK, WORK

ARCHIVES = ROOT / "Artifacts/Engine"
# Ignored, and outside .build/engine, which the engine build runner links to a Chromium tree.
DOWNLOADS = ROOT / ".build/engine-archives"
RESTORED = WORK / "prebuilt"
# The public repository whose releases carry the engine archives, and nothing else. The engine's
# sources stay in this one.
RELEASES_REPOSITORY = "capturecontext/arx-browser-engine"


def checksum(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def paths():
    identity = artifact.identity()
    arch = identity["architecture"]
    if arch not in LOCK["architectures"]:
        raise ValueError(f"Unsupported ENGINE_ARCH: {arch}")
    name = f"arx-engine-macos-{arch}"
    return ARCHIVES / f"{name}.tar.gz", ARCHIVES / f"{name}.json"


def release_tag(identity):
    """One release per engine source fingerprint; each architecture is an asset of it."""
    return f"engine-{identity['sources'][:16]}"


def release_url(identity, name):
    return f"https://github.com/{RELEASES_REPOSITORY}/releases/download/{release_tag(identity)}/{name}"


def local_archive():
    archive, _ = paths()
    return DOWNLOADS / artifact.identity()["sources"] / archive.name


def problem(path, data):
    """Why ``path`` isn't the manifest's archive, or None when its size and SHA-256 match."""
    if not path.is_file():
        return f"{path} is missing"
    size = path.stat().st_size
    if size != data["bytes"]:
        return f"{path} has {size} bytes, the manifest expects {data['bytes']} (size mismatch)"
    if checksum(path) != data["sha256"]:
        return f"{path} doesn't match the manifest's SHA-256 (checksum mismatch)"
    return None


def locate(data):
    """The first verified local archive, and why each candidate was passed over."""
    tracked, _ = paths()
    problems = []
    for candidate in (local_archive(), tracked):
        reason = problem(candidate, data)
        if reason is None:
            return candidate, problems
        problems.append(reason)
    return None, problems


def metadata():
    archive, manifest = paths()
    if not manifest.is_file():
        raise ValueError(f"No cached engine for {artifact.identity()['architecture']}. Build it with make engine-build first.")
    data = json.loads(manifest.read_text())
    if (data.get("schema") != 1 or data.get("identity") != artifact.identity()
            or data.get("framework") != LOCK["framework"] or data.get("chromium") != LOCK["chromium"]
            or data.get("archive") != archive.name):
        raise ValueError("Cached engine does not match the current engine sources/architecture. Rebuild and run make engine-cache.")
    return data


def restored_directory():
    identity = artifact.identity()
    return RESTORED / identity["architecture"] / identity["sources"]


def validate_framework(framework):
    version = framework / "Versions" / LOCK["chromium"]
    if not (version / "Arx Framework").is_file():
        raise ValueError("Engine archive is missing its framework executable")
    for name in ["Helpers", "Libraries", "Resources"]:
        if not (version / name).is_dir():
            raise ValueError(f"Engine archive is missing {name}")
    if not (framework / "Versions/Current").is_dir():
        raise ValueError("Engine archive has a broken Versions/Current link")


def restored_available():
    directory = restored_directory()
    try:
        expected = metadata()
        if json.loads((directory / "artifact.json").read_text()) != expected:
            return False
        validate_framework(directory / LOCK["framework"])
    except (OSError, ValueError):
        return False
    return True


def available():
    return artifact.available() or restored_available()


def require():
    if artifact.available():
        return artifact.require()
    if restored_available():
        return restored_directory() / LOCK["framework"]
    raise ValueError("No matching engine. Run make engine-fetch for the prebuilt archive, or make engine-build from source.")


def restore():
    """Offline: unpack the first verified local archive. make engine-fetch also downloads one."""
    data = metadata()
    if restored_available():
        print(f"Engine already restored: {restored_directory()}")
        return
    archive, problems = locate(data)
    if archive is None:
        raise ValueError("No verified engine archive here: " + "; ".join(problems)
                         + ". Run make engine-fetch to download it, or make engine-build and make engine-cache.")
    unpack(archive, data)


def unpack(archive, data):
    """Extract ``archive``, which the caller has verified against ``data``."""
    destination = restored_directory()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".restore-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        with tarfile.open(archive, "r:gz") as bundle:
            for member in bundle.getmembers():
                path = PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != LOCK["framework"]:
                    raise ValueError(f"Unexpected path in engine archive: {member.name}")
            # Preserve internal framework links and executable bits; reject escaping links and special files.
            bundle.extractall(staging, filter="data")
        validate_framework(staging / LOCK["framework"])
        (staging / "artifact.json").write_text(json.dumps(data, indent=2) + "\n")
        if destination.exists():
            shutil.rmtree(destination)
        staging.rename(destination)
    print(f"Restored development engine: {destination / LOCK['framework']}")
