"""Owned nested scroll containers with bounded, value-free native-effect evidence."""

import json
import math
import threading
import time
import uuid
import weakref
from urllib.parse import parse_qs, urlsplit

MODES = frozenset(("main", "hidden", "navigation"))
MAXIMUM_RUNS = 64
_LOCK = threading.Lock()
_SERVERS = weakref.WeakKeyDictionary()
OFFSETS = frozenset(("innerX", "innerY", "outerX", "outerY", "pageX", "pageY"))
COUNTS = frozenset(("sample", "events"))
FLAGS = frozenset(("focused", "activation", "trusted", "innerAtEnd"))
MAIN = r'''<!doctype html><meta charset="utf-8"><title>Arx scroll ready</title>
<style>
html{scroll-behavior:smooth}body{margin:16px;height:2400px;font:16px sans-serif}
#viewport{position:fixed;top:8px;left:430px}
#outer{margin-top:64px;width:360px;height:260px;overflow:auto}
#wide{width:1100px;height:1000px;padding:16px}
#inner{width:280px;height:160px;overflow-y:auto;overflow-x:hidden;scroll-behavior:smooth}
#contents{height:960px;width:260px}button{height:32px}
</style>
<button id="viewport" aria-label="Arx scroll viewport">Viewport anchor</button>
<div id="outer"><div id="wide"><div id="inner" tabindex="0" aria-label="Arx scroll container">
<div id="contents"><button id="anchor" aria-label="Arx scroll anchor">Inner anchor</button></div>
</div></div></div>
<input type="password" aria-label="ARX_SCROLL_PASSWORD" value="ARX_SCROLL_SECRET">
<input id="former" type="password" aria-label="ARX_SCROLL_FORMER" value="ARX_SCROLL_FORMER_SECRET">
<script>
const run=new URLSearchParams(location.search).get('run');
const mode=location.pathname.split('/').pop();
const inner=document.getElementById('inner'),outer=document.getElementById('outer');
document.getElementById('former').type='text';
if(mode==='hidden')inner.style.overflowY='hidden';
let sample=0,events=0,trusted=true;
function report(){
 const state={innerX:inner.scrollLeft,innerY:inner.scrollTop,outerX:outer.scrollLeft,outerY:outer.scrollTop,
  pageX:scrollX,pageY:scrollY,sample:++sample,events,
  focused:+(document.activeElement!==document.body&&document.activeElement!==document.documentElement),
  activation:+navigator.userActivation.isActive,trusted:+trusted,
  innerAtEnd:+(Math.abs(inner.scrollTop-(inner.scrollHeight-inner.clientHeight))<0.5)};
 return fetch('/reference-scroll/report/'+run+'?'+new URLSearchParams(state),{cache:'no-store'});
}
for(const area of [inner,outer,document])area.addEventListener('scroll',event=>{
 ++events;trusted=trusted&&event.isTrusted;
 const sent=report();
 if(mode==='navigation')sent.then(()=>location.assign('/reference-scroll/destination'));
});
// Sampling only reads native geometry and posts HTTP evidence: no DOM/title edits.
report();const timer=setInterval(()=>{if(sample<10000)report();else clearInterval(timer)},100);
</script>'''


def _respond(handler, status, body=b"", content="application/json"):
    handler.send_response(status)
    handler.send_header("Content-Type", content)
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _token(value):
    try:
        return str(uuid.UUID(value)) == value
    except (ValueError, AttributeError, TypeError):
        return False


def evidence(query):
    if set(query) != OFFSETS | COUNTS | FLAGS or any(len(value) != 1 for value in query.values()):
        return None
    result = {}
    for field in OFFSETS:
        try:
            number = float(query[field][0])
        except ValueError:
            return None
        if not math.isfinite(number) or abs(number) > 100_000:
            return None
        result[field] = number
    for field in COUNTS:
        raw = query[field][0]
        if not raw.isascii() or not raw.isdecimal() or not 0 <= int(raw) <= 10_000:
            return None
        result[field] = int(raw)
    for field in FLAGS:
        if query[field][0] not in {"0", "1"}:
            return None
        result[field] = query[field][0] == "1"
    return result


def serve(handler):
    request = urlsplit(handler.path)
    if not request.path.startswith("/reference-scroll/"):
        return False
    if len(handler.path) > 4096:
        _respond(handler, 400)
        return True
    route = request.path.removeprefix("/reference-scroll/")
    query = parse_qs(request.query, keep_blank_values=True)
    with _LOCK:
        records = _SERVERS.setdefault(handler.server, {})
        now = time.monotonic()
        for key in [key for key, record in records.items() if now - record[0] > 300]:
            del records[key]
        if route in MODES:
            token = query.get("run", [None])[0]
            if not _token(token) or set(query) != {"run"} or len(query["run"]) != 1:
                _respond(handler, 400)
            elif token in records or len(records) >= MAXIMUM_RUNS:
                _respond(handler, 409)
            else:
                records[token] = [now, None]
                _respond(handler, 200, MAIN.encode(), "text/html; charset=utf-8")
        elif route == "destination" and not query:
            _respond(handler, 200, b"<!doctype html><title>Arx scroll destination</title>", "text/html")
        elif route.startswith("state/") and not query:
            token = route.removeprefix("state/")
            record = records.get(token) if _token(token) else None
            _respond(handler, 200 if record and record[1] else 404,
                     json.dumps(record[1]).encode() if record and record[1] else b"")
        elif route.startswith("report/"):
            token = route.removeprefix("report/")
            record = records.get(token) if _token(token) else None
            value = evidence(query)
            if not record or not value or value["sample"] <= (record[1]["sample"] if record[1] else 0):
                _respond(handler, 400)
            else:
                record[1] = value
                _respond(handler, 204)
        else:
            _respond(handler, 404)
    return True
