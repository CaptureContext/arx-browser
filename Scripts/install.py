"""make install and make update: a Developer ID–signed Release build swapped into /Applications.

The build, signing and checks are make dmg's own `build`, `sign` and `check` steps, so the installed
app keeps the bundle ID, team and entitlements of a release and reaches the same data and Keychain
items. There's no notarization, disk image or checksum, and the build number stays as it is.

`--no-timestamp` signs without Apple's secure timestamp. Only notarization needs one, and nothing
here is notarized, so the installed app is the same to use; it lets an install go through while
the timestamp service is down or out of reach.
"""

import argparse
import ctypes
import os
import shutil
import time
from pathlib import Path

from . import build_app, release
from .core.paths import ROOT
from .core.process import run


INSTALLED = Path("/Applications/Arx.app")
STAGING = ROOT / "build/install/Arx.app"
ENTITLEMENTS = ROOT / "build/install/Arx.entitlements"
QUIT_TIMEOUT = build_app.QUIT_TIMEOUT
# renamex_np flags from <stdio.h>.
RENAME_SWAP = 0x2
RENAME_EXCL = 0x4


def staged_path(installed):
    """The new bundle's place next to the installed one, on the same volume so the swap is a rename."""
    return installed.with_name(f".{installed.name}.new")


def quit_running(installed, *, running=build_app.running_arx, timeout=QUIT_TIMEOUT, sleep=time.sleep, clock=time.monotonic):
    """Asks the Arx running from the installed bundle to quit as Command-Q does, so it saves its
    session, and waits for it. Builds running from elsewhere are left alone. Never force-quits.
    Returns whether it was running."""
    if not running(quitting=True, path=installed):
        return False
    deadline = clock() + timeout
    while running(path=installed):
        if clock() >= deadline:
            raise ValueError(
                f"Arx didn't quit within {timeout:g} seconds; it may be asking you to confirm. "
                f"Quit it yourself and run the command again. {installed} was not changed."
            )
        sleep(0.5)
    return True


def renamex(source, destination, flags):
    libc = ctypes.CDLL(None, use_errno=True)
    function = libc.renamex_np
    function.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    function.restype = ctypes.c_int
    if function(os.fsencode(source), os.fsencode(destination), flags) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def swap(new, installed, *, rename=renamex):
    """Puts the new bundle in place in one rename. With an app already installed the two trade
    places, so `new` then holds the old app; with none, the rename fails rather than overwrite one
    that appeared meanwhile. Either way the installed app is whole at every moment."""
    if installed.exists() or installed.is_symlink():
        rename(new, installed, RENAME_SWAP)
    else:
        rename(new, installed, RENAME_EXCL)


def should_relaunch(was_running, requested):
    return was_running or requested


def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def copy_next_to(app, installed):
    """Copies the signed app beside the installed one and verifies the copy, so nothing installed
    changes until a complete, valid bundle is ready to swap in."""
    new = staged_path(installed)
    remove(new)
    try:
        run(["ditto", str(app), str(new)])
        run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(new)])
    except BaseException:
        remove(new)
        raise
    return new


def replace(app, installed, *, requested_open=False, quit=quit_running, launch=None):
    """Quits the installed Arx if it's running, swaps the new bundle in and relaunches it when it
    was running or asked to. If the copy, its check or quitting fails, the installed app stays as it was."""
    launch = launch or (lambda path: run(["open", str(path)]))
    new = copy_next_to(app, installed)
    try:
        was_running = quit(installed)
        swap(new, installed)
    finally:
        # After a swap this is the old app; otherwise it's the unused copy.
        remove(new)
    print(f"Installed {installed}", flush=True)
    if should_relaunch(was_running, requested_open):
        launch(installed)
    return was_running


def parser(command):
    verb = "Update the installed" if command == "update" else "Install"
    result = argparse.ArgumentParser(
        prog=f"make {command}",
        description=f"{verb} Arx in /Applications with a Developer ID–signed Release build, without notarization or a disk image.",
    )
    result.add_argument("--open", action="store_true", help="open Arx afterwards even if it wasn't running")
    result.add_argument(
        "--no-timestamp", action="store_true",
        help="sign without Apple's secure timestamp, for when its timestamp service is down or out of reach",
    )
    return result


def main(arguments=(), *, command="install", installed=None):
    options = parser(command).parse_args(list(arguments))
    installed = Path(installed or INSTALLED)
    if command == "update" and not installed.is_dir():
        raise ValueError(f"There's no {installed} to update. Run make install to install it.")
    # Before the build, so missing signing settings fail fast, as in make dmg.
    signer = release.signer(argparse.Namespace(development_identity=False))
    release.build(bump=False, destination=STAGING)
    release.sign(STAGING, signer, entitlements=ENTITLEMENTS, timestamp=not options.no_timestamp)
    release.check(STAGING, signer)
    replace(STAGING, installed, requested_open=options.open)


def install(arguments=()):
    return main(arguments, command="install")


def update(arguments=()):
    return main(arguments, command="update")
