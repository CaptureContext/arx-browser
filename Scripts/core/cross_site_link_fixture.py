"""Own HTTP-only pages for the native cross-site link fixture (DEV-727).

Pages are served from 127.0.0.1; links "to another site" go to localhost on the
same port, which Chromium counts as a different site. Every source page is one
link or button filling the window, so a click anywhere in it activates it.
"""
from urllib.parse import urlsplit

READY = "Arx cross-site ready"
ARRIVED = "Arx cross-site arrived"

STYLE = ("<style>html,body,form{margin:0;height:100%}a,button{display:block;width:100%;height:100%;"
         "border:0;margin:0;font:20px system-ui}</style>")


def page(body, script=f'document.title="{READY}";'):
    return (f'<!doctype html><meta charset="utf-8"><title>Arx cross-site</title>{STYLE}{body}'
            f'<script>addEventListener("load",()=>{{{script}}});</script>')


def link(href):
    return page(f'<a id="target" href="{href}">Link</a>')


SAME = "http://127.0.0.1:PORT/cross-site-link/arrived"
OTHER = "http://localhost:PORT/cross-site-link/arrived"
PAGES = {
    "same-site": link(SAME),
    "cross-site": link(OTHER),
    "redirect": link("/cross-site-link/redirect-to-other"),
    "form-post": page(f'<form method="post" action="{OTHER}"><button id="target">Post</button></form>'),
    "scripted": page('<p>Scripted</p>', f'document.title="{READY}";'
                     f'setTimeout(()=>{{location.href="{OTHER}?scripted"}},300);'),
    "arrived": page("<p>Arrived</p>", f'document.title="{ARRIVED}";'),
}


def respond(handler, status, body=b"", headers=()):
    handler.send_response(status)
    for name, value in headers:
        handler.send_header(name, value)
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def serve(handler):
    request = urlsplit(handler.path)
    if not request.path.startswith("/cross-site-link/"):
        return False
    port = str(handler.server.server_port)
    name = request.path.removeprefix("/cross-site-link/")
    if handler.command == "POST":
        length = int(handler.headers.get("Content-Length") or 0)
        handler.rfile.read(min(length, 4096))
        name = "arrived" if name == "arrived" else ""
    if name == "redirect-to-other" and not request.query:
        respond(handler, 302, headers=[("Location", OTHER.replace("PORT", port))])
        return True
    body = PAGES.get(name) if name == "arrived" or not request.query else None
    if not body:
        respond(handler, 404)
        return True
    respond(handler, 200, body.replace("PORT", port).encode(),
            [("Content-Type", "text/html; charset=utf-8")])
    return True
