"""Arx's own back and forward swipe on a WebKit page (DEV-1203).

The app smoke's overnight `webkit-swipe` phase. Set `ARX_SMOKE_OVERNIGHT=1` for `make app-smoke`
to run it: it moves a page to WebKit, which starts WebKit's own processes.

The app (`WebKitSwipeSmoke`) lists `localhost` for WebKit. `webkit-swipe-a.html`, in Chromium on
`127.0.0.1`, follows its link to `webkit-swipe-b.html` on `localhost` by script when its address
ends in `#follow`, dropping the fragment first so Back to it doesn't follow again; the router
moves the tab to WebKit as a page that reached a listed site itself. B's link, clicked in WebKit,
opens `webkit-swipe-c.html` on the same site, so the WebKit page has two entries.

The app then delivers synthesized precise trackpad scrolls straight to the WebKit page's view:
a swipe back lands on B in WebKit, forward on C and back on B again; a swipe back from WebKit's
first entry reopens A in Chromium; the Forward command (as ⌘] sends it) from A moves the tab to
WebKit on B, since a swipe forward on A is Chromium's own, which the gesture smoke's engine
fixture covers, and the WebKit page it shows still has C ahead of B (DEV-1293); a swipe back
short of the threshold leaves B where it is. Across engines the other way (DEV-1293), A typed on B
opens in Chromium, Back from it (as ⌘[ sends it) shows B in WebKit again, and a swipe forward from
B returns to A in Chromium, where the phase ends. The pages are no
wider than the window, so they never take the swipe's first wheel as a sideways scroll.

With the `ARX_WEBKIT_SWIPE` flag off, WebKit's own swipe returns; that run is out of scope.
"""

import os

PAGE_A = "webkit-swipe-a.html"
PAGE_B = "webkit-swipe-b.html"
PAGE_C = "webkit-swipe-c.html"
# The host the app lists for WebKit; A is on the fixture's 127.0.0.1.
LISTED_HOST = "localhost"
MARKER = "ARX_WEBKIT_SWIPE_SMOKE_SUCCESS"
STAGES = (
    "ARX_WEBKIT_SWIPE_SMOKE followed",
    "ARX_WEBKIT_SWIPE_SMOKE back in WebKit",
    "ARX_WEBKIT_SWIPE_SMOKE forward in WebKit",
    "ARX_WEBKIT_SWIPE_SMOKE back to Chromium",
    "ARX_WEBKIT_SWIPE_SMOKE forward command",
    "ARX_WEBKIT_SWIPE_SMOKE forward kept WebKit history",
    "ARX_WEBKIT_SWIPE_SMOKE short swipe stayed",
    "ARX_WEBKIT_SWIPE_SMOKE back into WebKit",
    "ARX_WEBKIT_SWIPE_SMOKE forward out of WebKit",
)

STYLE = (
    "<style>html,body{margin:0;overflow-x:hidden}"
    "body{font:32px system-ui;padding:64px;min-height:100vh;box-sizing:border-box}</style>"
)


def enabled(environment=os.environ):
    return environment.get("ARX_SMOKE_OVERNIGHT") == "1"


def _page(title, next_file, next_host, follows):
    """A fixture page whose link `#next` opens `next_file`, on `next_host` when given."""
    target = "new URL('" + next_file + "', location.href)"
    script = (
        "<script>"
        "const next = " + target + ";"
        + ("next.hostname = '" + next_host + "';" if next_host else "")
        + "next.hash = '';"
        "document.getElementById('next').href = next.href;"
        + (
            "if (location.hash === '#follow') {"
            "history.replaceState(null, '', location.pathname);"
            "setTimeout(() => location.assign(next.href), 300);"
            "}"
            if follows else ""
        )
        + "</script>"
    )
    return (
        "<!doctype html><meta charset=\"utf-8\"><title>" + title + "</title>" + STYLE
        + "<h1>" + title + "</h1><p>Owned WebKit swipe document.</p>"
        + "<a id=\"next\" href=\"" + next_file + "\">Next</a>"
        + script
    )


def prepare(root):
    with (root / PAGE_A).open("x") as page:
        page.write(_page("WebKit swipe A", PAGE_B, LISTED_HOST, follows=True))
    with (root / PAGE_B).open("x") as page:
        page.write(_page("WebKit swipe B", PAGE_C, None, follows=False))
    with (root / PAGE_C).open("x") as page:
        page.write(_page("WebKit swipe C", PAGE_A, None, follows=False))
    return {"ARX_WEBKIT_SWIPE_SMOKE": "1"}


def verify(stdout):
    lines = stdout.splitlines()
    for marker in STAGES + (MARKER,):
        if marker not in lines:
            raise ValueError("WebKit swipe smoke did not complete: " + marker)
