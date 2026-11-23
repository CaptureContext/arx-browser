"""Exercise `Arx --headless` end to end against a loopback fixture.

The run opens a page through the bundled MCP helper, reads it, captures it, and
stops cleanly. A second run kills its renderer and meets HTTP authentication
challenges and sign-in prompts: main-frame, subframe and subresource challenges
are cancelled (`authenticationRequired`), WebAuthn and FedCM requests are refused
(`userActionRequired`), pages never hang, and waits and page operations fail with
userActionRequired. WindowServer must never list a non-transparent window of either run.
It also checks the timeout, concurrent-profile and usage contracts.
Only disposable storage is used; the user's browser profile is never touched.
"""

import base64
import ctypes
import ctypes.util
import http.server
import json
import os
import selectors
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

from . import build_app
from .core import smoke
from .engine.config import WORK

TITLE = "Arx headless fixture"
PAGE = f"""<!doctype html><html><head><title>{TITLE}</title>
<style>html,body{{margin:0;height:100%;background:rgb(12,140,233)}}</style></head>
<body><main><h1>Headless fixture</h1><p>Rendered by Chromium without a visible window.</p>
<script>alert("unattended dialogs never block")</script></main></body></html>"""


AUTH_PAGE = "<!doctype html><title>Arx auth required</title><p>401</p>"
# DEV-949: a click anywhere asks for full screen; the title says how it settled.
# A headless run has no screen to fill, so the request must fail at once.
FULL_SCREEN_PAGE = """<!doctype html><title>Arx full screen pending</title>
<style>html,body,button{margin:0;width:100%;height:100%}</style>
<button id="go" type="button">Full screen</button><script>
const settle = name => { document.title = `Arx full screen settled:${name}`; };
document.querySelector('#go').addEventListener('click', () =>
  document.documentElement.requestFullscreen().then(() => settle('granted'), error => settle(error.name)));
</script>"""
# DEV-927: a click starts a site's Cast request, as Google's Cast SDK does. A headless
# run has no Media Router, so it must fail at once ("No screens found") with nothing
# found on the network; the title says how it settled and what availability said.
CAST_PAGE = """<!doctype html><title>Arx cast pending</title>
<style>html,body,button{margin:0;width:100%;height:100%}</style>
<button id="go" type="button">Cast</button><script>
const settle = name => { document.title = `Arx cast settled:${name}`; };
document.querySelector('#go').addEventListener('click', () => {
  const request = new PresentationRequest(['cast:CC1AD845']);
  const availability = request.getAvailability().then(found => String(found.value), error => error.name);
  request.start().then(() => settle('started'),
                       error => availability.then(found => settle(`${error.name}/${found}`)));
});
</script>"""
PAGES = {
    "/full-screen": FULL_SCREEN_PAGE,
    # DEV-905: a click asks for every kind of device; nobody can choose one, so each request
    # must be cancelled at once instead of waiting for a chooser nobody sees.
    "/devices": """<!doctype html><title>Arx devices ready</title>
<button style="width:400px;height:200px" aria-label="Request devices" onclick="request()">Request devices</button><script>
function request() {
  const requests = [
    navigator.serial && navigator.serial.requestPort(),
    navigator.usb && navigator.usb.requestDevice({filters: []}),
    navigator.hid && navigator.hid.requestDevice({filters: []}),
    navigator.bluetooth && navigator.bluetooth.requestDevice({acceptAllDevices: true}),
  ].filter(Boolean);
  document.title = 'Arx devices pending';
  Promise.allSettled(requests).then(results => {
    document.title = 'Arx devices settled:' + results.map(r => r.status === 'fulfilled' ? 'resolved' : r.reason.name).join(',');
  });
}
</script>""",
    "/cast": CAST_PAGE,
    "/auth-frame": "<!doctype html><title>Arx auth frame</title><iframe src=\"/auth\"></iframe>",
    "/auth-image": "<!doctype html><title>Arx auth image</title><img src=\"/auth-resource\">",
}

# Sign-in prompts nobody can answer. Each page reports how its request settled
# in its title; a hidden dialog would leave it pending until the deadline.
SIGN_IN_SCRIPT = """<!doctype html><title>Arx sign-in pending</title><script>
const settle = name => {{ document.title = `Arx sign-in settled:${{name}}`; }};
const bytes = text => new TextEncoder().encode(text);
{request}.then(() => settle('resolved'), error => settle(error.name));
</script>"""
SIGN_IN_PAGES = {
    "/webauthn-get": SIGN_IN_SCRIPT.format(request="""navigator.credentials.get({publicKey: {
  challenge: bytes('arx-headless-challenge'), timeout: 120000, userVerification: 'preferred'}})"""),
    "/webauthn-create": SIGN_IN_SCRIPT.format(request="""navigator.credentials.create({publicKey: {
  challenge: bytes('arx-headless-challenge'), rp: {name: 'Arx headless'},
  user: {id: bytes('arx'), name: 'arx@example.invalid', displayName: 'Arx'},
  pubKeyCredParams: [{type: 'public-key', alg: -7}], timeout: 120000}})"""),
    "/fedcm": SIGN_IN_SCRIPT.format(request="""navigator.credentials.get({identity: {providers: [{
  configURL: `${location.origin}/fedcm/config.json`, clientId: 'arx-headless'}]}})"""),
}
# A loopback identity provider with one signed-in account, so a FedCM request
# gets as far as its account chooser.
FEDCM = {
    "/.well-known/web-identity": {"provider_urls": ["{origin}/fedcm/config.json"]},
    "/fedcm/config.json": {
        "accounts_endpoint": "/fedcm/accounts", "client_metadata_endpoint": "/fedcm/metadata",
        "id_assertion_endpoint": "/fedcm/assertion", "login_url": "/fedcm/login",
    },
    "/fedcm/accounts": {"accounts": [{
        "id": "arx", "name": "Arx Headless", "email": "arx@example.invalid", "given_name": "Arx",
        "approved_clients": [],
    }]},
    "/fedcm/metadata": {"privacy_policy_url": "/", "terms_of_service_url": "/"},
}


class Fixture(http.server.BaseHTTPRequestHandler):
    credentials = []  # Authorization headers received; an unattended run must never send one.

    def do_GET(self):
        if self.headers.get("Authorization"):
            Fixture.credentials.append(self.path)
        if self.path in ("/auth", "/auth-resource"):
            # Main-frame and same-origin subresource HTTP authentication challenges.
            return self.reply(401, AUTH_PAGE, {"WWW-Authenticate": 'Basic realm="arx-headless"'})
        if self.path in FEDCM:
            origin = f"http://{self.headers.get('Host')}"
            body = json.dumps(FEDCM[self.path]).replace("{origin}", origin)
            return self.reply(200, body, {"Set-Login": "logged-in"}, content_type="application/json")
        if self.path in SIGN_IN_PAGES:
            return self.reply(200, SIGN_IN_PAGES[self.path], {"Set-Login": "logged-in"})
        self.reply(200, PAGES.get(self.path, PAGE))

    def reply(self, status, page, headers=None, content_type="text/html; charset=utf-8"):
        body = page.encode()
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class Run:
    """One headless Arx process. stdout carries only JSON event lines."""

    def __init__(self, app, log, *arguments):
        self.events = []
        # The checks look for the JSON workspace: SQLite is on by default (DEV-1143).
        self.process = subprocess.Popen(
            [str(app / "Contents/MacOS/Arx"), "--headless", *arguments],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log, start_new_session=True,
            env=dict(os.environ, ARX_SQLITE_WORKSPACE="0"),
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""

    def next_event(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise ValueError("Headless run produced no event before its deadline")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise ValueError("Headless run closed stdout: " + json.dumps(self.events))
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        event = json.loads(line)  # Anything but JSON on stdout fails the contract.
        self.events.append(event)
        return event

    def wait_for(self, name, timeout=60):
        """The first `name` event within `timeout` seconds in all; diagnostics don't extend it."""
        deadline = time.monotonic() + timeout
        while True:
            try:
                event = self.next_event(max(deadline - time.monotonic(), 0))
            except ValueError as error:
                slow = [event for event in self.events if event.get("code") == "startupSlow"]
                raise ValueError(f"{error}; waiting for {name}, startup reports {json.dumps(slow)}") from None
            if event["event"] == name:
                return event
            if event["event"] == "error":
                raise ValueError("Headless run failed: " + json.dumps(event))

    def finish(self, timeout=60):
        try:
            code = self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            raise ValueError("Headless run did not exit")
        rest = self.process.stdout.read()
        for line in rest.splitlines():
            self.events.append(json.loads(line))
        return code


class InventoryError(ValueError):
    """browser_inventory returned an error result, such as a transient busy state."""


class Client:
    """Minimal newline-delimited JSON-RPC client for the bundled ArxMCP helper."""

    def __init__(self, configuration):
        server = json.loads(Path(configuration).read_text())["mcpServers"]["arx"]
        self.process = subprocess.Popen(
            [server["command"]], env=server["env"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self.next_id = 0
        self.request("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "arx-headless-smoke", "version": "1"},
        })
        self.notify("notifications/initialized")

    def notify(self, method):
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}).encode() + b"\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise ValueError(f"MCP helper closed during {method}")
            reply = json.loads(line)
            if reply.get("id") == self.next_id:
                if "error" in reply:
                    raise ValueError(f"MCP {method} failed: {reply['error']}")
                return reply["result"]

    def call(self, tool, arguments):
        result = self.request("tools/call", {"name": tool, "arguments": arguments})
        return result, result.get("structuredContent", {}).get("result")

    def inventory(self):
        _, inventory = self.call("browser_inventory", {"limit": 100})
        if "items" not in inventory:
            raise InventoryError(json.dumps(inventory))
        return inventory["items"]

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)


class Windows:
    """On-screen windows from WindowServer. Owner PIDs and alpha need no Screen Recording permission."""

    def __init__(self):
        self.cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
        self.cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        pointer = ctypes.c_void_p
        for function, result, arguments in [
            (self.cg.CGWindowListCopyWindowInfo, pointer, [ctypes.c_uint32, ctypes.c_uint32]),
            (self.cf.CFArrayGetCount, ctypes.c_long, [pointer]),
            (self.cf.CFArrayGetValueAtIndex, pointer, [pointer, ctypes.c_long]),
            (self.cf.CFDictionaryGetValue, pointer, [pointer, pointer]),
            (self.cf.CFStringCreateWithCString, pointer, [pointer, ctypes.c_char_p, ctypes.c_uint32]),
            (self.cf.CFNumberGetValue, ctypes.c_bool, [pointer, ctypes.c_int, pointer]),
            (self.cf.CFRelease, None, [pointer]),
        ]:
            function.restype, function.argtypes = result, arguments
        self.keys = {name: self.cf.CFStringCreateWithCString(None, name.encode(), 0x08000100)
                     for name in ("kCGWindowOwnerPID", "kCGWindowAlpha")}

    def number(self, dictionary, key, kind, code):
        value, result = self.cf.CFDictionaryGetValue(dictionary, self.keys[key]), kind()
        if value:
            self.cf.CFNumberGetValue(value, code, ctypes.byref(result))
        return result.value

    def visible(self, pids):
        """(owner PID, alpha) of every on-screen window of `pids` that is not fully transparent."""
        info = self.cg.CGWindowListCopyWindowInfo(1, 0)  # kCGWindowListOptionOnScreenOnly
        if not info:
            raise ValueError("WindowServer returned no window list")
        try:
            windows = []
            for index in range(self.cf.CFArrayGetCount(info)):
                window = self.cf.CFArrayGetValueAtIndex(info, index)
                pid = self.number(window, "kCGWindowOwnerPID", ctypes.c_int64, 4)  # kCFNumberSInt64Type
                alpha = self.number(window, "kCGWindowAlpha", ctypes.c_double, 13)  # kCFNumberDoubleType
                if pid in pids and alpha > 0:
                    windows.append((pid, alpha))
            return windows
        finally:
            self.cf.CFRelease(info)

    def expect_none(self, run, moment):
        pids = {run.process.pid, *descendants(run.process.pid)}
        if shown := self.visible(pids):
            raise ValueError(f"Arx showed a window {moment}: {shown}")


def png_size(data):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Capture is not a PNG")
    return struct.unpack(">II", data[16:24])


def descendants(pid):
    result = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True)
    children = [int(value) for value in result.stdout.split()]
    return children + [grandchild for child in children for grandchild in descendants(child)]


def verify_hosts_unsupported(client, space_id, tab_id, url):
    """Unattended runs have no visible window, so Peek and Little Arx must refuse explicitly."""
    for action, target in (("openLittleArx", space_id), ("openPeek", tab_id)):
        items = {item["id"]: item for item in client.inventory()}
        request = {
            "operationID": str(uuid.uuid4()), "action": action, "targetID": target,
            "expectedRevision": items[target]["revision"], "url": url, "focus": True,
        }
        if action == "openPeek":
            request.update(sourceTabID=tab_id, sourceRevision=items[tab_id]["revision"])
        result, reply = client.call("browser_command", request)
        if not result.get("isError") or reply != {"kind": "error", "code": "unsupported"}:
            raise ValueError(f"{action} was not refused as unsupported: {json.dumps(reply)}")
    _, inventory = client.call("browser_inventory", {"limit": 100})
    if inventory.get("presentations") != []:
        raise ValueError("Headless inventory advertised a presentation")


def exercise(app, log, url, viewport):
    run = Run(app, log, "--viewport", f"{viewport[0]}x{viewport[1]}", "--allow", "read,screenshots,content,manage",
              "--timeout", "180")
    ready = run.wait_for("ready")
    configuration = Path(ready["configuration"])
    if configuration.stat().st_mode & 0o077:
        raise ValueError("MCP configuration is readable by other users")
    run_directory = configuration.parent
    helpers = descendants(run.process.pid)
    client = Client(configuration)
    try:
        items = client.inventory()
        space = next(item for item in items if item["kind"] == "space")
        result, command = client.call("browser_command", {
            "operationID": str(uuid.uuid4()), "action": "openTab", "targetID": space["id"],
            "expectedRevision": space["revision"], "url": url, "focus": True,
        })
        if result.get("isError") or command.get("kind") == "error":
            raise ValueError("openTab failed: " + json.dumps(result.get("structuredContent")))
        tab_id = command["targetID"]
        deadline = time.monotonic() + 30
        while True:
            tab = next(item for item in client.inventory() if item["id"] == tab_id)
            if tab.get("title") == TITLE and tab.get("sessionState") == "ready":
                _, waited = client.call("browser_wait", {
                    "targetID": tab_id, "expectedRevision": tab["revision"], "condition": "loadingStopped",
                    "timeoutMilliseconds": 5000,
                })
                if waited.get("kind") == "wait":
                    break
            if time.monotonic() > deadline:
                raise ValueError("Fixture page did not load: " + json.dumps(tab))
            time.sleep(0.25)

        tab = next(item for item in client.inventory() if item["id"] == tab_id)
        _, snapshot = client.call("browser_inspect", {"targetID": tab_id, "expectedRevision": tab["revision"]})
        text = json.dumps(snapshot)
        if snapshot.get("kind") != "inspection" or "Headless fixture" not in text:
            raise ValueError("Inspection did not read the fixture: " + text[:400])

        for _ in range(40):
            tab = next(item for item in client.inventory() if item["id"] == tab_id)
            result, capture = client.call("browser_capture", {
                "targetID": tab_id, "expectedRevision": tab["revision"], "mode": "viewport",
            })
            if capture.get("kind") == "capture" and (capture.get("viewportWidth"), capture.get("viewportHeight")) == viewport:
                break
            time.sleep(0.25)
        if capture.get("kind") != "capture":
            raise ValueError("Capture failed: " + json.dumps(capture))
        image = next(item for item in result["content"] if item["type"] == "image")
        width, height = png_size(base64.b64decode(image["data"]))
        scale = capture["deviceScale"]
        expected = (round(viewport[0] * scale), round(viewport[1] * scale))
        if (capture["viewportWidth"], capture["viewportHeight"]) != viewport or (width, height) != expected \
                or (capture["width"], capture["height"]) != (width, height):
            raise ValueError(f"Viewport {capture} produced {width}x{height}, expected {expected}")
        # DEV-865: the scale is fixed at startup, the main screen's or 2 without one.
        if scale != ready.get("deviceScale"):
            raise ValueError(f"Capture scale {scale} is not the run's deviceScale {ready.get('deviceScale')}")
        log.write(f"ARX_HEADLESS_CAPTURE {width}x{height} scale={scale}\n")
        verify_hosts_unsupported(client, space["id"], tab_id, url)
        Windows().expect_none(run, "while capturing")
    finally:
        client.close()

    os.kill(run.process.pid, signal.SIGTERM)
    code = run.finish()
    stopped = run.events[-1]
    if code != 0 or stopped["event"] != "stopped" or stopped["exitCode"] != 0:
        raise ValueError(f"Headless run exited {code}: {json.dumps(run.events)}")
    if stopped.get("suppressedDialogs", 0) < 1:
        raise ValueError("The fixture alert was not suppressed")
    if run_directory.exists():
        raise ValueError("Isolated run directory was not removed")
    time.sleep(1)
    orphans = [pid for pid in helpers if subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode == 0]
    if orphans:
        raise ValueError(f"Chromium helpers outlived the run: {orphans}")


def open_tab(client, url):
    space = next(item for item in client.inventory() if item["kind"] == "space")
    result, command = client.call("browser_command", {
        "operationID": str(uuid.uuid4()), "action": "openTab", "targetID": space["id"],
        "expectedRevision": space["revision"], "url": url, "focus": True,
    })
    if result.get("isError") or command.get("kind") == "error":
        raise ValueError("openTab failed: " + json.dumps(result.get("structuredContent")))
    return command["targetID"]


def settle(client, tab_id, title=None, seconds=15):
    """The tab once it stops loading (showing `title`, if given), or its last state at the deadline."""
    deadline = time.monotonic() + seconds
    while True:
        try:
            tab = next(item for item in client.inventory() if item["id"] == tab_id)
        except InventoryError:
            if time.monotonic() > deadline:
                raise
            time.sleep(0.25)
            continue
        settled = tab.get("sessionState") != "loading" and title in (None, tab.get("title"))
        if settled or time.monotonic() > deadline:
            return tab
        time.sleep(0.25)


def wait(client, tab):
    _, waited = client.call("browser_wait", {
        "targetID": tab["id"], "expectedRevision": tab["revision"], "condition": "loadingStopped",
        "timeoutMilliseconds": 5000,
    })
    return waited


def kill_renderers(pid):
    killed = []
    for candidate in subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split():
        details = subprocess.run(["ps", "-p", candidate, "-o", "ppid=,args="], capture_output=True,
                                 text=True).stdout.strip().split(maxsplit=1)
        if len(details) == 2 and details[0] == str(pid) and "--type=renderer" in details[1]:
            try:
                os.kill(int(candidate), signal.SIGKILL)
                killed.append(int(candidate))
            except ProcessLookupError:
                pass
    return killed


def full_screen_refused(app, log, base):
    """A page's full-screen request, from a real click with user activation, fails promptly in a
    headless run and opens nothing (DEV-949). Picture in Picture has no MCP route: Page PiP and a
    site's own Document PiP (DEV-948, DEV-950) are unavailable without windows. A site's Cast
    request fails in the same run (DEV-927)."""
    windows = Windows()
    run = Run(app, log, "--allow", "read,content,interaction,manage", "--timeout", "120")
    ready = run.wait_for("ready")
    client = Client(ready["configuration"])
    try:
        tab_id = open_tab(client, base + "full-screen")
        tab = settle(client, tab_id, "Arx full screen pending")
        _, snapshot = client.call("browser_inspect", {"targetID": tab_id, "expectedRevision": tab["revision"]})
        if snapshot.get("kind") != "inspection" or "snapshotID" not in snapshot:
            raise ValueError("Inspection of the full-screen page failed: " + json.dumps(snapshot)[:400])
        tab = next(item for item in client.inventory() if item["id"] == tab_id)
        _, clicked = client.call("browser_click", {
            "operationID": str(uuid.uuid4()), "targetID": tab_id, "expectedRevision": tab["revision"],
            "snapshotID": snapshot["snapshotID"], "x": 100, "y": 100,
        })
        deadline = time.monotonic() + 15
        title = ""
        while time.monotonic() < deadline:
            title = settle(client, tab_id, seconds=1).get("title") or ""
            if title.startswith("Arx full screen settled:"):
                break
            time.sleep(0.25)
        log.write(f"ARX_HEADLESS_FULL_SCREEN title={title!r} click={json.dumps(clicked)}\n")
        if not title.startswith("Arx full screen settled:"):
            raise ValueError("The full-screen request was left pending: " + json.dumps(clicked))
        if title == "Arx full screen settled:granted":
            raise ValueError("A headless run granted page full screen")
        windows.expect_none(run, "after a full-screen request")
        cast_refused(client, run, windows, base, log)
    finally:
        client.close()

    os.kill(run.process.pid, signal.SIGTERM)
    if run.finish() != 0 or run.events[-1]["event"] != "stopped":
        raise ValueError("Full-screen run did not stop cleanly: " + json.dumps(run.events))


def cast_refused(client, run, windows, base, log):
    """A site's Cast request, from a real click, fails at once in a headless run, and finds no
    device: the engine runs without the Media Router (DEV-927)."""
    tab_id = open_tab(client, base + "cast")
    tab = settle(client, tab_id, "Arx cast pending")
    _, snapshot = client.call("browser_inspect", {"targetID": tab_id, "expectedRevision": tab["revision"]})
    if snapshot.get("kind") != "inspection" or "snapshotID" not in snapshot:
        raise ValueError("Inspection of the Cast page failed: " + json.dumps(snapshot)[:400])
    tab = next(item for item in client.inventory() if item["id"] == tab_id)
    started = time.monotonic()
    _, clicked = client.call("browser_click", {
        "operationID": str(uuid.uuid4()), "targetID": tab_id, "expectedRevision": tab["revision"],
        "snapshotID": snapshot["snapshotID"], "x": 100, "y": 100,
    })
    deadline = time.monotonic() + 15
    title = ""
    while time.monotonic() < deadline:
        title = settle(client, tab_id, seconds=1).get("title") or ""
        if title.startswith("Arx cast settled:"):
            break
        time.sleep(0.25)
    elapsed = time.monotonic() - started
    log.write(f"ARX_HEADLESS_CAST title={title!r} seconds={elapsed:.1f} click={json.dumps(clicked)}\n")
    if not title.startswith("Arx cast settled:"):
        raise ValueError("The Cast request was left pending: " + json.dumps(clicked))
    if title != "Arx cast settled:NotFoundError/false":
        raise ValueError(f"A headless run's Cast request didn't fail with no screens and none found: {title!r}")
    windows.expect_none(run, "after a Cast request")


def unattended_failures(app, log, base):
    """Renderer death and HTTP authentication in a run nobody can answer."""
    windows = Windows()
    run = Run(app, log, "--allow", "read,screenshots,content,manage", "--timeout", "180")
    ready = run.wait_for("ready")
    windows.expect_none(run, "at startup")
    client = Client(ready["configuration"])
    try:
        tab_id = open_tab(client, base)
        tab = settle(client, tab_id, TITLE)
        if tab.get("sessionState") != "ready":
            raise ValueError("Fixture page did not load: " + json.dumps(tab))
        if not kill_renderers(run.process.pid):
            raise ValueError("No renderer process to terminate")
        failed = run.wait_for("rendererFailed", timeout=15)
        reported = {failed["tabID"]}
        while tab_id.upper() not in reported:
            reported.add(run.wait_for("rendererFailed", timeout=15)["tabID"])
        tab = settle(client, tab_id, TITLE, seconds=5)
        waited = wait(client, tab)
        log.write(f"ARX_HEADLESS_RENDERER inventory={tab.get('sessionState')} wait={json.dumps(waited)}\n")
        if tab.get("sessionState") != "failed":
            raise ValueError("Inventory did not report the renderer failure: " + json.dumps(tab))
        if waited.get("kind") != "wait" or waited.get("errorCode") != -10000:
            raise ValueError("browser_wait did not report the renderer failure: " + json.dumps(waited))
        windows.expect_none(run, "after a renderer failure")

        result, command = client.call("browser_command", {
            "operationID": str(uuid.uuid4()), "action": "reload", "targetID": tab_id,
            "expectedRevision": tab["revision"],
        })
        if result.get("isError") or command.get("kind") == "error":
            raise ValueError("reload failed: " + json.dumps(result.get("structuredContent")))
        deadline = time.monotonic() + 15
        while (tab := settle(client, tab_id, TITLE, seconds=1)).get("sessionState") != "ready":
            if time.monotonic() > deadline:
                raise ValueError("Reload did not recover the renderer: " + json.dumps(tab))

        # Every challenge is cancelled natively instead of building a hidden
        # prompt: the page stops loading promptly, stdout gets
        # `authenticationRequired`, and wait/page operations fail with
        # userActionRequired. A main-frame challenge commits the server's 401 body.
        for path in ["auth", "auth-frame", "auth-image"]:
            started = time.monotonic()
            tab_id = open_tab(client, base + path)
            tab = settle(client, tab_id, seconds=10)
            waited = wait(client, tab)
            elapsed = time.monotonic() - started
            _, inspected = client.call("browser_inspect", {"targetID": tab["id"], "expectedRevision": tab["revision"]})
            log.write(f"ARX_HEADLESS_AUTH {path} inventory={tab.get('sessionState')} wait={json.dumps(waited)} "
                      f"inspect={json.dumps(inspected)} seconds={elapsed:.1f}\n")
            if tab.get("sessionState") == "loading" or elapsed > 10:
                raise ValueError(f"/{path} kept loading after its authentication challenge: " + json.dumps(tab))
            for name, result in [("browser_wait", waited), ("browser_inspect", inspected)]:
                if result.get("kind") != "error" or result.get("code") != "userActionRequired":
                    raise ValueError(f"{name} on /{path} did not require user action: " + json.dumps(result))
            required = run.wait_for("authenticationRequired", timeout=15)
            if required["tabID"].upper() != tab_id.upper():
                raise ValueError(f"authenticationRequired named another tab: {json.dumps(required)}")
            windows.expect_none(run, f"for HTTP authentication on /{path}")
        if Fixture.credentials:
            raise ValueError(f"Credentials were sent without a person: {Fixture.credentials}")

        sign_in_prompts(client, run, windows, localhost(base), log)
    finally:
        client.close()

    os.kill(run.process.pid, signal.SIGTERM)
    if run.finish() != 0 or run.events[-1]["event"] != "stopped":
        raise ValueError("Run with failures did not stop cleanly: " + json.dumps(run.events))
    log.write("ARX_HEADLESS_EVENTS " + json.dumps(run.events) + "\n")


def localhost(base):
    """WebAuthn and FedCM refuse IP-address origins; localhost is a secure context."""
    return base.replace("://127.0.0.1:", "://localhost:")


def sign_in_prompts(client, run, windows, base, log):
    """WebAuthn and FedCM requests settle promptly and need a person."""
    for path, prompt in [("webauthn-get", "webAuthentication"), ("webauthn-create", "webAuthentication"),
                         ("fedcm", "federatedSignIn")]:
        started = time.monotonic()
        tab_id = open_tab(client, base + path)
        tab = settle(client, tab_id, seconds=15)
        deadline = time.monotonic() + 15
        while not (tab.get("title") or "").startswith("Arx sign-in settled:") and time.monotonic() < deadline:
            time.sleep(0.25)
            tab = settle(client, tab_id, seconds=1)
        elapsed = time.monotonic() - started
        waited = wait(client, tab)
        _, inspected = client.call("browser_inspect", {"targetID": tab["id"], "expectedRevision": tab["revision"]})
        log.write(f"ARX_HEADLESS_SIGN_IN {path} title={tab.get('title')!r} wait={json.dumps(waited)} "
                      f"inspect={json.dumps(inspected)} seconds={elapsed:.1f}\n")
        if not (tab.get("title") or "").startswith("Arx sign-in settled:") or elapsed > 30:
            raise ValueError(f"/{path} left its sign-in request pending: " + json.dumps(tab))
        if tab.get("title") == "Arx sign-in settled:resolved":
            raise ValueError(f"/{path} signed in without a person: " + json.dumps(tab))
        for name, result in [("browser_wait", waited), ("browser_inspect", inspected)]:
            if result.get("kind") != "error" or result.get("code") != "userActionRequired":
                raise ValueError(f"{name} on /{path} did not require user action: " + json.dumps(result))
        required = run.wait_for("userActionRequired", timeout=15)
        if required["tabID"].upper() != tab_id.upper() or prompt not in required.get("prompts", []):
            raise ValueError(f"userActionRequired did not name /{path}: {json.dumps(required)}")
        windows.expect_none(run, f"for the sign-in prompt on /{path}")


def device_requests(app, log, base):
    """WebUSB, WebHID, Web Serial and Web Bluetooth requests are cancelled at once (DEV-905).

    The click needs the interaction grant; the requests need the click's user activation.
    """
    windows = Windows()
    run = Run(app, log, "--allow", "read,content,interaction,manage", "--timeout", "120")
    ready = run.wait_for("ready")
    client = Client(ready["configuration"])
    try:
        device_requests_in(client, run, windows, base, log)
    finally:
        client.close()
    os.kill(run.process.pid, signal.SIGTERM)
    if run.finish() != 0 or run.events[-1]["event"] != "stopped":
        raise ValueError("Run with device requests did not stop cleanly: " + json.dumps(run.events))


def device_requests_in(client, run, windows, base, log):
    tab_id = open_tab(client, base + "devices")
    tab = settle(client, tab_id, "Arx devices ready")
    _, snapshot = client.call("browser_inspect", {"targetID": tab_id, "expectedRevision": tab["revision"]})
    button = next((node for node in (snapshot or {}).get("nodes", []) if node.get("name") == "Request devices"), None)
    if (snapshot or {}).get("kind") != "inspection" or not button or not button.get("reference"):
        raise ValueError("The devices fixture has no button to click: " + json.dumps(snapshot)[:400])
    started = time.monotonic()
    result, clicked = client.call("browser_click", {
        "operationID": str(uuid.uuid4()), "targetID": tab_id, "expectedRevision": tab["revision"],
        "snapshotID": snapshot["snapshotID"], "reference": button["reference"],
    })
    if result.get("isError") or (clicked or {}).get("kind") == "error":
        raise ValueError("Clicking the devices fixture failed: " + json.dumps(result.get("structuredContent")))
    deadline = time.monotonic() + 10
    while not ((tab := settle(client, tab_id, seconds=1)).get("title") or "").startswith("Arx devices settled:"):
        if time.monotonic() > deadline:
            raise ValueError("A device request was left pending: " + json.dumps(tab))
        time.sleep(0.25)
    title = tab.get("title") or ""
    log.write(f"ARX_HEADLESS_DEVICES title={title!r} seconds={time.monotonic() - started:.1f}\n")
    if "resolved" in title:
        raise ValueError("A device request was granted without a person: " + title)
    windows.expect_none(run, "for the device requests")


def contracts(app, log, url):
    profile = Path(tempfile.mkdtemp(prefix="headless-profile-", dir=WORK)).resolve()
    first = Run(app, log, "--profile", str(profile), "--allow", "read,manage", "--timeout", "120")
    ready = first.wait_for("ready")
    second = Run(app, log, "--profile", str(profile), "--timeout", "30")
    if second.finish() != 73 or second.events[-1].get("code") != "profileInUse":
        raise ValueError("A second run used a locked profile: " + json.dumps(second.events))
    # A tab opened just before the stop is saved: the stop flushes the coalesced workspace save.
    client = Client(Path(ready["configuration"]))
    try:
        opened = open_tab(client, url)
    finally:
        client.close()
    first.process.send_signal(signal.SIGINT)
    if first.finish() != 0:
        raise ValueError("Persistent run did not stop cleanly: " + json.dumps(first.events))
    if not (profile / "arx-workspace.json").exists():
        raise ValueError("Persistent profile was not kept")
    reopened = Run(app, log, "--profile", str(profile), "--timeout", "60")
    ready = reopened.wait_for("ready")
    client = Client(Path(ready["configuration"]))
    try:
        restored = any(item["id"] == opened for item in client.inventory())
    finally:
        client.close()
    reopened.process.send_signal(signal.SIGTERM)
    if reopened.finish() != 0:
        raise ValueError("Reopened persistent run did not stop cleanly: " + json.dumps(reopened.events))
    if not restored:
        raise ValueError("A tab opened just before the stop was not saved")

    timed = Run(app, log, "--timeout", "10")
    timed.wait_for("ready")
    if timed.finish(timeout=60) != 75 or not any(event.get("code") == "timedOut" for event in timed.events):
        raise ValueError("Timeout did not stop the run: " + json.dumps(timed.events))

    usage = Run(app, log, "--viewport", "12x12")
    if usage.finish() != 64 or usage.events[-1].get("code") != "usage":
        raise ValueError("Invalid options were accepted: " + json.dumps(usage.events))


GRANT_WINDOW = 3  # Test-only temporary grant window; the interactive one is 15 minutes.


class LongRun(Run):
    """A run without --timeout, with a shortened temporary grant window."""

    def __init__(self, app, log, *arguments, stdin=subprocess.DEVNULL):
        self.events = []
        self.process = subprocess.Popen(
            [str(app / "Contents/MacOS/Arx"), "--headless", *arguments],
            stdin=stdin, stdout=subprocess.PIPE, stderr=log, start_new_session=True,
            env={**os.environ, "ARX_HEADLESS_GRANT_WINDOW_FOR_TESTING": str(GRANT_WINDOW), "ARX_SQLITE_WORKSPACE": "0"},
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""


def expect_gone(pids, moment):
    deadline = time.monotonic() + 10
    while alive := [pid for pid in pids if subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode == 0]:
        if time.monotonic() > deadline:
            raise ValueError(f"Processes outlived the run {moment}: {alive}")
        time.sleep(0.25)


def expect_stopped(events, reason):
    stopping = [event for event in events if event["event"] == "stopping"]
    stopped = events[-1] if events else {}
    if [event.get("reason") for event in stopping] != [reason] or stopped.get("event") != "stopped" \
            or stopped.get("exitCode") != 0:
        raise ValueError(f"Run did not stop for {reason}: {json.dumps(events)}")


def long_runs(app, log, url):
    """Runs without --timeout last until signalled or until their launcher goes away (DEV-598)."""
    run = LongRun(app, log, "--allow", "read,manage")
    ready = run.wait_for("ready")
    if ready.get("timeoutSeconds", 0) is not None or ready.get("grantsExpireAt", 0) is not None:
        raise ValueError("An unbounded run reported an expiry: " + json.dumps(ready))
    helpers = descendants(run.process.pid)
    client = Client(ready["configuration"])
    try:
        open_tab(client, url)
        # Past the shortened window, a capped grant would fail with userActionRequired.
        time.sleep(GRANT_WINDOW + 2)
        open_tab(client, url)
        log.write(f"ARX_HEADLESS_LONG_RUN mutations accepted past a {GRANT_WINDOW}s window\n")
    finally:
        client.close()
    if run.process.poll() is not None:
        raise ValueError("A run with /dev/null stdin stopped by itself: " + json.dumps(run.events))
    os.kill(run.process.pid, signal.SIGTERM)
    if run.finish() != 0:
        raise ValueError("Unbounded run did not stop on SIGTERM: " + json.dumps(run.events))
    expect_stopped(run.events, "signal")
    expect_gone(helpers, "after SIGTERM")

    # Closing a piped stdin, as a launcher that exits does, stops the run.
    piped = LongRun(app, log, stdin=subprocess.PIPE)
    piped.wait_for("ready")
    helpers = descendants(piped.process.pid)
    piped.process.stdin.write(b"ignored input\n")
    piped.process.stdin.flush()
    time.sleep(1)
    if piped.process.poll() is not None:
        raise ValueError("Input on stdin stopped the run: " + json.dumps(piped.events))
    piped.process.stdin.close()
    if piped.finish(timeout=30) != 0:
        raise ValueError("Run did not stop at stdin EOF: " + json.dumps(piped.events))
    expect_stopped(piped.events, "inputClosed")
    expect_gone(helpers, "after stdin EOF")

    # A launcher that dies without closing anything: Arx's stdin is /dev/null and its
    # stdout a file, so only the parent's exit can end the run.
    events = Path(tempfile.mkstemp(prefix="headless-events-", dir=WORK)[1])
    launcher = subprocess.Popen([sys.executable, "-c", (
        "import os, subprocess, sys, time\n"
        "with open(sys.argv[2], 'wb') as events:\n"
        "    child = subprocess.Popen([sys.argv[1], '--headless'], stdin=subprocess.DEVNULL, stdout=events,\n"
        "                             stderr=sys.stderr, env=dict(os.environ, ARX_HEADLESS_GRANT_WINDOW_FOR_TESTING='3'))\n"
        "print(child.pid, flush=True)\n"
        "time.sleep(600)\n"
    ), str(app / "Contents/MacOS/Arx"), str(events)], stdout=subprocess.PIPE, stderr=log, start_new_session=True)
    try:
        arx = int(launcher.stdout.readline())
        deadline = time.monotonic() + 60
        while '"event":"ready"' not in events.read_text():
            if time.monotonic() > deadline:
                raise ValueError("Launched run never became ready: " + events.read_text())
            time.sleep(0.25)
        helpers = descendants(arx)
        launcher.kill()
        launcher.wait(timeout=10)
        expect_gone([arx, *helpers], "after its launcher exited")
        recorded = [json.loads(line) for line in events.read_text().splitlines()]
        expect_stopped(recorded, "parentExited")
        log.write("ARX_HEADLESS_LAUNCHER_EXIT " + json.dumps(recorded[-2:]) + "\n")
    finally:
        try:
            os.killpg(launcher.pid, signal.SIGKILL)  # Only reaches anything after a failure.
        except ProcessLookupError:
            pass
        launcher.wait(timeout=10)
        events.unlink(missing_ok=True)


def launcher_chain(app, log):
    """An outer launcher exits while the wrapper between it and Arx lives on (DEV-607).

    The outer launcher leads its own session and group, like an agent's npx. The wrapper,
    like npx's node, is Arx's parent and outlives it, and Arx's stdin is /dev/null, so
    only the group and session leader watch can end the run. Like node, the wrapper reaps
    Arx and reports its exit status; an unreaped Arx would stay a zombie that `kill -0`
    still finds while its wrapper lives.
    """
    events = Path(tempfile.mkstemp(prefix="headless-chain-events-", dir=WORK)[1])
    wrapper = (
        "import os, subprocess, sys, time\n"
        "with open(sys.argv[2], 'wb') as events:\n"
        "    child = subprocess.Popen([sys.argv[1], '--headless'], stdin=subprocess.DEVNULL, stdout=events,\n"
        "                             stderr=sys.stderr)\n"
        "print(child.pid, flush=True)\n"
        "print(child.wait(), flush=True)\n"
        "time.sleep(600)\n"
    )
    launcher = subprocess.Popen([sys.executable, "-c", (
        "import subprocess, sys, time\n"
        "wrapper = subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2], sys.argv[3]],\n"
        "                           stdin=subprocess.DEVNULL)\n"
        "print(wrapper.pid, flush=True)\n"
        "time.sleep(600)\n"
    ), wrapper, str(app / "Contents/MacOS/Arx"), str(events)], stdout=subprocess.PIPE, stderr=log, start_new_session=True)
    middle = None
    try:
        middle = int(launcher.stdout.readline())
        arx = int(launcher.stdout.readline())
        deadline = time.monotonic() + 60
        while '"event":"ready"' not in events.read_text():
            if time.monotonic() > deadline:
                raise ValueError("Chained run never became ready: " + events.read_text())
            time.sleep(0.25)
        helpers = descendants(arx)
        launcher.kill()  # Only the outer launcher; the wrapper stays Arx's live parent.
        launcher.wait(timeout=10)
        expect_gone([arx, *helpers], "after its outer launcher exited")
        if subprocess.run(["kill", "-0", str(middle)], capture_output=True).returncode != 0:
            raise ValueError("The wrapper exited, so the chain check proved nothing")
        if (status := launcher.stdout.readline().strip()) != b"0":
            raise ValueError(f"The chained run exited with status {status!r}: {events.read_text()}")
        recorded = [json.loads(line) for line in events.read_text().splitlines()]
        expect_stopped(recorded, "launcherExited")
        log.write("ARX_HEADLESS_LAUNCHER_CHAIN " + json.dumps(recorded[-2:]) + "\n")
    finally:
        for pid in (launcher.pid, middle):
            try:
                if pid is not None:
                    os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        launcher.wait(timeout=10)
        events.unlink(missing_ok=True)


def main():
    with smoke.log("headless-smoke") as log:
        WORK.mkdir(parents=True, exist_ok=True)
        app = build_app.main(log="headless-smoke-build.log", signed=True, require_engine=True).resolve()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with log.open("a") as output:
                url = f"http://127.0.0.1:{server.server_port}/"
                exercise(app, output, url, (1024, 640))
                unattended_failures(app, output, url)
                full_screen_refused(app, output, url)
                device_requests(app, output, url)
                long_runs(app, output, url)
                launcher_chain(app, output)
                contracts(app, output, url)
                output.write("ARX_HEADLESS_SMOKE_SUCCESS\n")
        finally:
            server.shutdown()
        print("ARX_HEADLESS_SMOKE_SUCCESS")
