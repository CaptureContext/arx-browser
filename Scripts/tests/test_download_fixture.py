"""The real browser fixture advertises honest sizes and deterministic collisions."""

import hashlib
import http.client
import http.server
import io
import threading
import unittest
from unittest.mock import patch

from Scripts.core import download_fixture


class Handler:
    def __init__(self, path):
        self.path = path
        self.wfile = io.BytesIO()
        self.headers = {}
        self.close_connection = False

    def send_response(self, status):
        self.status = status

    def send_header(self, name, value):
        self.headers[name] = value

    def end_headers(self):
        pass


class DownloadFixtureTests(unittest.TestCase):
    def test_complete_and_duplicate_share_expected_name_and_real_bytes(self):
        for endpoint in ["complete", "duplicate"]:
            handler = Handler("/downloads/" + endpoint)
            self.assertTrue(download_fixture.serve(handler))
            self.assertEqual(handler.status, 200)
            self.assertEqual(int(handler.headers["Content-Length"]), len(handler.wfile.getvalue()))
            self.assertEqual(hashlib.sha256(handler.wfile.getvalue()).hexdigest(), download_fixture.PAYLOAD_SHA256)
            self.assertIn(download_fixture.FILENAME, handler.headers["Content-Disposition"])
            self.assertTrue(handler.close_connection)

    def test_truncation_advertises_more_than_it_delivers(self):
        handler = Handler("/downloads/truncated")
        download_fixture.serve(handler)
        self.assertEqual(len(handler.wfile.getvalue()), 1024)
        self.assertGreater(int(handler.headers["Content-Length"]), 1024)
        self.assertTrue(handler.close_connection)

    def test_slow_transfer_has_known_size_and_is_throttled(self):
        handler = Handler("/downloads/slow")
        with patch.object(download_fixture.time, "sleep") as sleep:
            download_fixture.serve(handler)
        self.assertEqual(len(handler.wfile.getvalue()), download_fixture.SLOW_BYTES)
        self.assertEqual(int(handler.headers["Content-Length"]), download_fixture.SLOW_BYTES)
        self.assertEqual(sleep.call_count, download_fixture.SLOW_CHUNKS)
        sleep.assert_called_with(0.05)

    def test_cancellation_is_an_expected_disconnect(self):
        class Disconnected:
            def write(self, _):
                raise BrokenPipeError()
        for endpoint in ["slow", "retained"]:
            with self.subTest(endpoint=endpoint):
                handler = Handler("/downloads/" + endpoint)
                handler.wfile = Disconnected()
                self.assertTrue(download_fixture.serve(handler))

    def test_retained_transfer_outlives_the_private_reopening_waits(self):
        handler = Handler("/downloads/retained?smoke=private&tab=one")
        with patch.object(download_fixture.time, "sleep") as sleep:
            self.assertTrue(download_fixture.serve(handler))
        self.assertEqual(len(handler.wfile.getvalue()), download_fixture.SLOW_BYTES)
        self.assertEqual(int(handler.headers["Content-Length"]), download_fixture.SLOW_BYTES)
        # Old progress (30 s), fresh identity (10 s), new progress (30 s).
        # The last advertised bytes must not arrive before this overlap window.
        before_last_chunk = sum(call.args[0] for call in sleep.call_args_list[:-1])
        self.assertGreater(before_last_chunk, 70)

    def test_unrelated_requests_fall_through(self):
        handler = Handler("/index.html")
        self.assertFalse(download_fixture.serve(handler))
        self.assertEqual(handler.wfile.getvalue(), b"")


class ResumableFixtureTests(unittest.TestCase):
    """DEV-892: a paused or interrupted transfer continues from where it stopped."""

    def test_full_response_advertises_ranges_and_a_validator(self):
        handler = Handler("/downloads/resumable")
        with patch.object(download_fixture.time, "sleep"):
            self.assertTrue(download_fixture.serve(handler))
        self.assertEqual(handler.status, 200)
        self.assertEqual(handler.headers["Accept-Ranges"], "bytes")
        self.assertEqual(handler.headers["ETag"], download_fixture.RESUMABLE_ETAG)
        self.assertEqual(len(handler.wfile.getvalue()), download_fixture.SLOW_BYTES)

    def test_range_request_continues_and_is_recorded(self):
        class Server:
            download_ranges = []
        handler = Handler("/downloads/resumable")
        handler.server = Server()
        handler.headers.update({"Range": "bytes=1048576-", "If-Range": download_fixture.RESUMABLE_ETAG})
        with patch.object(download_fixture.time, "sleep"):
            download_fixture.serve(handler)
        self.assertEqual(handler.status, 206)
        self.assertEqual(len(handler.wfile.getvalue()), download_fixture.SLOW_BYTES - 1048576)
        self.assertEqual(handler.headers["Content-Range"],
                         f"bytes 1048576-{download_fixture.SLOW_BYTES - 1}/{download_fixture.SLOW_BYTES}")
        self.assertEqual(Server.download_ranges, [1048576])

    def test_a_real_server_answers_with_strong_validators_and_a_range(self):
        # DEV-966: over a real socket, as Chromium sees it. Chromium keeps the validators, and
        # resumes after a quit, only from an HTTP/1.1 response.
        class Server(http.server.ThreadingHTTPServer):
            download_ranges = []

        class RealHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                download_fixture.serve(self)

            def log_message(self, *arguments):
                pass

        server = Server(("127.0.0.1", 0), RealHandler)
        server.download_ranges = []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        def get(headers):
            connection = http.client.HTTPConnection(*server.server_address, timeout=10)
            self.addCleanup(connection.close)
            connection.request("GET", "/downloads/resumable?smoke=resume", headers=headers)
            response = connection.getresponse()
            return response, response.read()

        with patch.object(download_fixture.time, "sleep"):
            full, body = get({})
            self.assertEqual((full.version, full.status), (11, 200))
            etag = full.getheader("ETag")
            self.assertEqual(etag, download_fixture.RESUMABLE_ETAG)
            self.assertFalse(etag.upper().startswith("W/"))
            self.assertIsNotNone(full.getheader("Last-Modified"))
            self.assertIsNotNone(full.getheader("Date"))
            self.assertEqual(full.getheader("Accept-Ranges"), "bytes")
            self.assertEqual(len(body), download_fixture.SLOW_BYTES)

            start = 655360
            partial, rest = get({"Range": f"bytes={start}-", "If-Range": etag})
            self.assertEqual((partial.version, partial.status), (11, 206))
            self.assertEqual(partial.getheader("Content-Range"),
                             f"bytes {start}-{download_fixture.SLOW_BYTES - 1}/{download_fixture.SLOW_BYTES}")
            self.assertEqual(len(rest), download_fixture.SLOW_BYTES - start)
        self.assertEqual(server.download_ranges, [start])

    def test_stale_validator_starts_over(self):
        handler = Handler("/downloads/resumable")
        handler.headers.update({"Range": "bytes=1048576-", "If-Range": '"other"'})
        with patch.object(download_fixture.time, "sleep"):
            download_fixture.serve(handler)
        self.assertEqual(handler.status, 200)
        self.assertEqual(len(handler.wfile.getvalue()), download_fixture.SLOW_BYTES)
