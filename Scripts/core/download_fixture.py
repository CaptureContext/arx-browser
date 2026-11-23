"""Deterministic attachment endpoints shared by signed browser runtime smoke tests."""

import hashlib
import time
from urllib.parse import urlsplit

PAYLOAD = b"Arx controlled download fixture\n" * 2048
PAYLOAD_SHA256 = hashlib.sha256(PAYLOAD).hexdigest()
FILENAME = "arx-download-smoke.txt"
SLOW_CHUNKS = 128
SLOW_CHUNK_BYTES = 64 * 1024
SLOW_BYTES = SLOW_CHUNKS * SLOW_CHUNK_BYTES


RESUMABLE_ETAG = '"arx-resumable-1"'


def serve_resumable(handler):
    """/downloads/resumable (DEV-892): the slow payload with an ETag and byte ranges.

    A request with `Range: bytes=N-` (and a matching `If-Range`, when sent) gets
    the rest from N as 206 Partial Content, and N is recorded on the server's
    `download_ranges` so the pause, relaunch and resume smoke can prove the
    transfer continued instead of starting over.
    """
    start = 0
    requested = handler.headers.get("Range", "")
    validator = handler.headers.get("If-Range")
    if requested.startswith("bytes=") and requested.endswith("-") and validator in (None, RESUMABLE_ETAG):
        try:
            start = int(requested.removeprefix("bytes=").removesuffix("-"))
        except ValueError:
            start = 0
        if not 0 <= start < SLOW_BYTES:
            start = 0
    # HTTP/1.1, unlike http.server's default: Chromium keeps a response's ETag and Last-Modified,
    # and so can resume the transfer after a quit, only when they're strong validators, which an
    # HTTP/1.0 response never has (HttpUtil::HasStrongValidators). Content-Length and Connection:
    # close still end each response (DEV-966).
    handler.protocol_version = "HTTP/1.1"
    if start:
        ranges = getattr(handler.server, "download_ranges", None) if hasattr(handler, "server") else None
        if ranges is not None:
            ranges.append(start)
        handler.send_response(206)
        handler.send_header("Content-Range", f"bytes {start}-{SLOW_BYTES - 1}/{SLOW_BYTES}")
    else:
        handler.send_response(200)
    handler.send_header("Content-Type", "application/octet-stream")
    handler.send_header("Content-Disposition", f'attachment; filename="{FILENAME}"')
    handler.send_header("Content-Length", str(SLOW_BYTES - start))
    handler.send_header("Accept-Ranges", "bytes")
    handler.send_header("ETag", RESUMABLE_ETAG)
    handler.send_header("Last-Modified", "Thu, 12 Nov 2026 00:00:00 GMT")
    handler.send_header("Connection", "close")
    handler.end_headers()
    handler.close_connection = True
    remaining = SLOW_BYTES - start
    try:
        while remaining > 0:
            size = min(SLOW_CHUNK_BYTES, remaining)
            handler.wfile.write(b"x" * size)
            handler.wfile.flush()
            remaining -= size
            time.sleep(0.05)
    except (BrokenPipeError, ConnectionResetError):
        # Pausing, quitting and cancelling all drop the connection.
        pass
    return True


def serve(handler):
    """Handle /downloads/{complete,duplicate,slow,retained,truncated,resumable}; return False otherwise.

    Call this first in an existing BaseHTTPRequestHandler.do_GET implementation.
    Complete and duplicate return identical known bytes and filename. Slow writes
    8 MiB over at least 6.4 seconds and tolerates explicit client cancellation.
    Retained uses the same bytes but stays active beyond all three bounded waits
    in the private-reopening fixture; cancelling it still closes promptly.
    Truncated promises a full payload but closes after its first 1024 bytes.
    """
    endpoint = urlsplit(handler.path).path
    if endpoint == "/downloads/resumable":
        return serve_resumable(handler)
    if endpoint not in {"/downloads/complete", "/downloads/duplicate", "/downloads/slow",
                        "/downloads/retained", "/downloads/truncated"}:
        return False
    slow = endpoint in {"/downloads/slow", "/downloads/retained"}
    delay = 1.0 if endpoint == "/downloads/retained" else 0.05
    handler.send_response(200)
    handler.send_header("Content-Type", "application/octet-stream")
    handler.send_header("Content-Disposition", f'attachment; filename="{FILENAME}"')
    handler.send_header("Content-Length", str(SLOW_BYTES if slow else len(PAYLOAD)))
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Connection", "close")
    handler.end_headers()
    handler.close_connection = True
    try:
        if slow:
            chunk = b"x" * SLOW_CHUNK_BYTES
            for _ in range(SLOW_CHUNKS):
                handler.wfile.write(chunk)
                handler.wfile.flush()
                time.sleep(delay)
        elif endpoint == "/downloads/truncated":
            handler.wfile.write(PAYLOAD[:1024])
        else:
            handler.wfile.write(PAYLOAD)
        handler.wfile.flush()
    except (BrokenPipeError, ConnectionResetError):
        # Cancelling a transfer is an expected result in these tests.
        pass
    return True
