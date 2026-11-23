"""Local failure smoke fixtures; these never launch the application."""

import socket
import ssl
import unittest
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

from Scripts import local_failure_smoke


class LocalFailureSmokeTests(unittest.TestCase):
    def setUp(self):
        self.server = local_failure_smoke.plain_server()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.port = self.server.server_port

    def test_plain_server_answers_http_with_its_title(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{local_failure_smoke.PLAIN_PATH}", timeout=5) as response:
            self.assertEqual(response.status, 200)
            self.assertIn(f"<title>{local_failure_smoke.PLAIN_TITLE}</title>", response.read().decode())

    def test_plain_server_fails_a_tls_handshake(self):
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as connection:
            with self.assertRaises((ssl.SSLError, ConnectionResetError)):
                context.wrap_socket(connection, server_hostname="127.0.0.1").close()

    def test_environment_names_loopback_https_for_the_plain_server(self):
        environment = local_failure_smoke.environment(Path("/tmp/profile"), 1, 2, self.port)
        plain = urlsplit(environment["ARX_LOCAL_FAILURE_PLAIN_URL"])
        self.assertEqual((plain.scheme, plain.hostname, plain.port), ("https", "127.0.0.1", self.port))
        self.assertEqual(f"{plain.path}?{plain.query}", local_failure_smoke.PLAIN_PATH)
        self.assertEqual(environment["ARX_LOCAL_FAILURE_PLAIN_TITLE"], local_failure_smoke.PLAIN_TITLE)
        self.assertEqual(environment["ARX_ENGINE_URL"], "http://127.0.0.1:1/")
        self.assertEqual(environment["ARX_LOCAL_FAILURE_TLS_URL"], "https://127.0.0.1:2/")
        self.assertEqual(environment["ARX_ENGINE_PROFILE"], "/tmp/profile")
        # DEV-1226: a .invalid name never resolves, online or off.
        unresolved = urlsplit(environment["ARX_LOCAL_FAILURE_UNRESOLVED_URL"])
        self.assertTrue(unresolved.hostname.endswith(".invalid"))


if __name__ == "__main__":
    unittest.main()
