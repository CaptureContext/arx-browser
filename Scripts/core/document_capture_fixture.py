"""Disposable full-document pixel/state fixture; serves no profile files."""

import json
import math
import threading
import time
import uuid
import weakref
from urllib.parse import parse_qs, urlsplit

MAXIMUM_RUNS = 32
_LOCK = threading.Lock()
_SERVERS = weakref.WeakKeyDictionary()
COUNTS = frozenset(("sample", "scrollEvents", "resizeEvents", "focusEvents", "selectionEvents",
                    "viewportWidth", "viewportHeight", "layoutWidth", "documentWidth", "documentHeight",
                    "selectionStart", "selectionEnd", "frames", "lazyLoads"))
NUMBERS = frozenset(("scrollX", "scrollY", "deviceScale", "visualScale", "markerX", "markerY", "markerWidth", "markerHeight"))
FLAGS = frozenset(("ready", "focused", "repainted"))
MAIN = r'''<!doctype html><meta charset="utf-8"><title>Arx document capture ready</title>
<style>html,body{margin:0;padding:0}section{height:800px}
#red{background:rgb(255,0,0)}#green{background:rgb(0,255,0)}#blue{background:rgb(0,0,255)}
#focus{position:absolute;left:850px;top:1132px;width:8px;height:8px;outline:none}
#selection{visibility:hidden;position:absolute;left:24px;top:24px}
iframe{position:absolute;left:400px;top:4300px;width:200px;height:120px;border:0}</style>
<section id="red"></section><section id="green"></section><section id="blue"></section>
<div id="focus" tabindex="0"></div><span id="selection">owned fixture selection</span>
<script>
const query=new URLSearchParams(location.search),run=query.get('run'),mode=query.get('mode');
let sample=0,scrollEvents=0,resizeEvents=0,focusEvents=0,selectionEvents=0,ready=false,repainted=false,lazyLoads=0;
addEventListener('scroll',()=>++scrollEvents);addEventListener('resize',()=>++resizeEvents);
addEventListener('focusin',()=>++focusEvents);addEventListener('selectionchange',()=>++selectionEvents);
if(mode==='oversize')document.getElementById('blue').style.height='9000px';
if(mode==='horizontal')for(const section of document.querySelectorAll('section'))section.style.width='1200px';
if(mode==='fixed'||mode==='sticky'){
 const marker=document.createElement('div');marker.id='marker';
 marker.style.cssText='position:'+mode+';top:20px;left:32px;margin-left:32px;width:80px;height:24px;background:black';
 (mode==='sticky'?document.getElementById('red'):document.body).prepend(marker);
}
if(mode==='canvas'){const canvas=document.createElement('canvas');canvas.width=80;canvas.height=24;
 canvas.getContext('2d').fillRect(0,0,80,24);document.body.append(canvas);}
if(mode==='animation'){const style=document.createElement('style');
 style.textContent='@keyframes ownedOpacity{from{opacity:0.5}to{opacity:1}}#focus{animation:ownedOpacity 2s infinite}';
 document.head.append(style);}
if(mode==='frame'){const child=document.createElement('iframe');child.src='/document-capture/frame?run='+run;document.body.append(child);}
if(mode==='lazy'){document.getElementById('blue').style.height='2400px';
 const image=document.createElement('img');image.loading='lazy';image.width=100;image.height=8;
 image.style.cssText='position:absolute;left:700px;top:3990px';image.onload=()=>++lazyLoads;
 image.src='/document-capture/lazy/'+run;document.body.append(image);}
if(mode==='loading'){const script=document.createElement('script');script.async=true;
 script.src='/document-capture/hold/'+run;document.head.append(script);}
function report(){
 const selection=getSelection(),root=document.documentElement,marker=document.getElementById('marker')?.getBoundingClientRect();
 const state={sample:++sample,scrollEvents,resizeEvents,focusEvents,selectionEvents,
  viewportWidth:innerWidth,viewportHeight:innerHeight,layoutWidth:root.clientWidth,
  documentWidth:root.scrollWidth,documentHeight:root.scrollHeight,
  selectionStart:selection.anchorOffset,selectionEnd:selection.focusOffset,frames:frames.length,lazyLoads,
  markerX:marker?.x??0,markerY:marker?.y??0,markerWidth:marker?.width??0,markerHeight:marker?.height??0,
  scrollX,scrollY,deviceScale:devicePixelRatio,visualScale:visualViewport.scale,
  ready:+ready,repainted:+repainted,focused:+(document.activeElement===document.getElementById('focus'))};
 return fetch('/document-capture/report/'+run+'?'+new URLSearchParams(state),{cache:'no-store'});
}
addEventListener(mode==='loading'?'DOMContentLoaded':'load',()=>requestAnimationFrame(()=>{
 if(mode==='horizontal')scrollTo(125.25,1100.5);else scrollTo(0,550);document.getElementById('focus').focus({preventScroll:true});
 const range=document.createRange();range.selectNodeContents(document.getElementById('selection'));
 getSelection().removeAllRanges();getSelection().addRange(range);
 requestAnimationFrame(()=>{ready=true;report()});
}));
setInterval(()=>{
 if(!ready||sample>=10000)return;report();
 fetch('/document-capture/poll/'+run,{cache:'no-store'}).then(r=>r.json()).then(state=>{
  if(state.command==='add-frame'&&!frames.length){const child=document.createElement('iframe');
   child.src='/document-capture/frame?run='+run;document.body.append(child);}
  if(state.command==='repaint'&&!repainted){document.getElementById('red').style.background='rgb(0,255,255)';
   requestAnimationFrame(()=>requestAnimationFrame(()=>{repainted=true;report()}));}
 });
},50);
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
    except (ValueError, TypeError, AttributeError):
        return False


def evidence(query):
    if set(query) != COUNTS | NUMBERS | FLAGS or any(len(value) != 1 for value in query.values()):
        return None
    value = {}
    for key in COUNTS:
        raw = query[key][0]
        if not raw.isascii() or not raw.isdecimal() or not 0 <= int(raw) <= 32768:
            return None
        value[key] = int(raw)
    if not 1 <= value["sample"] <= 10000 or value["frames"] > 1:
        return None
    for key in NUMBERS:
        try:
            number = float(query[key][0])
        except ValueError:
            return None
        if not math.isfinite(number) or abs(number) > 32768:
            return None
        if key in {"deviceScale", "visualScale"} and not 0 < number <= 8:
            return None
        value[key] = number
    for key in FLAGS:
        if query[key][0] not in {"0", "1"}:
            return None
        value[key] = query[key][0] == "1"
    return value


def serve(handler):
    request = urlsplit(handler.path)
    if not request.path.startswith("/document-capture/"):
        return False
    if len(handler.path) > 4096:
        _respond(handler, 400)
        return True
    route = request.path.removeprefix("/document-capture/")
    query = parse_qs(request.query, keep_blank_values=True)
    if route.startswith("hold/") and not query:
        token = route.removeprefix("hold/")
        with _LOCK:
            record = _SERVERS.get(handler.server, {}).get(token) if _token(token) else None
            release = record["release"] if record else None
        if release is None:
            _respond(handler, 404)
        else:
            release.wait(20)
            _respond(handler, 200, b"/* owned empty loading fixture */", "application/javascript")
        return True
    with _LOCK:
        records = _SERVERS.setdefault(handler.server, {})
        now = time.monotonic()
        for key in [key for key, record in records.items() if now - record["created"] > 300]:
            del records[key]
        if route == "main":
            token = query.get("run", [None])[0]
            if (set(query) != {"run", "mode"} or not _token(token)
                    or any(len(value) != 1 for value in query.values()) or query["mode"][0] not in {"plain", "oversize", "horizontal", "fixed", "sticky", "canvas", "animation", "frame", "lazy", "loading", "zoom"}):
                _respond(handler, 400)
            elif token in records or len(records) >= MAXIMUM_RUNS:
                _respond(handler, 409)
            else:
                records[token] = {"created": now, "latest": None, "command": "none", "lazyRequests": 0, "release": threading.Event()}
                _respond(handler, 200, MAIN.encode(), "text/html; charset=utf-8")
        elif route in {"frame", "destination"}:
            token = query.get("run", [None])[0]
            if set(query) != {"run"} or len(query["run"]) != 1 or token not in records:
                _respond(handler, 404)
            else:
                title = "Arx document capture destination" if route == "destination" else "Arx document frame"
                _respond(handler, 200, ("<!doctype html><title>"+title+"</title>").encode(), "text/html")
        else:
            parts = route.split("/")
            token = parts[1] if len(parts) == 2 else None
            record = records.get(token) if _token(token) else None
            if not record:
                _respond(handler, 404)
            elif parts[0] == "lazy" and not query:
                record["lazyRequests"] = min(32768, record["lazyRequests"] + 1)
                _respond(handler, 404)
            elif parts[0] == "state" and not query:
                _respond(handler, 200 if record["latest"] else 404,
                         json.dumps({**record["latest"], "lazyRequests": record["lazyRequests"]}).encode() if record["latest"] else b"")
            elif parts[0] == "poll" and not query:
                _respond(handler, 200, json.dumps({"command": record["command"]}).encode())
            elif parts[0] == "command" and (query == {"action": ["add-frame"]} or query == {"action": ["repaint"]} or query == {"action": ["release-load"]}):
                record["command"] = query["action"][0]
                if record["command"] == "release-load":
                    record["release"].set()
                _respond(handler, 204)
            elif parts[0] == "report":
                value = evidence(query)
                previous = record["latest"]
                if not value or (previous and value["sample"] <= previous["sample"]):
                    _respond(handler, 400)
                else:
                    record["latest"] = value
                    _respond(handler, 204)
            else:
                _respond(handler, 404)
    return True
