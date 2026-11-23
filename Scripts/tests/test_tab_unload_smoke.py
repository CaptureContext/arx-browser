"""Tab unload smoke fixtures; these never launch the application."""

import unittest
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path

from Scripts import tab_unload_smoke


class TabUnloadSmokeTests(unittest.TestCase):
    def setUp(self):
        self.server = tab_unload_smoke.server()
        self.addCleanup(self.server.server_close)
        self.addCleanup(tab_unload_smoke.stop, self.server)
        self.port = self.server.server_port

    def test_pages_are_never_cached_and_are_counted(self):
        for path, title in tab_unload_smoke.PAGES.items():
            with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=5) as response:
                self.assertEqual(response.headers["Cache-Control"], "no-store")
                self.assertIn(f"<title>{title}</title>", response.read().decode())
        self.assertEqual(tab_unload_smoke.Fixture.requests, Counter(tab_unload_smoke.PAGES.keys()))

    def test_unknown_paths_are_missing(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(f"http://127.0.0.1:{self.port}/elsewhere", timeout=5)
        self.assertEqual(error.exception.code, 404)

    def test_environment_points_every_page_at_the_server(self):
        environment = tab_unload_smoke.environment(Path("/tmp/profile"), self.port)
        base = f"http://127.0.0.1:{self.port}"
        self.assertEqual(environment["ARX_ENGINE_URL"], f"{base}/first")
        self.assertEqual(environment["ARX_TAB_UNLOAD_SECOND_URL"], f"{base}/second")
        self.assertEqual(environment["ARX_TAB_UNLOAD_OTHER_URL"], f"{base}/other")
        self.assertEqual(environment["ARX_TAB_UNLOAD_SECOND_TITLE"], tab_unload_smoke.PAGES["/second"])
        self.assertEqual(environment["ARX_TAB_UNLOAD_SMOKE"], "1")
        self.assertEqual(environment["ARX_TAB_UNLOAD_LIVE_URL"], f"{base}/live")
        self.assertEqual(environment["ARX_TAB_UNLOAD_LIVE_TITLE"], tab_unload_smoke.LIVE_TITLE)
        self.assertEqual(environment["ARX_TAB_UNLOAD_LIVE_WAIT"], str(tab_unload_smoke.LIVE_WAIT))

    def test_the_ask_page_asks_only_once_it_holds_text(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/ask", timeout=5) as response:
            self.assertEqual(response.headers["Cache-Control"], "no-store")
            page = response.read().decode()
        self.assertIn(f"<title>{tab_unload_smoke.ASK_TITLE}</title>", page)
        self.assertIn(tab_unload_smoke.ASK_TYPED_TITLE, page)
        self.assertIn('addEventListener("beforeunload"', page)
        self.assertIn("if (field.value) { event.preventDefault();", page)
        environment = tab_unload_smoke.environment(Path("/tmp/profile"), self.port)
        self.assertEqual(environment["ARX_TAB_UNLOAD_ASK_URL"], f"http://127.0.0.1:{self.port}/ask")
        self.assertEqual(environment["ARX_TAB_UNLOAD_ASK_TITLE"], tab_unload_smoke.ASK_TITLE)
        self.assertEqual(environment["ARX_TAB_UNLOAD_ASK_TYPED_TITLE"], tab_unload_smoke.ASK_TYPED_TITLE)

    def test_the_live_page_opens_a_socket_and_names_its_state(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/live", timeout=5) as response:
            self.assertEqual(response.headers["Cache-Control"], "no-store")
            page = response.read().decode()
        self.assertIn("new WebSocket(`ws://${location.host}/socket`)", page)
        self.assertIn(tab_unload_smoke.LIVE_TITLE, page)
        self.assertIn('fetch("/closed")', page)
        self.assertIn('fetch("/frozen")', page)

    def test_the_socket_upgrades_and_sends_ticks(self):
        import socket
        connection = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        self.addCleanup(connection.close)
        connection.sendall(b"GET /socket HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
        received = b""
        while b"tick 1" not in received:
            chunk = connection.recv(1024)
            self.assertTrue(chunk)
            received += chunk
        self.assertEqual(received.split(b"\r\n")[0], b"HTTP/1.1 101 Switching Protocols")
        # RFC 6455's own example key and answer.
        self.assertIn(b"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", received)
        self.assertIn(tab_unload_smoke.text_frame("tick 1"), received)
        self.assertEqual(tab_unload_smoke.Fixture.sockets["opened"], 1)

    def test_a_live_connection_holds_without_a_reconnect_or_a_report(self):
        held = Counter({"opened": 1, "ended": 1})
        self.assertTrue(tab_unload_smoke.stayed_connected(Counter(), held))
        self.assertFalse(tab_unload_smoke.stayed_connected(Counter(), Counter({"opened": 2})))
        self.assertFalse(tab_unload_smoke.stayed_connected(Counter({"/closed": 1}), held))
        self.assertFalse(tab_unload_smoke.stayed_connected(Counter({"/frozen": 1}), held))
        self.assertFalse(tab_unload_smoke.stayed_connected(Counter(), Counter()))

    def test_a_reload_needs_a_second_request_for_the_second_page(self):
        self.assertFalse(tab_unload_smoke.reloaded(Counter({"/first": 2, "/second": 1})))
        self.assertTrue(tab_unload_smoke.reloaded(Counter({"/first": 1, "/second": 2})))


if __name__ == "__main__":
    unittest.main()
