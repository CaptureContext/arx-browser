"""Owned hostile keyboard pages; bounded boolean evidence never records values/keys."""

import json
import threading
import time
import uuid
import weakref
from urllib.parse import parse_qs, urlsplit

MODES = frozenset(("printable", "unicode", "backspace", "delete", "left", "right", "home", "end", "up", "down", "enter",
                   "keydown-focus", "keydown-selection", "keydown-value", "beforeinput-focus", "beforeinput-selection",
                   "textInput-focus", "textInput-selection", "prevent-beforeinput", "enter-change", "slow", "fallback"))
_LOCK = threading.Lock()
_SERVERS = weakref.WeakKeyDictionary()
MAXIMUM_RUNS = 128
MAXIMUM_EVENTS = 32

MAIN = r'''<!doctype html><meta charset="utf-8"><title>Arx keypress loading</title>
<style>body{margin:24px;font:16px sans-serif}input,textarea{display:block;width:280px;height:80px}</style>
<form id="form"><input id="target" aria-label="Arx keypress target" value="abcd"><button>Submit</button></form>
<input id="foreign" aria-label="Arx keypress foreign" value="untouched">
<input type="password" aria-label="ARX_KEYPRESS_SECRET" value="ARX_KEYPRESS_SECRET">
<script>
const run=new URLSearchParams(location.search).get('run');
const mode=location.pathname.split('/').pop();
let target=document.getElementById('target');
const foreign=document.getElementById('foreign');
if(mode==='enter'){
 const textarea=document.createElement('textarea'); textarea.id='target';
 textarea.setAttribute('aria-label','Arx keypress target'); textarea.value='abcd';
 target.replaceWith(textarea); target=textarea;
}
const initial='abcd';
let submitted=false, timer;
const pending=[];
function send(query,attempt=0){
 return fetch('/reference-keypress/event/'+run+'?'+query,{cache:'no-store'})
  .catch(()=>attempt<4?new Promise(resolve=>setTimeout(resolve,100*(attempt+1))).then(()=>send(query,attempt+1)):undefined);
}
function report(name,event){
 const query=new URLSearchParams({target:name,event:event.type,trusted:String(+event.isTrusted),
  activation:String(+navigator.userActivation.isActive),focused:String(+(document.activeElement===target)),
  correct:String(+(foreign.value==='untouched'))});
 pending.push(send(query));
}
function correct(){
 const expected={printable:'abxcd',unicode:'ab🙂cd',backspace:'acd',delete:'abd',enter:'ab\ncd',slow:'abxcd'};
 const positions={left:1,right:3,home:0,end:4};
 if(mode==='keydown-value')return target.value==='author'&&foreign.value==='untouched'&&!submitted;
 if(mode==='fallback')return scrollY===200&&target.value===initial&&foreign.value==='untouched';
 if(mode==='enter-change')return target.value==='abxcd'&&foreign.value==='untouched'&&!submitted;
 const redirected=mode.includes('-focus')||mode.includes('-selection')||mode==='prevent-beforeinput';
 const value=redirected?initial:(expected[mode]??initial);
 return target.value===value&&foreign.value==='untouched'&&!submitted
  &&(!(mode in positions)||target.selectionStart===positions[mode]);
}
function settle(){
 clearTimeout(timer);
 timer=setTimeout(()=>{
  const query=new URLSearchParams({target:'fixture',event:'settled',trusted:'0',
   activation:String(+navigator.userActivation.isActive),focused:String(+(document.activeElement===target)),
   correct:String(+correct())});
  Promise.allSettled(pending).then(()=>send(query));
 },100);
}
for(const control of [target,foreign])for(const type of ['keydown','keypress','keyup','beforeinput','textInput','input','change']){
 control.addEventListener(type,event=>{
  report(control===target?'target':'foreign',event);
  if(control===target){
   if(mode===type+'-focus')foreign.focus();
   if(mode===type+'-selection')target.setSelectionRange(0,0);
   if(mode==='keydown-value'&&type==='keydown')target.value='author';
   if(mode==='prevent-beforeinput'&&type==='beforeinput')event.preventDefault();
   if(mode==='enter-change'&&type==='change')foreign.focus();
   if(mode==='slow'&&type==='keydown'){
    const end=performance.now()+1200;while(performance.now()<end){}
   }
  }
  settle();
 });
}
document.getElementById('form').addEventListener('submit',event=>{
 submitted=true;event.preventDefault();report('fixture',event);settle();
});
// Website chooses its own initial focused field. The automation path must never
// establish focus or synthesize transient/sticky user activation.
target.focus();target.setSelectionRange(2,2);
if(mode==='fallback'){
 document.body.style.height='4000px';target.style.position='fixed';target.style.top='24px';
 target.setSelectionRange(0,0);scrollTo(0,200);
}
document.title='Arx keypress ready';
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


def serve(handler):
    request = urlsplit(handler.path)
    if not request.path.startswith("/reference-keypress/"):
        return False
    route = request.path.removeprefix("/reference-keypress/")
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
                records[token] = (now, [])
                _respond(handler, 200, MAIN.encode(), "text/html; charset=utf-8")
        elif route.startswith("state/") and not query:
            token = route.removeprefix("state/")
            record = records.get(token) if _token(token) else None
            _respond(handler, 200 if record else 404,
                     json.dumps({"events": record[1]}).encode() if record else b"")
        elif route.startswith("event/"):
            token = route.removeprefix("event/")
            record = records.get(token) if _token(token) else None
            fields = {"target", "event", "trusted", "activation", "focused", "correct"}
            valid = (record is not None and set(query) == fields and all(len(v) == 1 for v in query.values())
                     and query["target"][0] in {"target", "foreign", "fixture"}
                     and query["event"][0] in {"keydown", "keypress", "keyup", "beforeinput", "textInput", "input", "change", "submit", "settled"}
                     and all(query[key][0] in {"0", "1"} for key in fields - {"target", "event"}))
            if not valid or len(record[1]) >= MAXIMUM_EVENTS:
                _respond(handler, 400)
            else:
                event = {key: values[0] if key in {"target", "event"} else values[0] == "1"
                         for key, values in query.items()}
                record[1].append(event)
                _respond(handler, 204)
        else:
            _respond(handler, 404)
    return True
