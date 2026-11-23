"""Own HTTP-only pages for the native back/forward cache fixture (DEV-943).

Each page writes one state line on `pageshow`: whether the browser restored it
from the back/forward cache (`persisted`), how often this server served it, and
a token its script drew when it first ran. A reload would serve it again and
draw a new token; a restore keeps both. Nothing here may block the cache: no
`Cache-Control: no-store`, no unload handlers, no open connections.

The server records every request it answers, so a failed run's log shows what
the page fetched and when (`request_log`).
"""
import struct
import threading
import time
import zlib
from urllib.parse import urlsplit

TITLES = {"a": "Arx cache A", "b": "Arx cache B", "media": "Arx cache media"}
STATE = "ARX_BACK_FORWARD_CACHE_STATE"
BUTTON = "Arx cache button"
START = "Arx cache start"
# The media page's video, served by media_fixture.
VIDEO = "/media/pattern.webm"
# The media page's Media Session metadata (DEV-960). Artwork must be at least 48 px for the engine.
TRACK = "Arx cache track"
ARTIST = "Arx cache artist"
ARTWORK = "/back-forward-cache/artwork.png"
ARTWORK_SIZE = 96
# The title the page sets, dropping its next track handler, on its third restore.
CHANGED_TRACK = "Arx cache track changed"
CHANGED_ON_RESTORE = 3

REQUEST = "ARX_BACK_FORWARD_CACHE_FIXTURE_REQUEST"

_served = {}
_requests = []
_started = time.monotonic()
_lock = threading.Lock()


def icon(size=32, color=(255, 0, 0)):
    """An opaque square PNG: by default the 32 px red site icon."""
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    pixels = b"".join(b"\0" + bytes((*color, 255)) * size for _ in range(size))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def artwork():
    """The media page's track artwork: a blue PNG the engine accepts as artwork."""
    return icon(ARTWORK_SIZE, (0, 0, 255))


def page(name, served):
    return (f'<!doctype html><meta charset="utf-8"><title>{TITLES[name]}</title>'
            '<link rel="icon" type="image/png" sizes="32x32" href="/back-forward-cache/icon.png">'
            f'<h1>{TITLES[name]}</h1><p id="state"></p><button aria-label="{BUTTON}">{BUTTON}</button>'
            '<script>const token=Math.random().toString(36).slice(2,12);'
            'addEventListener("pageshow",e=>{document.getElementById("state").textContent='
            f'"{STATE} persisted="+e.persisted+" served={served} token="+token;}});</script>')


def media_page(served):
    """Plays its video on a trusted click, then pauses it once, so a paused player goes into the cache.

    The clip lasts two seconds. Chromium treats media of five seconds or less as transient: its
    session isn't controllable and offers no Play action, before leaving or after a restore, unless
    the page reports a playback state through the Media Session API, as players on real sites do.
    So the page reports one.

    A restore drops that report in the browser but not in the page: the restored document's
    navigation resets its media session service (`MediaSessionImpl::DidFinishNavigation` calls
    `MediaSessionServiceImpl::DidFinishNavigation` without checking for a cache restore), while
    `navigator.mediaSession.playbackState` still reads "paused". Chrome then offers no Play for this
    clip either. Persistent media (longer than five seconds) stays controllable without a report.
    So a restored page reports its state again on `pageshow`.

    The page also names its track, with artist and artwork, and offers previous and next track
    (DEV-960). A restore keeps both in the browser, as the page never sends them again; on its
    third restore the page renames the track and drops its next track handler, and that change
    wins over what the browser kept.
    """
    return ('<!doctype html><meta charset="utf-8"><title>Arx cache media</title>'
            '<link rel="icon" type="image/png" sizes="32x32" href="/back-forward-cache/icon.png">'
            '<style>body{margin:0}video{width:320px;height:180px}'
            '#start{position:absolute;left:0;top:0;width:100%;height:100%;opacity:.4}</style>'
            f'<video preload="auto" playsinline src="{VIDEO}"></video><p id="state"></p>'
            f'<button id="start">{START}</button>'
            '<script>const token=Math.random().toString(36).slice(2,12);const video=document.querySelector("video");'
            'let paused=false;let restores=0;const session=navigator.mediaSession;'
            'const track=title=>new MediaMetadata({title,artist:"' + ARTIST + '",artwork:[{src:"' + ARTWORK
            + f'",sizes:"{ARTWORK_SIZE}x{ARTWORK_SIZE}",type:"image/png"}}]}});'
            'session.metadata=track("' + TRACK + '");'
            'session.setActionHandler("previoustrack",()=>{});session.setActionHandler("nexttrack",()=>{});'
            'document.getElementById("start").addEventListener("click",e=>{if(e.isTrusted)video.play().catch(()=>{});});'
            'video.addEventListener("playing",()=>{navigator.mediaSession.playbackState="playing";'
            'if(paused)return;paused=true;setTimeout(()=>video.pause(),300);});'
            'video.addEventListener("pause",()=>{navigator.mediaSession.playbackState="paused";});'
            'addEventListener("pageshow",e=>{if(e.persisted)navigator.mediaSession.playbackState='
            'video.paused?"paused":"playing";'
            f'if(e.persisted&&++restores==={CHANGED_ON_RESTORE}){{session.metadata=track("{CHANGED_TRACK}");'
            'session.setActionHandler("nexttrack",null);}'
            'document.getElementById("state").textContent='
            f'"{STATE} persisted="+e.persisted+" served={served} token="+token;}});</script>')


def served(name):
    with _lock:
        return _served.get(name, 0)


def reset():
    global _started
    with _lock:
        _served.clear()
        _requests.clear()
        _started = time.monotonic()


def record(method, path, status, byte_range=None):
    """Notes one answered request, with seconds since `reset`."""
    with _lock:
        line = f"{time.monotonic() - _started:.3f}s {method} {path} {status}"
        _requests.append(line + (f" range={byte_range}" if byte_range else ""))


def request_log():
    """Every recorded request as one log line each."""
    with _lock:
        return "".join(f"{REQUEST} {line}\n" for line in _requests)


def serve(handler):
    request = urlsplit(handler.path)
    if not request.path.startswith("/back-forward-cache/"):
        return False
    name = request.path.removeprefix("/back-forward-cache/")
    if request.query or (name not in TITLES and name not in ("icon.png", "artwork.png")):
        handler.send_response(404)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True
    if name == "icon.png":
        kind, data = "image/png", icon()
    elif name == "artwork.png":
        kind, data = "image/png", artwork()
    else:
        with _lock:
            _served[name] = _served.get(name, 0) + 1
            count = _served[name]
        body = media_page(count) if name == "media" else page(name, count)
        kind, data = "text/html; charset=utf-8", body.encode()
    handler.send_response(200)
    handler.send_header("Content-Type", kind)
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)
    return True
