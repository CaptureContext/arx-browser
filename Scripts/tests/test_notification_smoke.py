"""Notification smoke fixture and acceptance; these never launch the application."""

import json
import subprocess
import unittest
import urllib.request
from collections import Counter
from pathlib import Path

from Scripts import notification_smoke
from Scripts.core.loopback_server import LoopbackServer

TITLE = "Arx notification smoke 1234abcd"
SITE = "127.0.0.1:48123"


def delivered(**changes):
    value = {"title": TITLE, "subtitle": SITE, "body": notification_smoke.BODY, "attachments": 1,
             "origins": [f"http://{SITE}"]}
    value.update(changes)
    return notification_smoke.DELIVERED + json.dumps(value)


def output(*lines):
    return "\n".join(lines) + "\n"


PASSING = output(*notification_smoke.MARKERS[:3], delivered(), *notification_smoke.MARKERS[3:])


class NotificationSmokeVerifyTests(unittest.TestCase):
    def test_every_phase_and_a_matching_notification_pass(self):
        self.assertEqual(notification_smoke.verify(0, PASSING, TITLE, SITE), [])

    def test_no_attachment_passes_with_a_note(self):
        stdout = PASSING.replace(delivered(), delivered(attachments=0))
        notes = notification_smoke.verify(0, stdout, TITLE, SITE)
        self.assertEqual(len(notes), 1)
        self.assertIn("icon", notes[0])

    def test_unauthorized_arx_dev_is_not_run_with_its_own_exit_code(self):
        stdout = output(notification_smoke.NOT_RUN + " authorization=notDetermined Arx Dev is not allowed")
        with self.assertRaises(notification_smoke.NotRun) as context:
            notification_smoke.verify(0, stdout, TITLE, SITE)
        self.assertIsInstance(context.exception, subprocess.CalledProcessError)
        self.assertEqual(context.exception.returncode, notification_smoke.NOT_RUN_EXIT)
        self.assertIn("NOT RUN", str(context.exception))
        self.assertIn("System Settings › Notifications", str(context.exception))

    def test_a_missing_delivery_fails(self):
        stdout = PASSING.replace(delivered() + "\n", "")
        with self.assertRaisesRegex(ValueError, "didn't list"):
            notification_smoke.verify(0, stdout, TITLE, SITE)

    def test_a_wrong_title_or_body_fails(self):
        for changes in ({"title": "Other"}, {"body": "Other"}):
            with self.subTest(changes=changes), self.assertRaisesRegex(ValueError, "title or body"):
                notification_smoke.verify(0, PASSING.replace(delivered(), delivered(**changes)), TITLE, SITE)

    def test_a_notification_without_the_site_fails(self):
        stdout = PASSING.replace(delivered(), delivered(subtitle="Arx Dev"))
        with self.assertRaisesRegex(ValueError, "site"):
            notification_smoke.verify(0, stdout, TITLE, SITE)

    def test_a_missing_phase_fails(self):
        for marker in notification_smoke.MARKERS:
            with self.subTest(marker=marker), self.assertRaisesRegex(ValueError, marker):
                notification_smoke.verify(0, PASSING.replace(marker + "\n", ""), TITLE, SITE)

    def test_arx_failing_after_its_markers_fails(self):
        with self.assertRaisesRegex(ValueError, "exit 1"):
            notification_smoke.verify(1, PASSING, TITLE, SITE)


class NotificationSmokeFixtureTests(unittest.TestCase):
    def setUp(self):
        notification_smoke.Fixture.title = TITLE
        notification_smoke.Fixture.requests = Counter()
        self.server = LoopbackServer(notification_smoke.Fixture).start()
        self.addCleanup(self.server.stop)
        self.base = f"http://127.0.0.1:{self.server.server.server_port}"

    def fetch(self, path):
        with urllib.request.urlopen(self.base + path, timeout=5) as response:
            return response.headers.get("Content-Type"), response.read()

    def test_the_page_fires_the_titled_notification_only_when_granted_and_asked(self):
        kind, body = self.fetch("/page?fire=1")
        text = body.decode()
        self.assertTrue(kind.startswith("text/html"))
        self.assertIn(json.dumps(TITLE), text)
        self.assertIn(json.dumps(notification_smoke.BODY), text)
        self.assertIn('permission === "granted" && new URLSearchParams(location.search).has("fire")', text)
        self.assertNotIn("requireInteraction", text.replace("No requireInteraction", ""))
        # NotificationSmoke.PageTitle
        for title in ("Arx notification fixture ", "Arx notification shown", "Arx notification error"):
            self.assertIn(title, text)
        self.assertNotIn("<title>Arx notification fixture", text)

    def test_the_home_private_and_icon_resources(self):
        self.assertIn(b"<title>Arx notification fixture home</title>", self.fetch("/")[1])
        private = self.fetch("/private")[1].decode()
        self.assertIn("<title>Arx notification private asking</title>", private)
        self.assertIn("Notification.requestPermission()", private)
        kind, png = self.fetch("/icon.png")
        self.assertEqual(kind, "image/png")
        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertEqual(notification_smoke.Fixture.requests,
                         Counter({"/": 1, "/private": 1, "/icon.png": 1}))

    def test_a_title_cannot_end_the_script(self):
        self.assertNotIn("</script><", notification_smoke.page('x</script><b>'))

    def test_environment_names_the_fixture(self):
        environment = notification_smoke.environment(Path("/tmp/profile"), 48123, TITLE)
        self.assertEqual(environment["ARX_NOTIFICATION_SMOKE"], "1")
        self.assertEqual(environment["ARX_ENGINE_PROFILE"], "/tmp/profile")
        self.assertEqual(environment["ARX_ENGINE_URL"], "http://127.0.0.1:48123/page")
        self.assertEqual(environment["ARX_NOTIFICATION_SMOKE_ORIGIN"], "http://127.0.0.1:48123")
        self.assertEqual(environment["ARX_NOTIFICATION_SMOKE_PRIVATE_URL"], "http://127.0.0.1:48123/private")
        self.assertEqual(environment["ARX_NOTIFICATION_SMOKE_TITLE"], TITLE)


if __name__ == "__main__":
    unittest.main()
