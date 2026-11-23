"""Owned loopback loading fixture with an explicitly released, bounded image."""

import base64
import threading
from urllib.parse import urlsplit

MAIN = b'<!doctype html><meta charset="utf-8"><title>Arx wait committed</title><img src="/wait/image" alt="owned delayed image">'
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5V0AAAAASUVORK5CYII=")
MAXIMUM_HOLD_SECONDS = 12


def prepare(server):
    server.wait_image_release = threading.Event()


def release(server):
    server.wait_image_release.set()


def serve(handler):
    path = urlsplit(handler.path).path
    if path not in ("/wait/main", "/wait/image", "/wait/release"):
        return False
    gate = handler.server.wait_image_release
    status = 200
    if path == "/wait/main":
        gate.clear()
        body, content_type = MAIN, "text/html; charset=utf-8"
    elif path == "/wait/image":
        released = gate.wait(MAXIMUM_HOLD_SECONDS)
        status = 200 if released else 503
        body, content_type = (PNG if released else b"expired"), "image/png"
    else:
        release(handler.server)
        body, content_type = b"released", "text/plain"
    try:
        handler.send_response(status)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Content-Length", str(len(body)))
        handler.send_header("Cache-Control", "no-store")
        handler.end_headers()
        handler.wfile.write(body)
    except (BrokenPipeError, ConnectionResetError):
        pass
    return True
