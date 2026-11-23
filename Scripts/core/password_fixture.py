"""A loopback sign-in site for `make password-smoke` (DEV-708).

/password/login posts to /password/session, which checks the fixture account
and redirects to /password/home on success (or /password/code when the login
asks for a second step) and back to the form otherwise. Pages never echo what
was submitted. /password/framed holds the same form in a same-origin frame.
/password/state reports how many sign-ins succeeded or failed, and
/password/rotate changes the account's password so a saved one is refused;
/password/rotate?to=<suffix> sets it to the probe plus that suffix, so the
host can save the new one through Settings (DEV-721) without reading it back.
"""

import json
import secrets
import threading
from urllib.parse import parse_qs, urlsplit

USER = "arx-fixture-user"

FORM = """<!doctype html>
<title>{title}</title>
<form method="post" action="/password/session?next={next}">
<label>Username <input name="username" autocomplete="username"></label>
<label>Password <input name="password" type="password" autocomplete="current-password"></label>
<button type="submit">Sign in</button>
</form>
"""
PAGES = {
    "/password/home": "<!doctype html><title>Arx password home</title><p>Signed in.</p>",
    "/password/code": ("<!doctype html><title>Arx password code</title>"
                       "<label>Code <input name=\"code\" autocomplete=\"one-time-code\"></label>"),
    "/password/framed": ("<!doctype html><title>Arx password framed</title>"
                         "<iframe name=\"login\" width=\"600\" height=\"300\" src=\"/password/login?next=home\"></iframe>"),
    "/password/other": "<!doctype html><title>Arx password other</title><p>Another document.</p>",
}


class State:
    def __init__(self, password):
        self.lock = threading.Lock()
        self.probe = password
        self.password = password
        self.successes = 0
        self.failures = 0


STATE = State(secrets.token_hex(16))


def reset(password):
    global STATE
    STATE = State(password)


def serve(handler):
    """Handle /password/*; return False for anything else."""
    request = urlsplit(handler.path)
    if not request.path.startswith("/password/"):
        return False
    query = parse_qs(request.query)
    if handler.command == "POST" and request.path == "/password/session":
        length = min(int(handler.headers.get("Content-Length") or 0), 4096)
        form = parse_qs(handler.rfile.read(length).decode(errors="replace"))
        accepted = (form.get("username") == [USER]
                    and form.get("password") == [STATE.password])
        with STATE.lock:
            if accepted:
                STATE.successes += 1
            else:
                STATE.failures += 1
        destination = "/password/login?next=home&error=1"
        if accepted:
            destination = "/password/code" if query.get("next") == ["code"] else "/password/home"
        handler.send_response(303)
        handler.send_header("Location", destination)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True
    if handler.command == "POST" and request.path == "/password/rotate":
        suffix = query.get("to", [""])[0]
        with STATE.lock:
            STATE.password = (STATE.probe + suffix if suffix.isalnum() and len(suffix) <= 32
                              else secrets.token_hex(16))
        return respond(handler, b'{"ok":true}', "application/json")
    if request.path == "/password/state":
        with STATE.lock:
            body = json.dumps({"successes": STATE.successes, "failures": STATE.failures})
        return respond(handler, body.encode(), "application/json")
    if request.path == "/password/login":
        next_page = "code" if query.get("next") == ["code"] else "home"
        title = "Arx password retry" if query.get("error") else "Arx password login"
        return respond(handler, FORM.format(title=title, next=next_page).encode(), "text/html; charset=utf-8")
    page = PAGES.get(request.path)
    if page is None:
        handler.send_error(404)
        return True
    return respond(handler, page.encode(), "text/html; charset=utf-8")


def respond(handler, body, content_type):
    handler.send_response(200)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)
    return True
