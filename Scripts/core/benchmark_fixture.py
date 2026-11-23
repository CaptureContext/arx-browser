"""Loopback pages for `make benchmark`. Each page reports back when it is usable.

A page is usable once it has loaded, run its script and painted twice
(`load`, then two animation frames). It then requests `/beacon?event=ready&id=…`, and
the server records the monotonic time it arrived. Background tabs may not paint until
they're shown, so each page also reports `loaded` at its `load` event. The benchmark measures from its own
clock to that beacon, so the same pages work for any browser.

A page that becomes visible reports `visible` at `visibilitychange` and `shown` two
animation frames later, when it has painted again. Page Lifecycle `freeze` and `resume`
are reported with `navigator.sendBeacon`, which the browser sends even as the page
freezes, so the benchmark can count frozen pages. A start page loaded with `mark=1`
keeps its renderer busy for `MARK_MS`, `MARK_DELAY_MS` after it's ready, which tells its
renderer apart from extension and spare renderers in a process listing.

Requests come in bursts: background tabs that load together, and a relaunch that fetches
the icons of a hundred restored tabs at once. The server listens with a backlog of
`BACKLOG` connections rather than `socketserver`'s 5, because macOS resets a loopback
connection as soon as the backlog is full, and a refused beacon looked like a page that
never loaded. A beacon whose request fails anyway is sent again, up to `BEACON_ATTEMPTS`
times; a resent beacon arrives late, which only happens when the Mac is overloaded.

By default tab pages are served from `t<N>.localhost`, so each tab is its own site and
gets its own renderer. Chromium never lets same-site tabs share a renderer on localhost
or IP hosts, so `hosts="same-site"` serves them from `t<N>.arx-bench.test` instead: one
site, as tabs of the same real site are. `.test` never resolves on the internet; the
browser maps it to loopback (`HOST_RESOLVER_RULES`). A light one-second timer on each
page stands in for the background work of a typical site.

A tab page loaded with `live=1` also keeps a WebSocket open to the server, as a chat or a
live dashboard does (DEV-879): the server answers the upgrade on `/socket` and sends a short
message every `LIVE_TICK` seconds. It records `socket-open` for the page when the connection
opens and `socket-closed` once a send fails, so the benchmark can count the connections that
stayed open (`Beacons.connections`).
"""

import base64
import hashlib
import http.server
import threading
import time
from urllib.parse import parse_qs, urlsplit

MARK_MS = 400
BACKLOG = 128  # macOS caps a listen backlog at kern.ipc.somaxconn, 128 by default
BEACON_ATTEMPTS = 4
MARK_DELAY_MS = 3000  # after `ready`, so the benchmark can sample the processes first
SAME_SITE_DOMAIN = "arx-bench.test"
HOST_RESOLVER_RULES = f"MAP *.{SAME_SITE_DOMAIN} 127.0.0.1"
HOSTS = ("loopback", "same-site")
LIVE_TICK = 5  # seconds between the server's messages on a live page's WebSocket
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"  # RFC 6455
READY_SCRIPT = """<script>
const id = encodeURIComponent(document.body.dataset.id);
const report = (event, attempt = 1) => fetch(`/beacon?event=${event}&id=${id}`, {cache: 'no-store'})
  .catch(() => attempt < BEACON_ATTEMPTS && setTimeout(() => report(event, attempt + 1), 50 * attempt));
const painted = then => requestAnimationFrame(() => requestAnimationFrame(then));
addEventListener('load', () => {
  report('loaded');
  painted(() => {
    report('ready');
    if (new URLSearchParams(location.search).get('mark') === '1') setTimeout(() => {
      const end = performance.now() + MARK_MS;
      while (performance.now() < end) {}
      report('marked');
    }, MARK_DELAY_MS);
  });
});
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) { report('visible'); painted(() => report('shown')); }
});
document.addEventListener('freeze', () => navigator.sendBeacon(`/beacon?event=freeze&id=${id}`));
document.addEventListener('resume', () => report('resume'));
</script>""".replace("MARK_DELAY_MS", str(MARK_DELAY_MS)).replace("MARK_MS", str(MARK_MS)).replace(
    "BEACON_ATTEMPTS", str(BEACON_ATTEMPTS))

# After READY_SCRIPT, whose `id` it uses. The page holds the socket for as long as it lives.
LIVE_SCRIPT = """<script>
const socket = new WebSocket(`ws://${location.host}/socket?id=${id}`);
</script>"""

PARAGRAPH = ("Arx benchmark fixture text. Lorem ipsum dolor sit amet, consectetur adipiscing elit, "
             "sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. ")


def start_page(identifier):
    return (f"<!doctype html><html><head><meta charset=utf-8><title>Arx benchmark</title>"
            f"<style>body{{font:18px system-ui;margin:48px;background:#f4f7fb}}</style></head>"
            f"<body data-id=\"{identifier}\"><h1>Arx benchmark</h1>"
            f"<p>{PARAGRAPH * 4}</p>{READY_SCRIPT}</body></html>")


def tab_page(identifier, live=False):
    rows = "".join(f"<li><a href=\"#{index}\">Item {index}</a> {PARAGRAPH}</li>" for index in range(150))
    return (f"<!doctype html><html><head><meta charset=utf-8><title>Benchmark tab {identifier}</title>"
            f"<style>body{{font:15px system-ui;margin:32px}}li{{margin:4px 0}}"
            f".card{{display:inline-block;width:120px;height:80px;margin:4px;border-radius:8px;"
            f"background:linear-gradient(135deg,#7aa7ff,#ffb36b)}}</style></head>"
            f"<body data-id=\"{identifier}\"><h1>Tab {identifier}</h1>"
            f"{'<div class=card></div>' * 24}<ol>{rows}</ol>"
            f"<p id=clock></p><script>setInterval(() => {{"
            f"document.getElementById('clock').textContent = new Date().toISOString(); }}, 1000);</script>"
            f"{READY_SCRIPT}{LIVE_SCRIPT if live else ''}</body></html>")


def accept_key(key):
    """RFC 6455's Sec-WebSocket-Accept for a client's Sec-WebSocket-Key."""
    return base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode()).digest()).decode()


def text_frame(text):
    """An unmasked, final text frame shorter than 126 bytes, as a server sends it."""
    payload = text.encode()
    return bytes([0x81, len(payload)]) + payload


class Beacons:
    """Arrival times of page beacons, keyed by (event, id). A key can arrive many times."""

    def __init__(self):
        self.condition = threading.Condition()
        self.arrivals = {}

    def record(self, event, identifier):
        with self.condition:
            self.arrivals.setdefault((event, identifier), []).append(time.monotonic())
            self.condition.notify_all()

    def wait_since(self, event, identifier, since, timeout):
        """The first arrival after `since`, or None at the deadline."""
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                later = [value for value in self.arrivals.get((event, identifier), []) if value >= since]
                if later:
                    return later[0]
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self.condition.wait(remaining)

    def wait_any_since(self, event, since, timeout):
        """The first arrival of `event` from any page after `since`, or None at the deadline."""
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                later = [value for (name, _), values in self.arrivals.items() if name == event
                         for value in values if value >= since]
                if later:
                    return min(later)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self.condition.wait(remaining)

    def wait(self, event, identifier, timeout):
        """The first arrival, or None at the deadline."""
        return self.wait_since(event, identifier, float("-inf"), timeout)

    def wait_all(self, event, identifiers, timeout):
        """How many of `identifiers` reported `event` before the deadline."""
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                count = sum((event, identifier) in self.arrivals for identifier in identifiers)
                remaining = deadline - time.monotonic()
                if count == len(identifiers) or remaining <= 0:
                    return count
                self.condition.wait(remaining)

    def frozen(self, identifiers):
        """(frozen now, frozen at least once): a page is frozen while its last lifecycle beacon is `freeze`."""
        with self.condition:
            now = ever = 0
            for identifier in identifiers:
                freezes = self.arrivals.get(("freeze", identifier), [])
                resumes = self.arrivals.get(("resume", identifier), [])
                ever += bool(freezes)
                now += bool(freezes) and (not resumes or max(freezes) > max(resumes))
            return now, ever

    def connections(self, identifiers):
        """(open now, opened at least once): a page's WebSocket is open while its last opening
        came after its last noticed end."""
        with self.condition:
            now = ever = 0
            for identifier in identifiers:
                opened = self.arrivals.get(("socket-open", identifier), [])
                closed = self.arrivals.get(("socket-closed", identifier), [])
                ever += bool(opened)
                now += bool(opened) and (not closed or max(opened) > max(closed))
            return now, ever

    def forget(self, event, identifiers):
        with self.condition:
            for identifier in identifiers:
                self.arrivals.pop((event, identifier), None)


class Handler(http.server.BaseHTTPRequestHandler):
    beacons: Beacons = None
    stopping: threading.Event = None

    def do_GET(self):
        parts = urlsplit(self.path)
        query = {key: values[0] for key, values in parse_qs(parts.query).items()}
        if parts.path == "/beacon":
            self.beacons.record(query.get("event", ""), query.get("id", ""))
            return self.reply(204, b"", "text/plain")
        if parts.path == "/start":
            return self.reply(200, start_page(query.get("id", "start")).encode())
        if parts.path.startswith("/tab/"):
            # A run tag keeps one browser's beacons apart from another's for the same tab.
            index = parts.path.removeprefix("/tab/")
            identifier = f"{query['run']}-{index}" if query.get("run") else index
            return self.reply(200, tab_page(identifier, live=query.get("live") == "1").encode())
        if parts.path == "/socket":
            return self.serve_socket(query.get("id", ""))
        self.reply(404, b"not found", "text/plain")

    def serve_socket(self, identifier):
        """Holds a live page's WebSocket until a send fails or the server stops."""
        key = self.headers.get("Sec-WebSocket-Key")
        if not key or self.headers.get("Upgrade", "").lower() != "websocket":
            return self.reply(400, b"WebSocket upgrade expected", "text/plain")
        self.protocol_version = "HTTP/1.1"  # Chromium rejects a 101 answered as HTTP/1.0
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept_key(key))
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        self.beacons.record("socket-open", identifier)
        count = 0
        try:
            while not self.stopping.is_set():
                count += 1
                self.wfile.write(text_frame(f"tick {count}"))
                self.wfile.flush()
                self.stopping.wait(LIVE_TICK)
        except OSError:
            self.beacons.record("socket-closed", identifier)

    def do_POST(self):
        """`navigator.sendBeacon` posts; only the query matters."""
        parts = urlsplit(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if parts.path != "/beacon":
            return self.reply(404, b"not found", "text/plain")
        query = {key: values[0] for key, values in parse_qs(parts.query).items()}
        self.beacons.record(query.get("event", ""), query.get("id", ""))
        self.reply(204, b"", "text/plain")

    def reply(self, status, body, content_type="text/html; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class ListeningServer(http.server.ThreadingHTTPServer):
    """Takes a burst of connections without the kernel resetting any (`BACKLOG`)."""

    request_queue_size = BACKLOG
    daemon_threads = True  # a live page's socket thread never holds up the end of a run


class Server:
    def __init__(self, hosts="loopback"):
        if hosts not in HOSTS:
            raise ValueError(f"fixture hosts must be one of {HOSTS}")
        self.hosts = hosts
        self.beacons = Beacons()
        self.stopping = threading.Event()
        handler = type("BoundHandler", (Handler,), {"beacons": self.beacons, "stopping": self.stopping})
        self.server = ListeningServer(("127.0.0.1", 0), handler)
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stopping.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def start_url(self, identifier, mark=False):
        return f"http://127.0.0.1:{self.port}/start?id={identifier}" + ("&mark=1" if mark else "")

    def tab_url(self, index, run="", live=False):
        """Reports beacons as `<run>-<index>`, or `<index>` without a run tag. A live page keeps
        a WebSocket open to the server."""
        domain = SAME_SITE_DOMAIN if self.hosts == "same-site" else "localhost"
        query = "&".join(([f"run={run}"] if run else []) + (["live=1"] if live else []))
        return f"http://t{index}.{domain}:{self.port}/tab/{index}" + (f"?{query}" if query else "")

    @staticmethod
    def tab_id(index, run=""):
        return f"{run}-{index}" if run else str(index)
