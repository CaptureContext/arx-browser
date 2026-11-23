"""Exact owned documents for native gesture ACK/CSS and history acceptance."""

import re
from urllib.parse import parse_qs, urlsplit


MODES = {"/gestures/plain.html": "plain", "/gestures/contained.html": "contained",
         "/gestures/scrollable.html": "scrollable"}


def serve(handler):
    target = urlsplit(handler.path)
    mode = MODES.get(target.path)
    if mode is None:
        return False
    query = parse_qs(target.query, keep_blank_values=True)
    if (set(query) != {"case"} or len(query["case"]) != 1
            or not re.fullmatch(r"[a-z0-9-]{1,32}", query["case"][0])):
        handler.send_error(400)
        return True
    width = "4000px" if mode == "scrollable" else "100%"
    overflow = "auto"
    behavior = "contain" if mode == "contained" else "auto"
    position = "scrollTo(600,0);" if mode == "scrollable" else ""
    content = ("<!doctype html><meta charset=utf-8><title>Arx gesture source</title>"
               f"<style>html{{margin:0;overflow:{overflow};overscroll-behavior-x:{behavior}}}"
               f"body{{margin:0;width:{width};height:3000px;background:#dae7f0}}"
               "h1{font:24px system-ui;margin:24px}</style><h1>Owned gesture fixture</h1>"
               f"<script>addEventListener('load',()=>{{{position}}});</script>").encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(content)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(content)
    return True
