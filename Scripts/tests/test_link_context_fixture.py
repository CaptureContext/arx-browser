"""The link context fixture's file answers only its download page as referrer (DEV-851)."""
import io
import unittest
from unittest.mock import Mock

from Scripts.core import link_context_fixture as fixture


class Handler:
    def __init__(self, path, headers):
        self.path = path
        self.headers = headers
        self.status = None
        self.sent = {}
        self.wfile = io.BytesIO()
        self.send_response = Mock(side_effect=lambda status: setattr(self, "status", status))
        self.send_header = Mock(side_effect=lambda name, value: self.sent.__setitem__(name, value))
        self.end_headers = Mock()


class LinkContextFixtureTests(unittest.TestCase):
    def test_the_download_page_links_to_the_protected_file(self):
        handler = Handler("/link-context/download", {"Host": "127.0.0.1:8000"})
        self.assertTrue(fixture.serve(handler))
        self.assertEqual(handler.status, 200)
        self.assertIn('href="/link-context/protected.bin"', handler.wfile.getvalue().decode())

    def test_the_file_needs_its_page_as_the_referrer(self):
        page = "http://127.0.0.1:8000/link-context/download"
        allowed = Handler("/link-context/protected.bin", {"Host": "127.0.0.1:8000", "Referer": page})
        self.assertTrue(fixture.serve(allowed))
        self.assertEqual(allowed.status, 200)
        self.assertEqual(allowed.wfile.getvalue(), fixture.PROTECTED)
        self.assertIn("attachment", allowed.sent["Content-Disposition"])

        for headers in ({"Host": "127.0.0.1:8000"},
                        {"Host": "127.0.0.1:8000", "Referer": "http://127.0.0.1:8000/link-context/main"}):
            refused = Handler("/link-context/protected.bin", headers)
            self.assertTrue(fixture.serve(refused))
            self.assertEqual(refused.status, 403)
            self.assertEqual(refused.wfile.getvalue(), b"")


if __name__ == "__main__":
    unittest.main()
