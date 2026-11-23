"""Owned HTTP search destinations and required Chromium navigation evidence."""

import json
from urllib.parse import parse_qs, unquote, urlsplit

MARKERS = (
    "ARX_BANG_MAIN_SMOKE_SUCCESS",
    "ARX_SITE_SEARCH_MAIN_SMOKE_SUCCESS",
    "ARX_BANG_BUNDLED_SMOKE_SUCCESS",
    "ARX_BANG_LITTLE_SMOKE_SUCCESS",
    "ARX_SITE_SEARCH_LITTLE_SMOKE_SUCCESS",
)


def document(path):
    """Decode requests independently of Swift's shortcut/template implementation."""
    parts = urlsplit(path)
    query = parse_qs(parts.query, keep_blank_values=True)
    identity = None
    if parts.path == "/bang-search/seed" and set(query) == {"identity"}:
        values = query["identity"]
        if len(values) != 1 or values[0] not in ("ordinary", "secondary"):
            return None
        identity = values[0]
        mode, text = "seed", ""
    elif parts.path == "/bang-search/read" and not query:
        mode, text = "read", ""
    elif parts.path == "/bang-search/query" and set(query) == {"q"} and len(query["q"]) == 1:
        mode, text = "query", query["q"][0]
    elif parts.path == "/bang-search/bundled" and set(query) == {"q"} and len(query["q"]) == 1:
        # Reached only through a bundled-list entry, never through a user shortcut.
        mode, text = "bundled", query["q"][0]
    elif parts.path.startswith("/bang-search/path/") and not query:
        segment = parts.path.removeprefix("/bang-search/path/")
        if not segment or "/" in segment:
            return None
        mode, text = "path", unquote(segment, errors="strict")
    else:
        return None

    # JSON values escape HTML delimiters so even malformed fixture input cannot
    # terminate this script. The title combines server decoding with renderer storage.
    payload = json.dumps([mode, text, identity], ensure_ascii=True).replace("<", "\\u003c")
    return f"""<!doctype html>
<meta charset="utf-8">
<title>Arx bang fixture loading</title>
<p>Controlled search and profile-continuity fixture.</p>
<script>
const [mode, query, identity] = {payload};
if (identity !== null) {{
  localStorage.setItem('arx_bang_identity', identity);
  document.cookie = 'arx_bang_identity=' + identity + '; path=/; SameSite=Strict';
}}
const cookie = document.cookie.split('; ').find(value => value.startsWith('arx_bang_identity='));
const saved = localStorage.getItem('arx_bang_identity') || 'empty';
const cookieIdentity = cookie ? cookie.slice('arx_bang_identity='.length) : 'empty';
document.title = ['Arx bang', mode, query, saved, cookieIdentity].join('|');
</script>
""".encode("utf-8")


def serve(handler):
    if not urlsplit(handler.path).path.startswith("/bang-search/"):
        return False
    body = document(handler.path)
    if body is None:
        handler.send_error(400, "Invalid search fixture request")
        return True
    handler.send_response(200)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)
    return True


def verify(stdout):
    lines = set(stdout.splitlines())
    missing = [marker for marker in MARKERS if marker not in lines]
    if missing:
        raise ValueError("Bang navigation smoke did not complete: " + ", ".join(missing))
