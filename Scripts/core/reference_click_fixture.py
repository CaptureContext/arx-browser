"""Owned loopback pages for atomic reference activation, never real sites."""

from urllib.parse import urlsplit

BUTTON_NAME = "Arx reference click"
NAVIGATION_NAME = "Arx reference navigation"
READY_TITLE = "Arx reference ready"
COUNTER_PREFIX = "Arx reference count="

# Trusted mutation controls use CSS-point centers (96,34) and (280,34).
# The click target's own label remains stable. Only its handler changes count.
MAIN = """<!doctype html><meta charset="utf-8"><title>Arx reference ready</title>
<style>
body{margin:16px;padding-top:64px;font:16px sans-serif}
.control{position:fixed;top:16px;width:160px;height:36px}
#replace{left:16px}#reinsert{left:200px}
#target{min-width:180px;min-height:44px}
</style>
<button class="control" id="replace" aria-label="Replace click target">Replace target</button>
<button class="control" id="reinsert" aria-label="Reinsert click target">Reinsert target</button>
<button id="target" aria-label="Arx reference click">Activate target</button>
<p id="counter">0</p>
<a href="/reference-click/destination" aria-label="Arx reference navigation">Navigate</a>
<script>
let count=0;
function clicked(event){
 if(!event.isTrusted){document.title='Arx reference untrusted';return;}
 count++;
 const active=navigator.userActivation.isActive;
 const until=performance.now()+ARX_FIXTURE_DELAY;
 while(performance.now()<until){}
 document.getElementById('counter').textContent=String(count);
 document.title='Arx reference count='+count+' trusted=true activation='+active;
}
document.getElementById('target').onclick=clicked;
document.getElementById('replace').onclick=(event)=>{
 if(!event.isTrusted){document.title='Arx reference untrusted';return;}
 const old=document.getElementById('target');
 const replacement=old.cloneNode(true);replacement.onclick=clicked;
 old.replaceWith(replacement);document.title='Arx reference replaced';
};
document.getElementById('reinsert').onclick=(event)=>{
 if(!event.isTrusted){document.title='Arx reference untrusted';return;}
 const old=document.getElementById('target');const parent=old.parentNode;
 old.remove();parent.appendChild(old);document.title='Arx reference reinserted';
};
</script>"""

DOCUMENTS = {
    "/reference-click/main": MAIN.replace("ARX_FIXTURE_DELAY", "0"),
    "/reference-click/slow": MAIN.replace("ARX_FIXTURE_DELAY", "1200"),
    "/reference-click/transparent": MAIN.replace("ARX_FIXTURE_DELAY", "0").replace(
        "#target{min-width", "#target{opacity:0;min-width"),
    "/reference-click/destination": """<!doctype html><meta charset="utf-8">
<title>Arx reference destination</title><p>ARX_REFERENCE_DESTINATION</p>""",
}


def serve(handler):
    body = DOCUMENTS.get(urlsplit(handler.path).path)
    if body is None:
        return False
    encoded = body.encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Content-Length", str(len(encoded)))
    handler.end_headers()
    handler.wfile.write(encoded)
    return True
