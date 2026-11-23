"""Bound the DEV-936 visibility fixture's pages and beacons."""
import io
import unittest
from unittest.mock import Mock, patch

from Scripts.core import background_visibility_fixture as fixture


class BackgroundVisibilityFixtureTests(unittest.TestCase):
    def handler(self, path):
        handler = Mock()
        handler.path = path
        handler.wfile = io.BytesIO()
        return handler

    def test_page_reports_visibility_timers_and_freezing_in_its_title(self):
        handler = self.handler("/visibility/page.html?case=later-1")
        self.assertTrue(fixture.serve(handler))
        handler.send_response.assert_called_once_with(200)
        handler.send_header.assert_any_call("Cache-Control", "no-store")
        body = handler.wfile.getvalue().decode()
        self.assertIn("const name='later-1'", body)
        for needle in ["setInterval(()=>{slow++;report();},1000)", "setInterval(()=>{fast++;},100)",
                       "addEventListener('freeze'", "addEventListener('resume'", "'first='+first",
                       "'painted='+painted"]:
            with self.subTest(needle=needle):
                self.assertIn(needle, body)

    def test_events_are_counted_and_answered_without_content(self):
        with patch.object(fixture, "_events", []):
            handler = self.handler("/visibility/event?case=tab-1&kind=freeze")
            self.assertTrue(fixture.serve(handler))
            handler.send_response.assert_called_once_with(204)
            self.assertEqual([event[1:] for event in fixture._events], [("tab-1", "freeze")])

    def test_query_is_bounded_and_never_reflected(self):
        for path in ["/visibility/page.html", "/visibility/page.html?case=", "/visibility/page.html?case=a&case=b",
                     "/visibility/page.html?case=x&other=y", "/visibility/page.html?case=" + "a" * 33,
                     "/visibility/page.html?case=%3Cscript%3E", "/visibility/event?case=x",
                     "/visibility/event?case=x&kind=other", "/visibility/event?case=x&kind=freeze&kind=resume"]:
            with self.subTest(path=path):
                handler = self.handler(path)
                self.assertTrue(fixture.serve(handler))
                handler.send_error.assert_called_once_with(400)
                self.assertEqual(handler.wfile.getvalue(), b"")

    def test_other_paths_are_not_fixture_routes(self):
        self.assertFalse(fixture.serve(self.handler("/index.html")))

    def test_tally_counts_pages_whose_last_event_is_a_freeze(self):
        events = [(0, "a", "freeze"), (1, "b", "freeze"), (2, "a", "resume"), (3, "a", "visible"),
                  (4, "c", "hidden")]
        self.assertEqual(fixture.tally(events), (1, 1))


if __name__ == "__main__":
    unittest.main()
