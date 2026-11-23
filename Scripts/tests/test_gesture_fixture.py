"""Bound native gesture fixture documents and prevent filesystem fallback."""
import io
import unittest
from unittest.mock import Mock, patch

from Scripts.core import gesture_fixture
from Scripts.engine import smoke


class GestureFixtureTests(unittest.TestCase):
    def handler(self, path):
        handler = Mock()
        handler.path = path
        handler.wfile = io.BytesIO()
        return handler

    def test_documents_have_real_scroll_and_css_arbitration_states(self):
        for mode in ["plain", "contained", "scrollable"]:
            with self.subTest(mode=mode):
                handler = self.handler(f"/gestures/{mode}.html?case=seed-1")
                self.assertTrue(gesture_fixture.serve(handler))
                handler.send_response.assert_called_once_with(200)
                handler.send_header.assert_any_call("Cache-Control", "no-store")
                body = handler.wfile.getvalue().decode()
                self.assertIn("Arx gesture source", body)
                self.assertIn("overscroll-behavior-x:" + ("contain" if mode == "contained" else "auto"), body)
                self.assertEqual("scrollTo(600,0)" in body, mode == "scrollable")
                self.assertEqual("4000px" in body, mode == "scrollable")

    def test_query_is_bounded_and_never_reflected(self):
        for query in ["", "case=", "case=x&case=y", "case=x&other=y", "case=" + "a" * 33,
                      "case=%3Cscript%3E", "case=../profile"]:
            with self.subTest(query=query):
                handler = self.handler("/gestures/plain.html?" + query)
                self.assertTrue(gesture_fixture.serve(handler))
                handler.send_error.assert_called_once_with(400)
                self.assertEqual(handler.wfile.getvalue(), b"")

    def test_handler_never_serves_profile_or_directory(self):
        handler = object.__new__(smoke.GestureHandler)
        handler.send_error = Mock()
        with patch.object(smoke.http.server.SimpleHTTPRequestHandler, "do_GET") as serve_file:
            for path in ["/", "/profile/Default/Preferences", "/.arx-engine-smoke", "/gestures/unknown.html"]:
                handler.path = path
                handler.do_GET()
            self.assertEqual(handler.send_error.call_count, 4)
            serve_file.assert_not_called()
            handler.path = "/index.html"
            handler.do_GET()
            serve_file.assert_called_once()

    def test_fixture_modes_are_exclusive_before_build(self):
        with patch.object(smoke.host, "main") as build:
            with self.assertRaisesRegex(ValueError, "Choose one"):
                smoke.run(None, gestures=True, reference_click=True)
            build.assert_not_called()
