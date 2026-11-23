"""Embed the complete local engine into an Xcode-built application."""

import os
import shutil
from pathlib import Path

from ..core.process import execute, run
from . import bundle, cache
from .config import LOCK


def main():
    destination = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["FRAMEWORKS_FOLDER_PATH"] / LOCK["framework"]
    if not cache.available():
        if destination.exists():
            shutil.rmtree(destination)
        if os.environ.get("ARX_REQUIRE_ENGINE") == "1":
            cache.require()
        print("warning: Arx engine is unavailable. Run make engine-restore or make engine-build before launching the app.")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    source = cache.require()
    architectures = os.environ.get("ARCHS", "").split() or None
    bundle.validate_framework(source, architectures=architectures)
    # ditto preserves the framework's version symlinks and nested helper applications.
    if destination.exists():
        shutil.rmtree(destination)
    run(["ditto", str(source), str(destination)])
    bundle.validate_framework(destination, architectures=architectures)
    if os.environ.get("CODE_SIGNING_ALLOWED") == "YES":
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
        run(["codesign", "--force", "--deep", "--sign", identity, str(destination)])


if __name__ == "__main__":
    raise SystemExit(execute(main))
