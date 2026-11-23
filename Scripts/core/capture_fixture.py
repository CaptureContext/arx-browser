"""Controlled page-rendering cases for viewport capture in the signed app smoke."""

import time
from urllib.parse import urlsplit

# CSS-point centers and opaque sRGB colors. Native smoke scales these positions
# using the returned bitmap/viewport ratio instead of assuming Retina is 2x.
PATCHES = (
    (50, 50, (255, 0, 0)),
    (150, 50, (0, 255, 0)),
    (50, 150, (0, 0, 255)),
    (150, 150, (255, 255, 0)),
    (260, 40, (255, 0, 255)),
    (50, 260, (0, 255, 255)),
)

DOCUMENTS = {
    "/capture/document.html": """<!doctype html><meta charset="utf-8">
<title>Arx capture document</title><style>
html,body{margin:0}body{width:1800px;height:1800px}
.band{height:600px;width:1800px}.red{background:red}.green{background:lime}.blue{background:blue}
</style><div class="band red"></div><div class="band green"></div><div class="band blue"></div>
<script>
function report(){document.title='Arx capture document | '+[scrollX,scrollY,innerWidth,innerHeight,devicePixelRatio].join(',')}
addEventListener('load',()=>{scrollTo(125,300);requestAnimationFrame(report)});
addEventListener('scroll',report);addEventListener('resize',report);
</script>""",

    "/capture/viewport.html": """<!doctype html><meta charset="utf-8">
<title>Arx capture viewport</title>
<style>
html,body{margin:0;background:rgb(17,34,51);min-width:400px;min-height:400px}
.patch{position:absolute;width:100px;height:100px}
#red{left:0;top:0;background:red}#green{left:100px;top:0;background:lime}
#blue{left:0;top:100px;background:blue}#yellow{left:100px;top:100px;background:yellow}
canvas{position:absolute;left:220px;top:0;width:80px;height:80px}
iframe{position:absolute;left:0;top:220px;width:100px;height:100px;border:0}
</style>
<div class="patch" id="red"></div><div class="patch" id="green"></div>
<div class="patch" id="blue"></div><div class="patch" id="yellow"></div>
<canvas width="80" height="80"></canvas><iframe src="/capture/frame.html"></iframe>
<script>
const context=document.querySelector('canvas').getContext('2d');
context.fillStyle='rgb(255,0,255)';context.fillRect(0,0,80,80);
</script>""",
    "/capture/frame.html": """<!doctype html><meta charset="utf-8">
<title>Arx capture frame</title><style>html,body{margin:0;background:cyan}</style>""",
    "/capture/long.html": """<!doctype html><meta charset="utf-8">
<title>Arx capture layout</title>
<style>
html,body{margin:0}body{width:3200px;height:6000px;background:repeating-linear-gradient(#123456 0 100px,#abcdef 100px 200px)}
header{position:fixed;top:0;left:0;right:0;height:40px;background:#f90}
.sticky{position:sticky;top:40px;height:30px;background:#90f}
.end{position:absolute;top:5800px;left:3000px;background:white}
</style><header>Fixed header</header><div class="sticky">Sticky content</div><div class="end">Document end</div>
<script>
function report(){document.title='Arx capture layout | '+[scrollX,scrollY,innerWidth,innerHeight,devicePixelRatio].join(',')}
addEventListener('load',()=>{scrollTo(37,211);requestAnimationFrame(report)});
addEventListener('scroll',report);addEventListener('resize',report);
</script>""",
    "/capture/dynamic.html": """<!doctype html><meta charset="utf-8">
<title>Arx capture animation</title><style>
html,body{margin:0;background:white}canvas{width:400px;height:400px}
</style><canvas width="400" height="400"></canvas><script>
const context=document.querySelector('canvas').getContext('2d');
function draw(time){context.fillStyle='hsl('+((time/5)%360)+',100%,50%)';context.fillRect(0,0,400,400);requestAnimationFrame(draw)}
requestAnimationFrame(draw);
</script>""",
    "/capture/loading.html": """<!doctype html><meta charset="utf-8">
<title>Arx capture loading</title><style>body{margin:0;background:#246}</style>
<p>Visible while a resource is loading</p><img src="/capture/delayed.svg" width="100" height="100">""",
    "/capture/lazy.html": """<!doctype html><meta charset="utf-8">
<title>Arx capture lazy | unloaded</title><style>
html,body{margin:0}body{height:6000px;background:#def}#target{position:absolute;top:5800px}
</style><p>Visible page content</p><div id="target">Unloaded content</div><script>
const target=document.getElementById('target');
new IntersectionObserver(entries=>{if(entries.some(entry=>entry.isIntersecting)){
 target.textContent='Loaded content';document.title='Arx capture lazy | loaded';
}}).observe(target);
</script>""",
}


def serve(handler):
    """Serve known local cases; unrelated paths remain with the caller's handler."""
    path = urlsplit(handler.path).path
    if path == "/capture/delayed.svg":
        time.sleep(2)
        encoded = b'<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="red"/></svg>'
        handler.send_response(200)
        handler.send_header("Content-Type", "image/svg+xml")
        handler.send_header("Content-Length", str(len(encoded)))
        handler.send_header("Cache-Control", "no-store")
        handler.end_headers()
        try:
            handler.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass
        return True
    body = DOCUMENTS.get(path)
    if body is None:
        return False
    encoded = body.encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(encoded)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(encoded)
    return True
