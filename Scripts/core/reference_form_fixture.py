"""Owned loopback controls and value-free event evidence for reference actions."""

import json
import threading
import time
import uuid
import weakref
from urllib.parse import parse_qs, urlsplit

NAMES = {name: f"Arx form {name}" for name in ("text", "search", "textarea", "select")}
READY_TITLE = "Arx form ready"
DESTINATION_TITLE = "Arx form destination"
MODES = frozenset(("main", "slow", "navigation", "hidden", "value", "selection", "readonly",
                   "maxlength", "type", "selected", "option-value", "replace", "disabled", "oversized"))
_LOCK = threading.Lock()
_SERVERS = weakref.WeakKeyDictionary()
MAXIMUM_RUNS = 128
MAXIMUM_EVENTS = 32

MAIN = r'''<!doctype html><meta charset="utf-8"><title>Arx form ready</title>
<style>
body{margin:16px;padding-top:64px;font:16px sans-serif}
#mutate{position:fixed;left:16px;top:16px;width:160px;height:36px}
input,textarea,select{display:block;margin:12px;width:260px;min-height:32px}
</style>
<button id="mutate" aria-label="Mutate form baseline">Mutate baseline</button>
<input id="text" aria-label="Arx form text" value="original">
<input id="search" type="search" aria-label="Arx form search" value="original">
<textarea id="textarea" aria-label="Arx form textarea">first
second</textarea>
<select id="select" aria-label="Arx form select">
<option value="a">Alpha</option><option value="b">Beta</option><option value="">Empty</option>
<option value="duplicate">One</option><option value="duplicate">Two</option>
<option value="disabled" disabled>Disabled</option><option value="hidden" hidden>Hidden</option>
<option value="css-hidden" style="display:none">CSS hidden</option>
<optgroup label="Hidden group" style="visibility:hidden"><option value="hidden-group">Grouped</option></optgroup>
</select>
<input id="password" type="password" aria-label="ARX_FORM_PASSWORD" value="ARX_FORM_SECRET">
<input id="former" type="password" aria-label="ARX_FORM_FORMER_PASSWORD" value="ARX_FORM_FORMER_SECRET">
<input id="file" type="file" aria-label="Arx form file">
<script>
const run=new URLSearchParams(location.search).get('run');
const mode=location.pathname.split('/').pop();
const controls=['text','search','textarea','select'];
const sentEvents=[];
const element=id=>document.getElementById(id);
element('former').type='text';
if(mode==='hidden')element('text').style.opacity='0';
if(mode==='disabled')element('text').disabled=true;
if(mode==='oversized')element('text').value='x'.repeat(32769);
function report(target,event,trusted,activation,focused,correct){
 const query=new URLSearchParams({target,event,trusted:String(+trusted),activation:String(+activation),
  focused:String(+focused),correct:String(+correct)});
 return fetch('/reference-form/event/'+run+'?'+query,{cache:'no-store'});
}
for(const target of controls){
 for(const event of ['input','change'])element(target).addEventListener(event,e=>{
  const expected=target==='textarea'?'replacement\nline':target==='select'?'b':'replacement';
  const correct=element(target).value===expected;
  const active=navigator.userActivation.isActive;
  const focused=document.activeElement===element(target);
  if(mode==='slow'&&event==='input'){
   const until=performance.now()+1200;while(performance.now()<until){}
  }
  const sent=report(target,event,e.isTrusted,active,focused,correct);
  sentEvents.push(sent);
  if(mode==='navigation'&&event==='change')Promise.all(sentEvents).then(()=>location.assign('/reference-form/destination'));
 });
}
element('mutate').onclick=e=>{
 if(!e.isTrusted)return;
 const input=element('text');
 switch(mode){
  case 'value':input.value='replacement';break;
  case 'selection':input.setSelectionRange(1,2,'backward');break;
  case 'readonly':input.readOnly=true;break;
  case 'maxlength':input.maxLength=20;break;
  case 'type':input.type='search';break;
  case 'selected':element('select').value='b';break;
  case 'option-value':element('select').options[1].value='interleaved';break;
  case 'replace':input.replaceWith(input.cloneNode(true));break;
 }
 // HTTP acknowledgement deliberately changes no DOM/title. Property-only
 // mutation tests compare the pre/post native DOM version using separate scopes.
 report('mutation','mutation',true,navigator.userActivation.isActive,false,true);
};
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
    if not request.path.startswith("/reference-form/"):
        return False
    route = request.path.removeprefix("/reference-form/")
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
        elif route == "destination" and not query:
            _respond(handler, 200, b"<!doctype html><title>Arx form destination</title><p>ARX_FORM_DESTINATION</p>", "text/html")
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
                     and query["target"][0] in {*NAMES, "mutation"}
                     and query["event"][0] in {"input", "change", "mutation"}
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
