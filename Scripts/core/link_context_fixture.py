"""Own HTTP-only renderer targets for the native link context-menu fixture."""
from urllib.parse import urlsplit

MAIN = '''<!doctype html><meta charset="utf-8"><title>Arx link context ready</title>
<style>body{margin:0}a{position:absolute;left:20px;top:20px;width:300px;height:60px}
iframe{position:absolute;border:0;left:40px;top:150px;width:400px;height:200px}</style>
<a href="https://capturecontext.dev/main?a=1&amp;a=2#fragment">Main [link]</a>
<iframe src="/link-context/frame" onload="document.title='Arx link context ready'"></iframe>'''
FRAME = '''<!doctype html><meta charset="utf-8"><style>body{margin:0}
a{position:absolute;left:20px;top:20px;width:300px;height:60px}</style>
<a href="https://capturecontext.dev/frame?a=1&amp;a=2#fragment">Frame [link]</a>
<script>addEventListener("contextmenu",()=>setTimeout(()=>location.replace("/link-context/frame-destination"),800));</script>'''

# DEV-853: links that Arx's own filter used to refuse: a non-default port and mailto:.
SCHEMES = '''<!doctype html><meta charset="utf-8"><title>Arx link context ready</title>
<style>body{margin:0}a{position:absolute;left:20px;width:300px;height:60px}#port{top:20px}#mail{top:120px}</style>
<a id="port" href="http://localhost:3000/port?a=1">Port [link]</a>
<a id="mail" href="mailto:hello@capturecontext.dev?subject=Arx">Mail [link]</a>'''


# DEV-851: a link to a file the server sends only to a request whose referrer is this page,
# as hotlink protection does.
DOWNLOAD = '''<!doctype html><meta charset="utf-8"><title>Arx link context ready</title>
<style>body{margin:0}a{position:absolute;left:20px;top:20px;width:300px;height:60px}</style>
<a href="/link-context/protected.bin">Download [link]</a>'''
PROTECTED = b"arx-referrer-ok"


# DEV-814 context menus: a text field and a password field, a selection, an image
# and a video, with blank page around them. Each page selects what its phase needs.
MENU_STYLE = """<meta charset="utf-8"><style>body{margin:0;font:16px sans-serif}
input{position:absolute;left:20px;width:300px;height:30px}#field{top:20px}#secret{top:70px}
p{position:absolute;left:20px;top:120px;margin:0}img{position:absolute;left:20px;top:170px;width:80px;height:80px}
video{position:absolute;left:120px;top:170px;width:160px;height:90px;background:#000}</style>"""
MENU_FIELD = MENU_STYLE + """<title>Arx context menus ready</title>
<input id="field" value="arx context words"><input id="secret" type="password" value="arx-secret-value">
<script>field.focus();field.select();</script>"""
MENU_WORDS = MENU_STYLE + """<title>Arx context menus ready</title><p id="words">Selected words here</p>
<script>getSelection().selectAllChildren(words);</script>"""
MENU_MEDIA = MENU_STYLE + """<title>Arx context menus ready</title>
<img src="/link-context/pixel.png" alt=""><video src="/link-context/clip.mp4" muted></video>"""
PIXEL = bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
                      "0000000d49444154789c635068f8ff1f000502029f76a846c90000000049454e44ae426082")


def serve(handler):
    request = urlsplit(handler.path)
    pages = {"/link-context/main": MAIN, "/link-context/frame": FRAME,
             "/link-context/frame-destination": "<!doctype html><title>Frame replaced</title>",
             "/link-context/destination": "<!doctype html><title>Arx link destination</title>",
             "/link-context/schemes": SCHEMES,
             "/link-context/download": DOWNLOAD,
             "/link-context/menu-field": "<!doctype html>" + MENU_FIELD,
             "/link-context/menu-words": "<!doctype html>" + MENU_WORDS,
             "/link-context/menu-media": "<!doctype html>" + MENU_MEDIA}
    if not request.path.startswith("/link-context/"):
        return False
    if request.path == "/link-context/protected.bin" and not request.query:
        page = f"http://{handler.headers.get('Host', '')}/link-context/download"
        allowed = handler.headers.get("Referer") == page
        body = PROTECTED if allowed else b""
        handler.send_response(200 if allowed else 403)
        handler.send_header("Content-Type", "application/octet-stream")
        handler.send_header("Content-Disposition", 'attachment; filename="protected.bin"')
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)
        return True
    if request.path == "/link-context/pixel.png" and not request.query:
        handler.send_response(200)
        handler.send_header("Content-Type", "image/png")
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("Content-Length", str(len(PIXEL)))
        handler.end_headers()
        handler.wfile.write(PIXEL)
        return True
    body = pages.get(request.path) if not request.query else None
    data = (body or "").encode()
    handler.send_response(200 if body else 404)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)
    return True
