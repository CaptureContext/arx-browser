"""Loopback pages the eval tasks work on, and what the form received.

The pages look like ordinary sites: a menu, a footer and a sidebar around the part that matters,
so reading only the main content pays off. Form posts are kept in memory for the checks.
"""

import html
import http.server
import threading
import urllib.parse

CHROME = """<header><nav><a href="/">Home</a> · <a href="/news">News</a> · <a href="/shop">Shop</a>
· <a href="/about">About</a> · <a href="/contact">Contact</a></nav></header>"""
FOOTER = """<aside><h2>Popular</h2><ul><li>Ten bridges worth a detour</li><li>The ferry timetable, explained</li>
<li>Where the river floods</li></ul></aside><footer><p>© Riverside Courier. All rights reserved.</p>
<p>Privacy · Terms · Cookies · Advertise · Careers</p></footer>"""


def page(title, body):
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><title>{html.escape(title)}</title></head>
<body>{CHROME}<main>{body}</main>{FOOTER}</body></html>"""


ARTICLE = page("The Old Bridge turns 94", """<article><h1>The Old Bridge turns 94</h1>
<p>Few people crossing the river each morning stop to look at the Old Bridge, but its story is a long one.</p>
<p>Work began in 1929, after two winters of floods washed away the wooden crossing that stood there before.
The engineer, Marta Hollis, chose stone over steel because the quarry upstream could supply it by barge.</p>
<p>The Old Bridge opened to traffic in 1932, a year late, after the third arch had to be rebuilt.</p>
<p>Today about 18,000 cars and twice as many bicycles cross it every day.</p></article>""")

FORM = page("Contact us", """<h1>Contact us</h1><p>We answer within two working days.</p>
<form method="post" action="/submit">
<p><label for="name">Name</label> <input id="name" name="name" type="text"></p>
<p><label for="email">Email</label> <input id="email" name="email" type="text" inputmode="email" autocomplete="email"></p>
<p><label for="topic">Topic</label> <select id="topic" name="topic">
<option value="">Choose…</option><option value="billing">Billing</option>
<option value="delivery">Delivery</option><option value="other">Something else</option></select></p>
<p><label for="message">Message</label> <textarea id="message" name="message"></textarea></p>
<p><button type="submit">Send message</button></p>
</form>""")

NEWSLETTER = page("Newsletter", """<h1>The Courier's weekly letter</h1><p>One email on Fridays, nothing else.</p>
<form method="post" action="/submit">
<p><label for="address">Email address</label> <input id="address" name="address" type="email" required></p>
<p><button type="submit">Subscribe</button></p>
</form>""")

THANKS = page("Message sent", "<h1>Thanks, your message is on its way.</h1><p>We answer within two working days.</p>")

PRODUCTS = {
    "/shop/kettle-a": page("Brightline kettle", """<h1>Brightline kettle</h1>
<p>1.7 litres, stainless steel, boils in under three minutes.</p><p class="price">Price: €34.90</p>
<p>In stock. Delivery in 2–3 days.</p>"""),
    "/shop/kettle-b": page("Northwind kettle", """<h1>Northwind kettle</h1>
<p>1.5 litres, glass with a blue light while it boils.</p><p class="price">Price: €29.50</p>
<p>In stock. Delivery tomorrow.</p>"""),
}

PAGES = {"/article": ARTICLE, "/contact": FORM, "/newsletter": NEWSLETTER, **PRODUCTS}


class Fixture:
    """A loopback server for one eval run. `submissions` holds each form post, in order."""

    def __init__(self):
        self.submissions = []
        self.lock = threading.Lock()
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = PAGES.get(self.path.split("?", 1)[0])
                self.reply(200 if body else 404, body or page("Not found", "<h1>Not found</h1>"))

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                fields = urllib.parse.parse_qs(self.rfile.read(length).decode(), keep_blank_values=True)
                with fixture.lock:
                    fixture.submissions.append({key: values[-1] for key, values in fields.items()})
                self.reply(200, THANKS)

            def reply(self, status, body):
                data = body.encode()
                self.send_response(status)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()

    def url(self, path):
        return f"http://127.0.0.1:{self.server.server_port}{path}"

    def posted(self):
        with self.lock:
            return list(self.submissions)

    def clear(self):
        with self.lock:
            self.submissions.clear()
