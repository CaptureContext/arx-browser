"""The owned consent pages must never bypass native/OS approval or retain data."""
import io
from pathlib import Path
import tempfile
import unittest

from Scripts.core import page_consent_fixture as fixture


class Handler:
    def __init__(self, path):
        self.path = path
        self.wfile = io.BytesIO()
        self.headers = {}
        self.status = None
    def send_response(self, status): self.status = status
    def send_header(self, name, value): self.headers[name] = value
    def end_headers(self): pass
    def send_error(self, status): self.status = status


class PageConsentFixtureTests(unittest.TestCase):
    def test_routes_and_browser_policy_allow_real_cross_origin_prompt(self):
        for path in ('main', 'frame', 'destination'):
            handler = Handler('/page-consent/' + path + '.html')
            self.assertTrue(fixture.serve(handler))
            self.assertEqual(handler.status, 200)
            self.assertEqual(handler.headers['Cache-Control'], 'no-store')
            self.assertIn('geolocation=*', handler.headers['Permissions-Policy'])
            self.assertEqual(int(handler.headers['Content-Length']), len(handler.wfile.getvalue()))
        handler = Handler('/unowned')
        self.assertFalse(fixture.serve(handler))
        handler = Handler('/page-consent/missing')
        self.assertTrue(fixture.serve(handler))
        self.assertEqual(handler.status, 404)

    def test_tracks_stop_and_sensitive_values_never_leave_page(self):
        self.assertIn('for(const track of tracks)track.stop()', fixture.HTML)
        for denied in ('MediaRecorder', '.coords', '.latitude', '.longitude', 'fetch(',
                       'getSettings(', 'enumerateDevices(', 'location.assign(\'mailto:'):
            self.assertNotIn(denied, fixture.HTML)
        self.assertIn('getDisplayMedia', fixture.HTML)
        self.assertIn('Notification.requestPermission()', fixture.HTML)

    def test_navigation_and_frame_replacement_are_hostile_document_cases(self):
        self.assertIn("location.assign('/page-consent/destination.html'),400", fixture.HTML)
        self.assertIn("location.replace('/page-consent/destination.html'),400", fixture.FRAME)
        self.assertIn("url.hostname=location.hostname==='127.0.0.1'?'localhost':'127.0.0.1'", fixture.HTML)

    def test_preparation_is_exclusive_and_never_overwrites_existing_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture.prepare(root)
            self.assertEqual((root / 'page-consent/main.html').read_text(), fixture.HTML)
            with self.assertRaises(FileExistsError):
                fixture.prepare(root)
