"""The owned echo binary uses Chromium's native-endian framing without a broker."""
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from Scripts.engine.config import PACKAGE


class NativeMessagingFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.directory.name) / "host"
        result = subprocess.run([
            "xcrun", "clang", "-std=c17", "-Wall", "-Wextra", "-Werror",
            str(PACKAGE.parents[1] / "Scripts/engine/fixtures/native_message_host.c"),
            "-o", str(cls.binary),
        ], capture_output=True, text=True, timeout=30)
        if result.returncode:
            cls.directory.cleanup()
            raise AssertionError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_host(self, payload, origin=None):
        origin = origin or "chrome-extension://" + "a" * 32 + "/"
        return subprocess.run([str(self.binary), origin], input=payload,
                              capture_output=True, timeout=5)

    def test_multiple_messages_keep_the_exact_origin_and_one_live_process(self):
        message = b'{"kind":"arx-native-fixture"}'
        frame = struct.pack("=I", len(message)) + message
        result = self.run_host(frame + frame)
        self.assertEqual(result.returncode, 0)
        responses = []
        data = result.stdout
        while data:
            size = struct.unpack("=I", data[:4])[0]
            responses.append(json.loads(data[4:4+size]))
            data = data[4+size:]
        self.assertEqual(len(responses), 2)
        self.assertEqual(responses[0], responses[1])
        self.assertEqual(responses[0]["origin"], "chrome-extension://" + "a" * 32 + "/")
        self.assertEqual(responses[0]["kind"], "arx-native-fixture")
        self.assertTrue(responses[0]["framed"])
        self.assertGreater(responses[0]["pid"], 0)
        self.assertEqual(result.stderr, b"")

    def test_foreign_or_malformed_origin_cannot_start_protocol(self):
        for origin in ("https://capturecontext.dev/", "chrome-extension://" + "z" * 32 + "/", "chrome-extension://" + "a" * 32):
            with self.subTest(origin=origin):
                result = self.run_host(b"", origin)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, b"")

    def test_bounded_frames_and_payload_are_fail_closed(self):
        for payload in (b"x", struct.pack("=I", 0), struct.pack("=I", 4097), struct.pack("=I", 7)+b"partial", struct.pack("=I", 3)+b"bad"):
            with self.subTest(payload=payload):
                result = self.run_host(payload)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
