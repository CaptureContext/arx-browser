"""Configure and require all real-rendering capture assertions in app-smoke."""

import json

from . import capture_fixture

MARKERS = (
    "ARX_CAPTURE_PIXELS_SUCCESS",
    "ARX_CAPTURE_LAYOUT_SUCCESS",
    "ARX_CAPTURE_INVALIDATION_SUCCESS",
    "ARX_CAPTURE_SMOKE_SUCCESS",
)


def environment():
    return {"ARX_CAPTURE_SMOKE_PATCHES": json.dumps([
        dict(x=x, y=y, red=rgb[0], green=rgb[1], blue=rgb[2])
        for x, y, rgb in capture_fixture.PATCHES
    ])}


def verify(stdout):
    # Match complete lines, not a quoted diagnostic or an abbreviated success.
    lines = set(stdout.splitlines())
    missing = [marker for marker in MARKERS if marker not in lines]
    if missing:
        raise ValueError("Native capture smoke did not complete: " + ", ".join(missing))
