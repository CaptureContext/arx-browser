"""The search fixture distinguishes URL component errors and requires native evidence."""

import http.server
import json
import re
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import urlopen

from Scripts.core import bang_smoke


class BangSmokeTests(unittest.TestCase):
    def test_server_decodes_query_and_single_path_segment_independently(self):
        encoded = "swift%20%26%20%E6%9D%B1%E4%BA%AC%2Fcaf%C3%A9%2B100%25%20%23%3F%21"
        expected = "swift & 東京/café+100% #?!"
        for path, mode in (("/bang-search/query?q=", "query"), ("/bang-search/bundled?q=", "bundled"), ("/bang-search/path/", "path")):
            with self.subTest(mode=mode):
                body = bang_smoke.document(path + encoded).decode()
                payload = re.search(r"const \[mode, query, identity\] = (.*);", body).group(1)
                self.assertEqual(json.loads(payload), [mode, expected, None])
                self.assertIn("localStorage.getItem('arx_bang_identity')", body)
                self.assertIn("document.cookie.split('; ')", body)

    def test_delimiter_leaks_cannot_masquerade_as_a_valid_search(self):
        for path in (
            "/bang-search/query?q=swift&other=value",
            "/bang-search/query?q=one&q=two",
            "/bang-search/bundled?q=swift&other=value",
            "/bang-search/bundled/swift",
            "/bang-search/path/swift/concurrency",
            "/bang-search/path/swift?extra=query",
            "/bang-search/seed?identity=uncontrolled",
            "/bang-search/seed?identity=ordinary&identity=secondary",
        ):
            with self.subTest(path=path):
                self.assertIsNone(bang_smoke.document(path))
        body = bang_smoke.document("/bang-search/query?q=%3C%2Fscript%3E").decode()
        self.assertNotIn('"</script>"', body)
        self.assertIn('"\\u003c/script>"', body)

    def test_owned_http_routes_serve_uncached_documents_and_reject_bad_requests(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if not bang_smoke.serve(self):
                    self.send_error(404)

            def log_message(self, *_):
                pass

        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                base = f"http://127.0.0.1:{server.server_port}"
                with urlopen(base + "/bang-search/seed?identity=secondary", timeout=2) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.headers["Cache-Control"], "no-store")
                    self.assertEqual(response.headers["Content-Type"], "text/html; charset=utf-8")
                    self.assertIn(b'["seed", "", "secondary"]', response.read())
                with self.assertRaises(HTTPError) as caught:
                    urlopen(base + "/bang-search/path/unescaped/slash", timeout=2)
                self.assertEqual(caught.exception.code, 400)
                caught.exception.close()
            finally:
                server.shutdown()
                thread.join()

    def test_every_exact_native_phase_marker_is_mandatory(self):
        bang_smoke.verify("\n".join(bang_smoke.MARKERS))
        for omitted in bang_smoke.MARKERS:
            remaining = "\n".join(marker for marker in bang_smoke.MARKERS if marker != omitted)
            for diagnostic in ("", "pending " + omitted, omitted + "_PENDING"):
                with self.subTest(omitted=omitted, diagnostic=diagnostic):
                    with self.assertRaisesRegex(ValueError, "Bang navigation smoke did not complete"):
                        bang_smoke.verify(remaining + "\n" + diagnostic)


if __name__ == "__main__":
    unittest.main()
