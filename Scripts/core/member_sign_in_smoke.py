"""The app smoke's `member-sign-in` phase (DEV-1323): the member number's sign-in window.

Apple's web sign-in ends with a form post from appleid.apple.com to Arx's server, which answers
303 to `dev.capturecontext.arx.auth:/apple?...`. This fixture reproduces that shape without an
Apple account: `member-sign-in.html`, opened on `localhost`, posts a form at once and without a
click to `/member-sign-in/callback` on `127.0.0.1` (another site), which answers 303 to the
sign-in scheme with the error Arx's server sends for a cancel. The app's phase opens the page
through the sign-in window and must get that address back from the window, with the window
closed, its private profile released and no prompt for another app.
"""

MARKERS = ("ARX_MEMBER_SIGN_IN_SMOKE_SUCCESS",)
CALLBACK = "dev.capturecontext.arx.auth:/apple?error=cancelled&state=arx-smoke"

PAGE = """<!doctype html>
<meta charset="utf-8">
<title>Arx member sign-in fixture</title>
<p>Owned sign-in post.</p>
<form method="post">
<input type="hidden" name="error" value="user_cancelled_authorize">
<input type="hidden" name="state" value="arx-smoke">
</form>
<script>
const form = document.forms[0];
form.action = 'http://127.0.0.1:' + location.port + '/member-sign-in/callback';
form.submit();
</script>
"""


def prepare(root):
    (root / "member-sign-in.html").write_text(PAGE)


def serve_post(handler):
    """Answers the fixture's post as Arx's server answers Apple's. False for any other path."""
    if handler.path != "/member-sign-in/callback":
        return False
    handler.rfile.read(int(handler.headers.get("Content-Length", "0")))
    handler.send_response(303)
    handler.send_header("Location", CALLBACK)
    handler.send_header("Content-Length", "0")
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    return True


def verify(stdout):
    if any(marker not in stdout for marker in MARKERS):
        raise ValueError("Arx smoke missed the member sign-in window's answer (DEV-1323)")
