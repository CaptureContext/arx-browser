"""Pages that report their own visibility, timers and freezing (DEV-936, DEV-941).

Each page keeps a 1 Hz timer and a 10 Hz probe and writes its state into its title:
`ARXVIS <case> first=<visibility at start> vis=<visibility> slow=<1 Hz ticks>
fast=<10 Hz ticks> ms=<ms since start> state=running|frozen|resumed painted=<frames>`.
A hidden page still updates its title; a frozen page can't, so an unchanged title means
no timer ran. The engine host's `--background-visibility-fixture` reads these titles.

Each page also beacons its freeze, resume and visibility changes to `/visibility/event`.
Run `python3 -m Scripts.core.background_visibility_fixture` to serve the pages on their
own and print a running tally, for measuring the app by hand (see Scripts/README.md).
"""

import http.server
import re
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit

PAGE = "/visibility/page.html"
EVENT = "/visibility/event"
CASE = re.compile(r"[a-z0-9-]{1,32}")
KINDS = {"freeze", "resume", "visible", "hidden"}

_events = []
_events_lock = threading.Lock()


def page(case):
    return ("<!doctype html><meta charset=utf-8><title>ARXVIS " + case + " loading</title>"
            "<style>body{font:20px system-ui;margin:32px;background:#e8eef4}</style>"
            "<h1>Background visibility fixture</h1><p id=state></p><script>(()=>{"
            f"const name={case!r};const first=document.visibilityState;const start=performance.now();"
            "let slow=0,fast=0,state='running',painted=0;"
            "const beacon=k=>navigator.sendBeacon('/visibility/event?case='+name+'&kind='+k);"
            "const report=()=>{document.title=['ARXVIS',name,'first='+first,'vis='+document.visibilityState,"
            "'slow='+slow,'fast='+fast,'ms='+Math.round(performance.now()-start),'state='+state,"
            "'painted='+painted].join(' ');document.getElementById('state').textContent=document.title;};"
            "const paint=()=>requestAnimationFrame(()=>requestAnimationFrame(()=>{painted++;report();}));"
            "setInterval(()=>{slow++;report();},1000);setInterval(()=>{fast++;},100);"
            "document.addEventListener('freeze',()=>{state='frozen';report();beacon('freeze');});"
            "document.addEventListener('resume',()=>{state='resumed';report();beacon('resume');});"
            "document.addEventListener('visibilitychange',()=>{report();beacon(document.visibilityState);"
            "if(document.visibilityState==='visible')paint();});"
            "if(document.visibilityState==='visible')paint();report();})();</script>").encode()


def serve(handler):
    """Serves the fixture's routes; returns False for any other path."""
    target = urlsplit(handler.path)
    if target.path not in (PAGE, EVENT):
        return False
    query = parse_qs(target.query, keep_blank_values=True)
    case = query.get("case", [""])
    expected = {"case"} if target.path == PAGE else {"case", "kind"}
    if (set(query) != expected or len(case) != 1 or not CASE.fullmatch(case[0])
            or (target.path == EVENT and (len(query["kind"]) != 1 or query["kind"][0] not in KINDS))):
        handler.send_error(400)
        return True
    if target.path == EVENT:
        with _events_lock:
            _events.append((time.monotonic(), case[0], query["kind"][0]))
        handler.send_response(204)
        handler.send_header("Content-Length", "0")
        handler.end_headers()
        return True
    content = page(case[0])
    handler.send_response(200)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(content)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(content)
    return True


def tally(events):
    """Pages frozen now (last event a freeze) and resumes, from (time, case, kind) events."""
    last = {}
    resumes = 0
    for _, case, kind in events:
        if kind in ("freeze", "resume"):
            last[case] = kind
        if kind == "resume":
            resumes += 1
    return sum(1 for kind in last.values() if kind == "freeze"), resumes


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if not serve(self):
            self.send_error(404)

    do_POST = do_GET

    def log_message(self, *_):
        pass


def main(arguments=None):
    """Serves the pages on loopback and prints frozen pages and resumes every 2 s."""
    arguments = sys.argv[1:] if arguments is None else arguments
    port = int(arguments[0]) if arguments else 8936
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"Open http://127.0.0.1:{port}{PAGE}?case=tab-1 … tab-20 as tabs; Ctrl-C stops.", flush=True)
    try:
        while True:
            time.sleep(2)
            with _events_lock:
                frozen, resumes = tally(_events)
            print(f"frozen={frozen} resumes={resumes}", flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
