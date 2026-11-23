import base64
import json
import plistlib
import unittest
from unittest.mock import patch

from Scripts import sign_in_smoke


class SignInLeakScanTests(unittest.TestCase):
    secret = "k3j9x7q2m8p4w6z1n5b0"

    def test_detects_encodings_and_partial_windows(self):
        for blob in [
            self.secret, self.secret.upper(), self.secret[::-1], base64.b64encode(self.secret.encode()).decode(),
            self.secret.encode().hex(), " ".join(self.secret), "prefix " + self.secret[5:15] + " suffix",
        ]:
            self.assertTrue(sign_in_smoke.leaks(blob, [self.secret]), blob)

    def test_ignores_unrelated_replies(self):
        reply = json.dumps({"result": {"kind": "error", "code": "authenticationProtected"}})
        self.assertEqual(sign_in_smoke.leaks(reply, [self.secret]), [])

    def test_decodes_image_blocks(self):
        line = json.dumps({"content": [{"type": "image", "data": base64.b64encode(b"png").decode()}]})
        self.assertEqual(sign_in_smoke.decoded_images(line), [b"png"])


class SignInConsoleTests(unittest.TestCase):
    def test_reads_the_console_lock(self):
        self.assertTrue(sign_in_smoke.console_locked(plistlib.dumps({"IOConsoleLocked": True})))
        self.assertFalse(sign_in_smoke.console_locked(plistlib.dumps({"IOConsoleLocked": False})))
        self.assertFalse(sign_in_smoke.console_locked(plistlib.dumps({"IOKitBuildVersion": "x"})))


class SignInDriverTests(unittest.TestCase):
    def environment(self, driver, base=None):
        return sign_in_smoke.app_environment(
            base or {}, driver=driver, port=4321, profile="/work/profile", transcript="/work/transcript.jsonl",
            password="p" * 20, wrong="w" * 20, otp="o" * 12,
        )

    def test_store_driver_keeps_the_original_markers(self):
        self.assertEqual(sign_in_smoke.markers("store"), sign_in_smoke.MARKERS)
        self.assertEqual(sign_in_smoke.task_name("store"), "sign-in-smoke")

    def test_interface_driver_requires_pressed_controls_before_success(self):
        markers = sign_in_smoke.markers("interface")
        self.assertEqual(sign_in_smoke.task_name("interface"), "sign-in-interface-smoke")
        self.assertEqual(markers[-2:], ["ARX_SIGN_IN_INTERFACE_CONTROLS_PRESSED", "ARX_SIGN_IN_SMOKE_SUCCESS"])
        self.assertTrue(set(sign_in_smoke.MARKERS) <= set(markers))
        store_output = "".join(marker + "\n" for marker in sign_in_smoke.MARKERS)
        self.assertEqual(sign_in_smoke.missing_markers(store_output, "store"), [])
        self.assertEqual(sign_in_smoke.missing_markers(store_output, "interface"),
                         ["ARX_SIGN_IN_INTERFACE_CONTROLS_PRESSED"])

    def test_markers_must_be_complete_lines(self):
        output = "".join(marker + "\n" for marker in sign_in_smoke.markers("interface"))
        self.assertEqual(sign_in_smoke.missing_markers(output, "interface"), [])
        partial = output.replace("ARX_SIGN_IN_INTERFACE_CONTROLS_PRESSED\n", "x ARX_SIGN_IN_INTERFACE_CONTROLS_PRESSED")
        self.assertEqual(sign_in_smoke.missing_markers(partial, "interface"),
                         ["ARX_SIGN_IN_INTERFACE_CONTROLS_PRESSED"])

    def test_environment_selects_the_driver_and_drops_inherited_fixture_variables(self):
        env = self.environment("interface", {"PATH": "/usr/bin", "ARX_SIGN_IN_SMOKE_DRIVER": "store", "ARX_OTHER": "1"})
        self.assertEqual(env["ARX_SIGN_IN_SMOKE_DRIVER"], "interface")
        self.assertEqual(env["PATH"], "/usr/bin")
        self.assertNotIn("ARX_OTHER", env)
        self.assertEqual(env["ARX_ENGINE_URL"], "http://127.0.0.1:4321/login.html")
        self.assertEqual(self.environment("store")["ARX_SIGN_IN_SMOKE_DRIVER"], "store")

    def test_unknown_driver_is_rejected(self):
        with self.assertRaises(ValueError):
            sign_in_smoke.markers("keyboard")
        with self.assertRaises(ValueError):
            self.environment("keyboard")

    def test_interface_task_is_dispatched(self):
        from Scripts import tasks
        self.assertIs(tasks.COMMANDS["sign-in-interface-smoke"], sign_in_smoke.interface)
        with patch.object(sign_in_smoke, "main") as run:
            sign_in_smoke.interface()
        run.assert_called_once_with(driver="interface")


if __name__ == "__main__":
    unittest.main()
