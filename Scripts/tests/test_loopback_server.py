"""The app smoke's fixture serves on both loopback addresses at one port (DEV-1000)."""

import errno
import http.client
import http.server
import socket
import unittest
from unittest import mock

from Scripts.core import loopback_server


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.hosts.append(self.headers.get("Host"))
        body = b"served"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def get(address, port, host):
    connection = http.client.HTTPConnection(address, port, timeout=5)
    try:
        connection.request("GET", "/page.html", headers={"Host": f"{host}:{port}"})
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def has_ipv6_loopback():
    try:
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as probe:
            probe.bind(("::1", 0))
        return True
    except OSError:
        return False


class LoopbackServerTests(unittest.TestCase):
    @unittest.skipUnless(has_ipv6_loopback(), "No IPv6 loopback on this machine")
    def test_serves_both_loopback_addresses_at_one_port_with_one_state(self):
        loopback = loopback_server.LoopbackServer(Handler)
        loopback.server.hosts = []
        loopback.start()
        try:
            port = loopback.server.server_port
            self.assertEqual(loopback.companion.server_address[1], port)
            self.assertEqual(get("127.0.0.1", port, "127.0.0.1"), (200, b"served"))
            self.assertEqual(get("::1", port, "localhost"), (200, b"served"))
            # localhost, as a browser resolves it, whichever address it tries first.
            for family, _, _, _, address in socket.getaddrinfo("localhost", port, type=socket.SOCK_STREAM):
                with self.subTest(family=family):
                    self.assertEqual(get(address[0], port, "localhost"), (200, b"served"))
            self.assertIn("localhost:%d" % port, loopback.server.hosts)
            self.assertIn("127.0.0.1:%d" % port, loopback.server.hosts)
        finally:
            loopback.stop()

    def test_a_port_taken_on_ipv6_is_skipped(self):
        real = loopback_server.Companion.__init__
        calls = []

        def busy_once(companion, main):
            calls.append(main.server_port)
            if len(calls) == 1:
                raise OSError(errno.EADDRINUSE, "taken")
            real(companion, main)

        with mock.patch.object(loopback_server.Companion, "__init__", busy_once):
            try:
                loopback = loopback_server.LoopbackServer(Handler)
            except OSError as error:
                self.skipTest(f"No IPv6 loopback on this machine: {error}")
        try:
            self.assertEqual(len(calls), 2)
            self.assertEqual(loopback.server.server_port, calls[1])
        finally:
            loopback.stop()

    def test_without_ipv6_it_serves_127_0_0_1_alone(self):
        def unavailable(companion, main):
            raise OSError(errno.EADDRNOTAVAIL, "no IPv6")

        with mock.patch.object(loopback_server.Companion, "__init__", unavailable):
            loopback = loopback_server.LoopbackServer(Handler)
        loopback.server.hosts = []
        loopback.start()
        try:
            self.assertIsNone(loopback.companion)
            self.assertEqual(get("127.0.0.1", loopback.server.server_port, "127.0.0.1"), (200, b"served"))
        finally:
            loopback.stop()

    def test_gives_up_when_no_port_is_free_on_both(self):
        def busy(companion, main):
            raise OSError(errno.EADDRINUSE, "taken")

        with mock.patch.object(loopback_server.Companion, "__init__", busy):
            with self.assertRaises(OSError):
                loopback_server.LoopbackServer(Handler, attempts=3)


if __name__ == "__main__":
    unittest.main()
