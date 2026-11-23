"""Controlled loading is explicitly released and cannot strand a server worker."""

import io
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import Mock

from Scripts.core import wait_fixture as fixture


class Handler:
    def __init__(self, server, path):
        self.server = server
        self.path = path
        self.status = None
        self.headers = {}
        self.wfile = io.BytesIO()

    def send_response(self, status): self.status = status
    def send_header(self, name, value): self.headers[name] = value
    def end_headers(self): pass


class WaitFixtureTests(unittest.TestCase):
    def setUp(self):
        self.server = SimpleNamespace()
        fixture.prepare(self.server)
        self.addCleanup(fixture.release, self.server)

    def test_committed_document_has_one_controlled_subresource_and_no_mutation_script(self):
        main = Handler(self.server, "/wait/main")
        self.assertTrue(fixture.serve(main))
        self.assertEqual(main.status, 200)
        self.assertEqual(main.wfile.getvalue(), fixture.MAIN)
        self.assertEqual(main.headers["Cache-Control"], "no-store")
        self.assertEqual(fixture.MAIN.count(b'<img '), 1)
        self.assertIn(b'<title>Arx wait committed</title>', fixture.MAIN)
        self.assertNotIn(b'<script', fixture.MAIN)
        self.assertFalse(fixture.serve(Handler(self.server, "/wait/unknown")))

    def test_release_and_teardown_unblock_only_the_owned_server_gate(self):
        for teardown in (False, True):
            with self.subTest(teardown=teardown):
                fixture.prepare(self.server)
                waiting = threading.Event()
                gate = self.server.wait_image_release
                original_wait = gate.wait

                def wait(timeout):
                    self.assertEqual(timeout, 12)
                    waiting.set()
                    return original_wait(timeout)

                gate.wait = wait
                image = Handler(self.server, "/wait/image")
                worker = threading.Thread(target=fixture.serve, args=(image,))
                worker.start()
                try:
                    self.assertTrue(waiting.wait(1))
                    self.assertIsNone(image.status)
                    if teardown:
                        fixture.release(self.server)
                    else:
                        release = Handler(self.server, "/wait/release")
                        self.assertTrue(fixture.serve(release))
                        self.assertEqual(release.wfile.getvalue(), b"released")
                    worker.join(1)
                    self.assertFalse(worker.is_alive())
                    self.assertEqual(image.status, 200)
                    self.assertEqual(image.wfile.getvalue(), fixture.PNG)
                finally:
                    fixture.release(self.server)
                    worker.join(1)

    def test_unreleased_image_expires_without_claiming_success_and_disconnect_is_tolerated(self):
        self.server.wait_image_release = Mock()
        self.server.wait_image_release.wait.return_value = False
        image = Handler(self.server, "/wait/image")
        self.assertTrue(fixture.serve(image))
        self.server.wait_image_release.wait.assert_called_once_with(12)
        self.assertEqual(image.status, 503)
        self.assertEqual(image.wfile.getvalue(), b"expired")
        self.server.wait_image_release.wait.return_value = True
        image.wfile = Mock()
        image.wfile.write.side_effect = BrokenPipeError
        self.assertTrue(fixture.serve(image))
