"""Owned loopback favicon cases; image loads require the browser profile cookie.

The icon origin (DEV-796) covers saved pages that never loaded: their icons
come from the app's directory or the site's root page, or /favicon.ico, never
the saved path, and land in that profile's database. The page requests carry
the profile's cookies for the site and the icon requests none (DEV-1108). A
page that redirects to another host (a sign-in page) gives that host's icons
nothing; the saved site's own /favicon.ico is used (DEV-1108).
"""

import base64
import http.server
import os
import stat
import struct
import subprocess
import threading
import zlib
from http.cookies import SimpleCookie
from urllib.parse import urlsplit

from . import smoke

SENTINEL = "Arx site icons disposable fixture v1\n"
MARKERS = ("ARX_SITE_ICONS_DATABASE_SUCCESS", "ARX_SITE_ICONS_FETCH_SUCCESS",
           "ARX_SITE_ICONS_PROFILE_SUCCESS", "ARX_SITE_ICONS_SMOKE_SUCCESS")
MANIFEST = ".arx-site-icons-restart.json"
RESTART_MARKER = "ARX_SITE_ICONS_RESTART_SUCCESS"
COLORS = {"red": (255, 0, 0), "green": (0, 255, 0), "blue": (0, 0, 255)}
DECLARED = (255, 255, 0)
FALLBACK = (255, 0, 255)
# The stage's origins are hosts no other stage uses: cookies are kept per host,
# not per port, so a cookie an earlier stage stored for 127.0.0.1 or localhost
# would ride along on this stage's page requests (DEV-1108).
DECLARED_HOST = "declared.localhost"
BARE_HOST = "bare.localhost"
SIGN_IN_HOST = "sign-in.localhost"
# DEV-1108: a root that redirects to another host's sign-in page, which declares
# its own icon; the redirecting site's /favicon.ico is its own.
REDIRECTING_HOST = "redirect.localhost"
SIGN_IN = (255, 128, 0)
OWN = (0, 255, 255)
# A loaded page whose script replaces its icon after load (DEV-1108).
SCRIPTED = {"first": (128, 0, 255), "second": (0, 128, 0)}
# DEV-1108: a signed-in app. Its sign-in page sets the profile's cookie; with it,
# the app's directory answers with the app's own icon, and without it, it sends
# the visitor to the sign-in page on another host, so its own /favicon.ico is used.
APP_HOST = "app.localhost"
APP_COOKIE = "arx_signed_in=1"
APP_ICON = (0, 0, 128)
APP_OWN = (128, 128, 0)
# Each lookup tries the saved path's app directory (/saved/, a 404 on the first
# three origins) before the root. Two ordinary profiles each fetch the declared
# origin's pages and icon once (the first profile's second read comes from its
# database); the bare origin's pages and /favicon.ico are fetched once. The
# redirecting site's root redirects to another site's sign-in page, which a page
# request never follows, so the site's own /favicon.ico is used. The signed-in
# profile gets the app's own icon from its directory; the other profile, sent
# toward the sign-in page from both pages, gets the app host's /favicon.ico.
# Only page requests carry the profile's cookie. The saved paths are never
# requested.
FETCH_REQUESTS = sorted(
    [(DECLARED_HOST, "/saved/", False), (DECLARED_HOST, "/", False), (DECLARED_HOST, "/declared.png", False)] * 2
    + [(BARE_HOST, "/saved/", False), (BARE_HOST, "/", False), (BARE_HOST, "/favicon.ico", False)]
    + [(REDIRECTING_HOST, "/saved/", False), (REDIRECTING_HOST, "/", False),
       (REDIRECTING_HOST, "/favicon.ico", False)]
    + [(APP_HOST, "/sign-in-here", False), (APP_HOST, "/mail/", True), (APP_HOST, "/mail/icon.png", False)]
    + [(APP_HOST, "/mail/", False), (APP_HOST, "/", False), (APP_HOST, "/favicon.ico", False)])


def png(color):
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    pixels = b"".join(b"\0" + bytes((*color, 255)) * 32 for _ in range(32))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def prepare(root):
    if not root.name.startswith("app-smoke-"):
        raise ValueError("Site icons require an owned disposable runner root")
    for path in (root, root / "profile"):
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700 or info.st_uid != os.getuid():
            raise ValueError("Site icons require private owned directories")
    if (root / "profile").resolve().parent != root.resolve():
        raise ValueError("Site icon profile escaped its root")
    descriptor = os.open(root / ".arx-site-icons-smoke", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(SENTINEL)
    descriptor = os.open(root / MANIFEST, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(descriptor)
    return {"ARX_SITE_ICONS_SMOKE_ROOT": str(root)}


class IconOriginHandler(http.server.BaseHTTPRequestHandler):
    """Five hosts on one port: declared.localhost declares an icon, bare.localhost has
    only /favicon.ico, redirect.localhost sends its root to sign-in.localhost's sign-in
    page, and app.localhost is an app that shows its own page only to a signed-in profile."""

    def do_GET(self):
        host = self.headers.get("Host", "").rsplit(":", 1)[0]
        path = urlsplit(self.path).path
        if getattr(self.server, "site_icon_restart_forbidden", False):
            self.server.site_icon_restart_requests.append(path)
            self.send_error(410, "Restart fixture forbids navigation and icon requests")
            return
        self.server.site_icon_fetch_requests.append((host, path, "Cookie" in self.headers))
        if host == DECLARED_HOST and path == "/":
            body = (b'<!doctype html><html><head><title>Arx declared icon</title>'
                    b'<link rel="icon" type="image/svg+xml" href="/vector.svg">'
                    b'<link rel="icon" type="image/png" sizes="32x32" href="declared.png">'
                    b'</head><body><link rel="icon" href="/body.png"></body></html>')
            respond(self, 200, "text/html; charset=utf-8", body)
        elif host == DECLARED_HOST and path == "/declared.png":
            respond(self, 200, "image/png", png(DECLARED))
        elif host == BARE_HOST and path == "/":
            respond(self, 200, "text/html; charset=utf-8", b"<!doctype html><title>Arx bare origin</title>")
        elif host == BARE_HOST and path == "/favicon.ico":
            respond(self, 200, "image/png", png(FALLBACK))
        elif host == REDIRECTING_HOST and path == "/":
            self.send_response(302)
            self.send_header("Location", f"http://{SIGN_IN_HOST}:{self.server.server_port}/sign-in")
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
        elif host == SIGN_IN_HOST and path == "/sign-in":
            body = (b'<!doctype html><html><head><title>Arx sign-in page</title>'
                    b'<link rel="icon" type="image/png" sizes="32x32" href="/sign-in.png">'
                    b'</head><body></body></html>')
            respond(self, 200, "text/html; charset=utf-8", body)
        elif host == SIGN_IN_HOST and path == "/sign-in.png":
            respond(self, 200, "image/png", png(SIGN_IN))
        elif host == REDIRECTING_HOST and path == "/favicon.ico":
            respond(self, 200, "image/png", png(OWN))
        elif host == APP_HOST and path == "/sign-in-here":
            # Signs the profile in; its inline icon keeps the load from asking for /favicon.ico.
            body = (b'<!doctype html><html><head><title>Arx signed in</title>'
                    b'<link rel="icon" href="data:image/png;base64,' + base64.b64encode(png(APP_ICON)) + b'">'
                    b'</head><body>Signed in</body></html>')
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", f"{APP_COOKIE}; Path=/; SameSite=Lax")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif host == APP_HOST and path == "/mail/" and APP_COOKIE in self.headers.get("Cookie", ""):
            body = (b'<!doctype html><html><head><title>Arx app</title>'
                    b'<link rel="icon" type="image/png" sizes="32x32" href="/mail/icon.png">'
                    b'</head><body></body></html>')
            respond(self, 200, "text/html; charset=utf-8", body)
        elif host == APP_HOST and path in ("/", "/mail/"):
            self.send_response(302)
            self.send_header("Location", f"http://{SIGN_IN_HOST}:{self.server.server_port}/sign-in")
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
        elif host == APP_HOST and path == "/mail/icon.png":
            respond(self, 200, "image/png", png(APP_ICON))
        elif host == APP_HOST and path == "/favicon.ico":
            respond(self, 200, "image/png", png(APP_OWN))
        else:
            respond(self, 404, "text/plain", b"")

    def log_message(self, *_):
        pass


def start_icon_origin():
    """A second loopback port, so the fixture's own pages keep having no root icon."""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), IconOriginHandler)
    server.site_icon_fetch_requests = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread, {"ARX_SITE_ICONS_ORIGIN_PORT": str(server.server_port)}


def stop_icon_origin(server, thread):
    server.shutdown()
    server.server_close()
    thread.join()


def respond(handler, status, mime, body):
    handler.send_response(status)
    handler.send_header("Content-Type", mime)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)


def verify_fetch(requests):
    """Each profile fetched the site's pages and icon once, never the saved path, with the
    profile's cookie on page requests only."""
    if sorted(requests) != FETCH_REQUESTS:
        raise ValueError(f"Unvisited page icons were not fetched once per profile as expected: {requests}")


def verify(stdout):
    missing = set(MARKERS) - set(stdout.splitlines())
    if missing:
        raise ValueError("Native site icon smoke incomplete: " + ", ".join(sorted(missing)))


def serve(handler):
    path = urlsplit(handler.path).path
    if not path.startswith("/site-icons/"):
        return False
    if getattr(handler.server, "site_icon_restart_forbidden", False):
        handler.server.site_icon_restart_requests.append(path)
        handler.send_error(410, "Restart fixture forbids navigation and icon requests")
        return True
    cookie = SimpleCookie(handler.headers.get("Cookie", ""))
    value = cookie.get("arx_site_icon")
    identity = value.value if value else None
    filename = path.removeprefix("/site-icons/")
    if filename == "scripted.html":
        # Declares one icon, then replaces it from script once loaded (DEV-1108).
        body = (b'<!doctype html><title>Arx scripted site icon</title>'
                b'<link id="icon" rel="icon" type="image/png" sizes="32x32" href="/site-icons/scripted-first.png">'
                b'<h1>Owned scripted icon</h1><script>addEventListener("load", () => setTimeout(() => {'
                b'document.getElementById("icon").href = "/site-icons/scripted-second.png";'
                b'document.title = "Arx scripted site icon replaced"; }, 300));</script>')
        respond(handler, 200, "text/html; charset=utf-8", body)
        return True
    scripted = filename.removeprefix("scripted-").removesuffix(".png")
    if filename.startswith("scripted-") and filename.endswith(".png") and scripted in SCRIPTED:
        respond(handler, 200, "image/png", png(SCRIPTED[scripted]))
        return True
    if filename.startswith("set-") and filename.removeprefix("set-").removesuffix(".html") in COLORS:
        color = filename.removeprefix("set-").removesuffix(".html")
        handler.send_response(302)
        handler.send_header("Location", "/site-icons/page.html")
        handler.send_header("Set-Cookie", f"arx_site_icon={color}; Path=/site-icons/; SameSite=Strict")
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True
    if filename == "page.html":
        color = identity if identity in COLORS else "missing"
        body = (f'<!doctype html><title>Arx site icon {color}</title>'
                f'<link rel="icon" type="image/png" sizes="32x32" href="/site-icons/{color}.png">'
                f'<h1>Owned site icon {color}</h1>').encode()
        status, mime = 200, "text/html; charset=utf-8"
    elif filename.removesuffix(".png") in COLORS and filename.endswith(".png"):
        color = filename.removesuffix(".png")
        authorized = identity == color
        handler.server.site_icon_requests.append((color, authorized))
        status, mime = (200 if authorized else 403), "image/png"
        body = png(COLORS[color]) if authorized else b""
    else:
        status, mime, body = 404, "text/plain", b""
    handler.send_response(status)
    handler.send_header("Content-Type", mime)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)
    return True


def verify_restart(result, requests):
    startup_markers = ("ARX_BOOTSTRAP_ENTRY ", "ARX_BOOTSTRAP_REGISTERED", "ARX_BOOTSTRAP_FRAMEWORK_VERIFIED")
    # Each failure names its own reason, so a flaky run says which proof was missing (DEV-965).
    reasons = []
    if result.returncode:
        reasons.append(f"exit status {result.returncode}")
    if RESTART_MARKER not in result.stdout.splitlines():
        reasons.append("no restart marker")
    if requests:
        reasons.append(f"requests on restart: {sorted(set(map(str, requests)))}")
    missing = [marker.strip() for marker in startup_markers if marker not in result.stderr]
    if missing:
        reasons.append("missing startup markers " + ", ".join(missing))
    if reasons:
        raise ValueError("Favicon restart did not prove isolated database-only persistence: " + "; ".join(reasons))


def restart(app, environment, server, log, origin=None):
    """Run only after the first signed process exits successfully; never rebuild or adopt another host."""
    env = dict(environment, ARX_SITE_ICONS_RESTART="1")
    env.pop("ARX_ENGINE_SMOKE_CRASH_REQUEST", None)
    server.site_icon_restart_requests = []
    server.site_icon_restart_forbidden = True
    if origin is not None:
        origin.site_icon_restart_requests = server.site_icon_restart_requests
        origin.site_icon_restart_forbidden = True
    with subprocess.Popen(
        [str(app / "Contents/MacOS/Arx")], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    ) as process:
        try:
            stdout, stderr = process.communicate(timeout=40)
        except subprocess.TimeoutExpired as error:
            process.kill()
            stdout, stderr = process.communicate()
            smoke.append(log, stdout, stderr)
            raise ValueError("Favicon restart smoke timed out") from error
        result = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
    smoke.append(log, result.stdout, result.stderr)
    verify_restart(result, server.site_icon_restart_requests)
