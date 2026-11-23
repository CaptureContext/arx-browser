"""Explicit opt-in and completion gates for the prepared ABI6 native media fixture."""

import os
import stat

from .paths import ROOT
from .process import run

SENTINEL = "Arx media disposable fixture v1\n"
MARKERS = (
    "ARX_MEDIA_PLAYBACK_SUCCESS",
    "ARX_MEDIA_PIP_WINDOW_SUCCESS",
    "ARX_MEDIA_REPLACEMENT_SUCCESS",
    "ARX_MEDIA_INVALIDATION_SUCCESS",
    "ARX_MEDIA_POSITION_SUCCESS",
    "ARX_MEDIA_VOLUME_SUCCESS",
    "ARX_MEDIA_APP_TAB_MUTE_SUCCESS",
    "ARX_MEDIA_AUTOMATIC_SUCCESS",
    "ARX_MEDIA_AUTOMATIC_GATES_SUCCESS",
    "ARX_MEDIA_VISIBILITY_AUTOMATIC_SUCCESS",
    "ARX_MEDIA_VISIBLE_PEERS_AUTOMATIC_SUCCESS",
    "ARX_MEDIA_PRIVATE_POLICY_SUCCESS",
    # DEV-848: automatic PiP triggers, full-screen apps and aspect ratio.
    # DEV-1246: Arx losing focus with its window on screen floats nothing.
    "ARX_AUTOMATIC_PIP_FOCUS_LOSS_STAYS_SUCCESS",
    "ARX_AUTOMATIC_PIP_TAB_SWITCH_SUCCESS",
    "ARX_AUTOMATIC_PIP_LANDSCAPE_ASPECT_SUCCESS",
    # DEV-852: throws, time labels, display changes and full-screen apps.
    "ARX_AUTOMATIC_PIP_FLING_SUCCESS",
    "ARX_AUTOMATIC_PIP_TIME_LABELS_SUCCESS",
    "ARX_AUTOMATIC_PIP_DISPLAY_CHANGE_SUCCESS",
    # DEV-1322: another app's full-screen Space taking the display from a window that isn't full
    # screen floats nothing; from a full-screen window it floats the video.
    "ARX_AUTOMATIC_PIP_OS_WORKSPACE_WINDOWED_STAYS_SUCCESS",
    "ARX_AUTOMATIC_PIP_FULL_SCREEN_SUCCESS",
    "ARX_AUTOMATIC_PIP_TAB_RETURN_SUCCESS",
    "ARX_AUTOMATIC_PIP_OS_WORKSPACE_FULL_SCREEN_SUCCESS",
    "ARX_AUTOMATIC_PIP_PORTRAIT_ASPECT_SUCCESS",
    "ARX_AUTOMATIC_PIP_SMOKE_SUCCESS",
    # DEV-949: page full screen from a window in and out of macOS full screen.
    "ARX_PAGE_FULL_SCREEN_VIDEO_SUCCESS",
    # DEV-991: a playing video stays full screen through the window's Space transition, with no PiP;
    # the page's own exit restores the window; ⌘S shows the sidebar beside the page and hides it.
    "ARX_PAGE_FULL_SCREEN_STAYS_SUCCESS",
    "ARX_PAGE_FULL_SCREEN_ESCAPE_SUCCESS",
    "ARX_PAGE_FULL_SCREEN_ELEMENT_SUCCESS",
    "ARX_PAGE_FULL_SCREEN_PAGE_EXIT_SUCCESS",
    "ARX_PAGE_FULL_SCREEN_TAB_SWITCH_SUCCESS",
    "ARX_PAGE_FULL_SCREEN_SIDEBAR_SUCCESS",
    "ARX_PAGE_FULL_SCREEN_KEEPS_WINDOW_SUCCESS",
    "ARX_PAGE_FULL_SCREEN_SMOKE_SUCCESS",
    # DEV-991 again, in the app's own main window: its BrowserWindow, sidebar, media and activity.
    "ARX_PAGE_FULL_SCREEN_APP_WINDOW_STAYS_SUCCESS",
    "ARX_PAGE_FULL_SCREEN_APP_WINDOW_SIDEBAR_SUCCESS",
    "ARX_PAGE_FULL_SCREEN_APP_WINDOW_RESTORE_SUCCESS",
    # DEV-950: Page PiP takes clicks and typing and returns without reloading.
    "ARX_PAGE_PICTURE_CLICK_SUCCESS",
    "ARX_PAGE_PICTURE_TYPING_SUCCESS",
    # DEV-1247: Page PiP and Little Arx move when dragged by the URL bar or a button, which then
    # do nothing; a click without movement still works.
    "ARX_PAGE_PICTURE_DRAG_ADDRESS_SUCCESS",
    "ARX_PAGE_PICTURE_DRAG_BUTTON_SUCCESS",
    "ARX_LITTLE_ARX_DRAG_ADDRESS_SUCCESS",
    "ARX_LITTLE_ARX_DRAG_BUTTON_SUCCESS",
    "ARX_PAGE_PICTURE_RETURN_SUCCESS",
    "ARX_PAGE_PICTURE_SMOKE_SUCCESS",
    "ARX_MEDIA_SMOKE_SUCCESS",
)
# DEV-962: PiP must float over another app's full-screen window, so the smoke takes one full screen
# in a fixture app of its own; the app smoke builds it into the runner root.
FULL_SCREEN_HOST = "Scripts/fixtures/FullScreenHostFixture.swift"
# Phases a display can't run, with the exact line that stands in for their marker and what the
# runner prints instead. PiP over another app's full-screen window needs full-screen Spaces, which
# the app checks with a probe window of its own; where the probe floats, the PiP window must too.
SKIPS = {
    "ARX_AUTOMATIC_PIP_FULL_SCREEN_SUCCESS": (
        "ARX_AUTOMATIC_PIP_FULL_SCREEN_SKIPPED reason=no-full-screen-spaces",
        "PiP over a full-screen window: skipped: no full-screen Spaces",
    ),
    "ARX_AUTOMATIC_PIP_OS_WORKSPACE_WINDOWED_STAYS_SUCCESS": (
        "ARX_AUTOMATIC_PIP_OS_WORKSPACE_WINDOWED_SKIPPED reason=no-full-screen-spaces",
        "No PiP when a window that isn't full screen leaves the display: skipped: no full-screen Spaces",
    ),
    "ARX_AUTOMATIC_PIP_OS_WORKSPACE_FULL_SCREEN_SUCCESS": (
        "ARX_AUTOMATIC_PIP_OS_WORKSPACE_FULL_SCREEN_SKIPPED reason=no-full-screen-spaces",
        "PiP when a full-screen window's OS workspace leaves the display: skipped: no full-screen Spaces",
    ),
}


def prepare(root):
    # MCP setup already created the fresh profile; never claim an existing browser directory.
    if not root.name.startswith("app-smoke-"):
        raise ValueError("Media smoke requires an owned disposable runner root")
    for path in (root, root / "profile"):
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700 or info.st_uid != os.getuid():
            raise ValueError("Media smoke requires private owned directories")
    if (root / "profile").resolve().parent != root.resolve():
        raise ValueError("Media smoke profile escaped its root")
    marker = root / ".arx-media-smoke"
    descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(SENTINEL)
    return {"ARX_MEDIA_SMOKE_ROOT": str(root)}


def build_full_screen_host(root):
    """Builds the full-screen fixture app into the runner root and names it to Arx (DEV-962)."""
    host = root / "full-screen-host"
    run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(ROOT / FULL_SCREEN_HOST), "-o", str(host)],
        log="full-screen-host-build.log")
    return {"ARX_MEDIA_SMOKE_FULL_SCREEN_HOST": str(host)}


def verify(stdout):
    """Requires every phase; returns the notes for phases this display skipped, and prints them."""
    lines = set(stdout.splitlines())
    missing = [marker for marker in MARKERS
               if marker not in lines and not (marker in SKIPS and SKIPS[marker][0] in lines)]
    if missing:
        raise ValueError("Native media smoke did not complete: " + ", ".join(missing))
    skipped = [note for marker, (line, note) in SKIPS.items() if marker not in lines and line in lines]
    for note in skipped:
        print(note)
    return skipped
