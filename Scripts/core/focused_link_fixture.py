"""Own HTTP-only pages for the native focused-link fixture (DEV-713).

Every page focuses its target with script once it loads and then sets the ready
title, so the host never needs real keyboard input. Frames tell their parent
through postMessage; the cross-site frame is served from localhost while the
page is on 127.0.0.1, so it gets its own renderer.
"""
from urllib.parse import urlsplit

READY = "Arx focused link ready"
MAIN_LINK = "https://capturecontext.dev/focused/main?a=1#fragment"
FRAME_LINK = "https://capturecontext.dev/focused/frame"
SHADOW_LINK = "https://capturecontext.dev/focused/shadow"

STYLE = "<style>a,input,button{display:block;margin:20px}</style>"


def page(body, script):
    return (f'<!doctype html><meta charset="utf-8"><title>Arx focused link</title>{STYLE}{body}'
            f'<script>addEventListener("load",()=>{{{script}}});</script>')


def framed(source):
    return page(f'<a id="outer" href="https://capturecontext.dev/focused/outer">Outer</a>'
                f'<iframe src="{source}"></iframe>',
                f'addEventListener("message",e=>{{if(e.data==="focused")document.title="{READY}"}});')


FOCUS = f'document.getElementById("target").focus();document.title="{READY}";'
PAGES = {
    "link": page(f'<a id="target" href="{MAIN_LINK}">Main link</a>', FOCUS),
    "nested": page('<a href="https://capturecontext.dev/focused/nested"><span id="target" tabindex="0">'
                   'Span in a link</span></a>', FOCUS),
    "shadow": page('<div id="host"></div>',
                   'const root=document.getElementById("host").attachShadow({mode:"open"});'
                   f'root.innerHTML=\'<a id="target" href="{SHADOW_LINK}">Shadow link</a>\';'
                   f'root.getElementById("target").focus();document.title="{READY}";'),
    "svg": page('<svg width="200" height="40"><a id="target" tabindex="0" href="/focused/svg?a=1">'
                '<text x="0" y="20">SVG link</text></a></svg>', FOCUS),
    "field": page('<a href="https://capturecontext.dev/focused/near-field">Link</a>'
                  '<input id="target" value="text">', FOCUS),
    "field-in-link": page('<a href="https://capturecontext.dev/focused/around-field">'
                          '<input id="target" value="text"></a>', FOCUS),
    "button": page('<a href="https://capturecontext.dev/focused/near-button">Link</a>'
                   '<button id="target">Button</button>', FOCUS),
    "none": page('<a href="https://capturecontext.dev/focused/unfocused">Link</a>',
                 f'document.title="{READY}";'),
    "script-link": page('<a id="target" href="javascript:void(0)">Script link</a>', FOCUS),
    "credentials": page('<a id="target" href="https://user:secret@capturecontext.dev/focused">'
                        'Credentials</a>', FOCUS),
    "same-frame": framed("/focused-link/frame"),
    "cross-frame": framed("http://localhost:PORT/focused-link/frame"),
    "frame": page(f'<a id="target" href="{FRAME_LINK}">Frame link</a>',
                  'document.getElementById("target").focus();parent.postMessage("focused","*");'),
}


def serve(handler):
    request = urlsplit(handler.path)
    if not request.path.startswith("/focused-link/"):
        return False
    name = request.path.removeprefix("/focused-link/")
    body = PAGES.get(name) if not request.query else None
    if body:
        body = body.replace("PORT", str(handler.server.server_port))
    data = (body or "").encode()
    handler.send_response(200 if body else 404)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)
    return True
