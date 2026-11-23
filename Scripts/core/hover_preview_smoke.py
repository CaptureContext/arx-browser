"""Fixture pages for the hover preview phase of the app smoke (DEV-730)."""

import struct
import zlib
from pathlib import Path

MARKERS = ("ARX_HOVER_PREVIEW_SMOKE_SUCCESS",)
DESCRIPTION = "Arx hover preview smoke description"


def png(width: int, height: int, rgb=(40, 110, 220)) -> bytes:
    """A solid-color RGB PNG, built without imaging libraries."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    row = b"\x00" + bytes(rgb) * width
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(row * height))
        + chunk(b"IEND", b"")
    )


def prepare(root: Path):
    """`hover-preview.html` publishes an Open Graph picture and description."""
    (root / "hover-preview.png").write_bytes(png(1200, 630))
    (root / "hover-preview.html").write_text(
        "<!doctype html><html><head><title>Arx hover preview smoke</title>"
        '<meta property="og:title" content="Arx hover preview smoke">'
        f'<meta property="og:description" content="{DESCRIPTION}">'
        '<meta property="og:image" content="hover-preview.png">'
        "</head><body><h1>Hover preview smoke</h1></body></html>"
    )


def verify(stdout: str):
    """The app checks the history itself; `history_smoke` checks the persisted index."""
    if any(marker not in stdout for marker in MARKERS):
        raise ValueError("Hover preview smoke did not complete")
