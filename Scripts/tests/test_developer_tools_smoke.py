"""Developer tools smoke fixtures and marker checks; these never launch the application."""

import base64
import os
import urllib.error
import socket
import unittest
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

from Scripts import developer_tools_smoke as devtools


def handshake(port, key="dGhlIHNhbXBsZSBub25jZQ=="):
    connection = socket.create_connection(("127.0.0.1", port), timeout=5)
    connection.sendall((f"GET {devtools.LIVE_SOCKET} HTTP/1.1\r\nHost: localhost:{port}\r\n"
                        f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                        "Sec-WebSocket-Version: 13\r\n\r\n").encode())
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = connection.recv(1024)
        if not chunk:
            break
        response += chunk
    head, _, rest = response.partition(b"\r\n\r\n")
    return connection, head.decode(), rest


def receive(connection, count):
    data = b""
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        if not chunk:
            break
        data += chunk
    return data


class DeveloperToolsFixtureTests(unittest.TestCase):
    def setUp(self):
        self.servers, self.live = devtools.fixture_servers()
        for server in self.servers:
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
        self.port = self.servers[0].server_port

    def get(self, path):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=5) as response:
            return response.status, response.headers, response.read().decode()

    def test_every_binding_page_has_a_distinct_title(self):
        titles = {}
        for path in devtools.PAGES:
            status, _, body = self.get(path)
            self.assertEqual(status, 200)
            titles[path] = body.split("<title>")[1].split("</title>")[0]
        self.assertEqual(len(set(titles.values())), len(titles))
        self.assertEqual(titles["/pane.html"], "Arx developer pane")
        self.assertEqual(titles["/peek.html"], "Arx developer peek")
        self.assertEqual(titles["/little.html"], "Arx developer little")
        self.assertEqual(titles["/private.html"], "Arx developer private")

    def test_unknown_paths_are_not_found(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.get("/missing.html")
        self.assertEqual(error.exception.code, 404)

    def test_live_page_generation_increments_per_load_and_is_not_cached(self):
        _, headers, first = self.get(devtools.LIVE_PATH)
        _, _, second = self.get(devtools.LIVE_PATH)
        self.assertIn(f"<title>{devtools.LIVE_TITLE} 1</title>", first)
        self.assertIn(f"<title>{devtools.LIVE_TITLE} 2</title>", second)
        self.assertIn(f"'{devtools.LIVE_TITLE} 2 connected'", second)
        self.assertIn(f"ws://${{location.host}}{devtools.LIVE_SOCKET}", second)
        self.assertEqual(headers["Cache-Control"], "no-store")

    def test_handshake_follows_rfc_6455(self):
        connection, head, _ = handshake(self.port)
        self.addCleanup(connection.close)
        self.assertTrue(head.startswith("HTTP/1.1 101"))
        self.assertIn("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", head)

    def test_only_the_first_socket_reloads_and_only_after_a_request(self):
        first, _, rest = handshake(self.port)
        self.addCleanup(first.close)
        self.assertEqual(rest, b"")
        first.settimeout(0.3)
        with self.assertRaises(socket.timeout):
            first.recv(1, socket.MSG_PEEK)
        self.live.request()
        first.settimeout(5)
        self.assertEqual(receive(first, 2 + len(devtools.RELOAD)), devtools.text_frame(devtools.RELOAD))

        second, _, rest = handshake(self.port, base64.b64encode(os.urandom(16)).decode())
        self.addCleanup(second.close)
        second.settimeout(0.3)
        self.assertEqual(rest, b"")
        with self.assertRaises(socket.timeout):
            second.recv(1)

    def test_text_frame_is_a_final_unmasked_text_frame(self):
        self.assertEqual(devtools.text_frame("reload"), b"\x81\x06reload")
        with self.assertRaises(ValueError):
            devtools.text_frame("x" * 126)


class DeveloperToolsRunnerTests(unittest.TestCase):
    def test_environment_points_localhost_at_the_fixture_port(self):
        environment = devtools.environment(Path("/tmp/profile"), 4321)
        self.assertEqual(environment["ARX_DEVTOOLS_SMOKE"], "1")
        self.assertEqual(environment["ARX_ENGINE_PROFILE"], "/tmp/profile")
        self.assertEqual(environment["ARX_ENGINE_URL"], "http://127.0.0.1:4321/index.html")
        local = urlsplit(environment["ARX_DEVTOOLS_LOCAL_URL"])
        self.assertEqual((local.scheme, local.hostname, local.port, local.path), ("http", "localhost", 4321, "/"))

    def test_renderer_children_selects_only_direct_renderer_children(self):
        listing = "\n".join([
            "  10     1 /Applications/Arx.app/Contents/MacOS/Arx",
            "  11    10 /Arx Helper (Renderer) --type=renderer --renderer-client-id=4",
            "  12    10 /Arx Helper (GPU) --type=gpu-process",
            "  13    99 /Other Helper (Renderer) --type=renderer",
            "  14    10 /Arx Helper (Renderer) --type=renderer --renderer-client-id=7",
            " 100    10",
        ])
        self.assertEqual(devtools.renderer_children(10, listing), [11, 14])
        self.assertEqual(devtools.renderer_children(99, listing), [13])
        self.assertEqual(devtools.renderer_children(42, listing), [])

    def test_all_phases_in_order_pass(self):
        output = [f"{phase}\n" for phase in devtools.PHASES]
        output.insert(3, "ARX_DEVTOOLS_WINDOW 42\n")
        self.assertEqual(devtools.missing_phases(output), [])

    def test_missing_or_reordered_phases_fail(self):
        phases = list(devtools.PHASES)
        self.assertEqual(devtools.missing_phases([f"{phase}\n" for phase in phases[:-1]]), [phases[-1]])
        swapped = phases[:]
        swapped[3], swapped[4] = swapped[4], swapped[3]
        self.assertEqual(devtools.missing_phases([f"{phase}\n" for phase in swapped]), [phases[4]])

    def test_markers_are_whole_lines_and_distinct(self):
        self.assertEqual(len(set(devtools.PHASES)), len(devtools.PHASES))
        self.assertEqual(devtools.missing_phases([f"prefix {phase}\n" for phase in devtools.PHASES]), list(devtools.PHASES))
        requests = {devtools.LIVE_RELOAD_REQUEST, devtools.CRASH_REQUEST}
        self.assertFalse(requests & set(devtools.PHASES))

    def test_swift_runner_prints_every_marker(self):
        source = (Path(__file__).resolve().parents[2]
                  / "Packages/features/Sources/AppFeature/DeveloperToolsSmoke.swift").read_text()
        for marker in (*devtools.PHASES, devtools.LIVE_RELOAD_REQUEST, devtools.CRASH_REQUEST, devtools.WINDOW.strip()):
            self.assertIn(f'emit("{marker}', source)
        for path in devtools.PAGES:
            if path not in ("/index.html", "/second.html"):
                self.assertIn(f'"{path.lstrip("/")}"', source)


if __name__ == "__main__":
    unittest.main()
