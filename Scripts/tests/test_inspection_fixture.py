"""Fixture transport and adversarial semantic cases; actual AX proof is native."""

import io
from html.parser import HTMLParser
import unittest

from Scripts.core import inspection_fixture as fixture


class Document(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.elements = []
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        self.elements.append((tag, dict(attrs)))


class InspectionFixtureTests(unittest.TestCase):
    def test_known_documents_are_exact_bounded_utf8_and_unknown_paths_fall_through(self):
        class Handler:
            def __init__(self, path):
                self.path = path
                self.headers = {}
                self.wfile = io.BytesIO()
                self.status = None

            def send_response(self, status): self.status = status
            def send_header(self, key, value): self.headers[key] = value
            def end_headers(self): pass

        for path, html in fixture.DOCUMENTS.items():
            handler = Handler(path + "?owned=1")
            self.assertTrue(fixture.serve(handler))
            self.assertEqual(handler.status, 200)
            self.assertEqual(handler.wfile.getvalue(), html.encode("utf-8"))
            self.assertEqual(int(handler.headers["Content-Length"]), len(html.encode("utf-8")))
            self.assertEqual(handler.headers["Cache-Control"], "no-store")
        unknown = Handler("/inspection/not-owned")
        self.assertFalse(fixture.serve(unknown))
        self.assertIsNone(unknown.status)

    def test_the_slow_pdf_is_the_whole_pdf_sent_in_two_parts(self):
        class Handler:
            def __init__(self, path):
                self.path = path
                self.headers = {}
                self.wfile = io.BytesIO()
                self.status = None

            def send_response(self, status): self.status = status
            def send_header(self, key, value): self.headers[key] = value
            def end_headers(self): pass

        pause = fixture.SLOW_PDF_PAUSE
        fixture.SLOW_PDF_PAUSE = 0
        try:
            handler = Handler(fixture.SLOW_PDF_PATH)
            self.assertTrue(fixture.serve(handler))
        finally:
            fixture.SLOW_PDF_PAUSE = pause
        self.assertEqual(handler.status, 200)
        self.assertEqual(handler.headers["Content-Type"], "application/pdf")
        self.assertEqual(handler.wfile.getvalue(), fixture.pdf_document())
        self.assertEqual(int(handler.headers["Content-Length"]), len(fixture.pdf_document()))

    def test_secret_values_are_in_controls_or_excluded_surfaces_and_replacement_is_real(self):
        main = fixture.DOCUMENTS["/inspection/main"]
        document = Document(main)
        inputs = [attrs for tag, attrs in document.elements if tag == "input"]
        self.assertIn({"id": "password", "type": "password", "value": "ARX_PASSWORD_SECRET"}, inputs)
        self.assertIn({"id": "former-password", "type": "password",
                       "value": "ARX_FORMER_PASSWORD_SECRET"}, inputs)
        self.assertIn("document.getElementById('former-password').type='text'", main)
        self.assertTrue(any(tag == "button" and attrs.get("aria-labelledby") == "former-password"
                            for tag, attrs in document.elements))
        self.assertTrue(any(attrs.get("value") == "ARX_FORM_VALUE_SECRET" for attrs in inputs))
        self.assertTrue(any(tag == "iframe" and "sandbox" in attrs and
                            "ARX_CROSS_ORIGIN_SECRET" in attrs.get("srcdoc", "")
                            for tag, attrs in document.elements))
        self.assertIn("-webkit-text-security:none", main)
        self.assertIn("attachShadow({mode:'closed'})", main)
        self.assertIn("old.replaceWith(replacement)", main)
        self.assertIn("node.remove();parent.appendChild(node)", main)
        self.assertEqual(main.count("if(!event.isTrusted)"), 2)
        self.assertIn(fixture.SAFE_TEXT, main)
        self.assertIn(fixture.SAFE_SHADOW_TEXT, main)
        self.assertIn(fixture.BUTTON_NAME, main)
        all_documents = "\n".join(fixture.DOCUMENTS.values())
        for sentinel in fixture.EXCLUDED:
            self.assertIn(sentinel, all_documents)
