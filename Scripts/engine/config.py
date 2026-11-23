"""Engine paths and immutable upstream source identities."""

import json

from ..core.paths import ROOT

PACKAGE = ROOT / "Packages/engine"
WORK = ROOT / ".build/engine"
UPSTREAM = WORK / "helium-macos"
SOURCE = UPSTREAM / "build/src"
LOCK = json.loads((PACKAGE / "engine.lock.json").read_text())


def fingerprint():
    return json.dumps(LOCK, sort_keys=True)


def prepared_mismatch():
    """Why the prepared tree is not the locked source (an older checkout's), or None when it is.

    The stamp `prepare` writes records the lock the tree was prepared from; the ABI may change
    without touching the source.
    """
    stamp = WORK / "prepared.json"
    if not stamp.is_file():
        return None
    prepared = json.loads(stamp.read_text())
    if {k: v for k, v in prepared.items() if k != "abi"} == {k: v for k, v in LOCK.items() if k != "abi"}:
        return None

    def name(identity):
        helium = identity.get("helium") or {}
        return f"Chromium {identity.get('chromium', 'unknown')}, Helium {helium.get('version', 'unknown')}"

    return f"the prepared tree ({name(prepared)}) is not the one engine.lock.json pins ({name(LOCK)})"
