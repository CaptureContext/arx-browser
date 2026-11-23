"""Developer-tier endpoints for the app smoke's MCP phase (DEV-668).

/developer/page sets a script-readable and an HttpOnly cookie, echoes the
HttpOnly value into the DOM (as a careless site might), fills a password
field from the page's own script, logs a console message carrying the
readable cookie and fetches /developer/api with a token in the query. A
script in Arx's developer world must read none of the cookies or the
password, and the console and network logs must show neither cookie value
nor the token.
"""

from urllib.parse import urlsplit

VISIBLE_COOKIE = "arx-visible-cookie-value-5d1c"
HIDDEN_COOKIE = "arx-hidden-cookie-value-9b7e"
PASSWORD = "arx-fixture-password-4f2a"
TOKEN = "arx-fixture-token-8c3d"
TITLE = "Arx developer"
CONSOLE_MARKER = "arx-developer-console"

PAGE = f"""<!doctype html>
<title>{TITLE}</title>
<body data-echo="{HIDDEN_COOKIE}">
<form id="login" action="/developer/api" method="post">
<input id="user" name="user" value="fixture-user">
<input id="password" name="password" type="password" autocomplete="current-password">
<input id="card" name="card" autocomplete="cc-number">
</form>
<script>
window.arxPageSecret = "main-world-only";
document.querySelector("#password").value = "{PASSWORD}";
document.querySelector("#card").value = "4111111111111111";
console.error("{CONSOLE_MARKER} " + document.cookie);
fetch("/developer/api?token={TOKEN}&page=2").then(response => response.text());
</script>
</body>
"""


def serve(handler):
    """Handle /developer/page and /developer/api; return False otherwise."""
    endpoint = urlsplit(handler.path).path
    if endpoint not in {"/developer/page", "/developer/api"}:
        return False
    if endpoint == "/developer/page":
        body = PAGE.encode()
        content_type = "text/html; charset=utf-8"
    else:
        body = b'{"ok":true}'
        content_type = "application/json"
    handler.send_response(200)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    if endpoint == "/developer/page":
        handler.send_header("Set-Cookie", f"arx_visible={VISIBLE_COOKIE}; Path=/")
        handler.send_header("Set-Cookie", f"arx_hidden={HIDDEN_COOKIE}; Path=/; HttpOnly")
    handler.end_headers()
    handler.wfile.write(body)
    return True


def environment():
    """Values the app's smoke phase checks against."""
    return {
        "ARX_DEVELOPER_SMOKE_SECRETS": ",".join([VISIBLE_COOKIE, HIDDEN_COOKIE, PASSWORD, TOKEN]),
    }
