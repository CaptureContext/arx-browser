"""Validate that native image smoke can load every controlled document and frame."""

import http.server
import threading
import unittest
import urllib.error
import urllib.request

from Scripts.core import capture_fixture


class CaptureFixtureTests(unittest.TestCase):
    def test_serves_complete_documents_frames_and_falls_through_unknown_paths(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if not capture_fixture.serve(self):
                    self.send_error(404)

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_port}"
            for path in capture_fixture.DOCUMENTS:
                with self.subTest(path=path), urllib.request.urlopen(base + path + "?run=fixture") as response:
                    body = response.read()
                    self.assertEqual(len(body), int(response.headers["Content-Length"]))
                    self.assertEqual(response.headers["Cache-Control"], "no-store")
                    self.assertEqual(response.headers.get_content_charset(), "utf-8")
                    self.assertTrue(body.startswith(b"<!doctype html>"))
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(base + "/capture/not-a-fixture.html")
            self.assertEqual(error.exception.code, 404)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
