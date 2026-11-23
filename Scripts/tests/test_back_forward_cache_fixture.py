"""The back/forward cache fixture serves only its own pages, and nothing that blocks the cache (DEV-943)."""
import io
import unittest
import zlib
from unittest.mock import Mock

from Scripts.core import back_forward_cache_fixture as fixture


class Handler:
    def __init__(self, path):
        self.path = path
        self.status = None
        self.headers = {}
        self.wfile = io.BytesIO()
        self.send_response = Mock(side_effect=lambda status: setattr(self, "status", status))
        self.send_header = Mock(side_effect=lambda name, value: self.headers.__setitem__(name, value))
        self.end_headers = Mock()


class BackForwardCacheFixtureTests(unittest.TestCase):
    def setUp(self):
        fixture.reset()

    def test_pages_count_each_serve_and_report_pageshow(self):
        first = Handler("/back-forward-cache/a")
        self.assertTrue(fixture.serve(first))
        body = first.wfile.getvalue().decode()
        self.assertEqual(first.status, 200)
        self.assertIn("<title>Arx cache A</title>", body)
        self.assertIn('addEventListener("pageshow"', body)
        self.assertIn("served=1 token=", body)
        self.assertIn(fixture.BUTTON, body)
        self.assertIn('href="/back-forward-cache/icon.png"', body)
        second = Handler("/back-forward-cache/a")
        fixture.serve(second)
        self.assertIn("served=2 token=", second.wfile.getvalue().decode())
        self.assertEqual(fixture.served("a"), 2)
        self.assertEqual(fixture.served("b"), 0)

    def test_nothing_blocks_the_cache(self):
        for name in ("a", "b", "media", "icon.png", "artwork.png"):
            handler = Handler(f"/back-forward-cache/{name}")
            fixture.serve(handler)
            self.assertNotIn("Cache-Control", handler.headers)
            body = handler.wfile.getvalue()
            self.assertNotIn(b"unload", body)
            self.assertNotIn(b"no-store", body)

    def test_media_page_plays_once_on_a_trusted_click_then_pauses(self):
        handler = Handler("/back-forward-cache/media")
        fixture.serve(handler)
        body = handler.wfile.getvalue().decode()
        self.assertIn("<title>Arx cache media</title>", body)
        self.assertIn(f'src="{fixture.VIDEO}"', body)
        self.assertIn("e.isTrusted", body)
        self.assertIn("video.pause()", body)
        # A two-second clip is transient to Chromium; the reported state makes it controllable.
        self.assertIn('navigator.mediaSession.playbackState="playing"', body)
        self.assertIn('navigator.mediaSession.playbackState="paused"', body)
        # A restore resets the browser's copy of that state, so a restored page reports it again.
        self.assertIn('if(e.persisted)navigator.mediaSession.playbackState=video.paused?"paused":"playing"', body)
        self.assertIn('addEventListener("pageshow"', body)
        self.assertIn("served=1 token=", body)

    def test_media_page_names_its_track_and_offers_previous_and_next(self):
        # DEV-960: a restore must keep these in the browser; the page never sends them again.
        handler = Handler("/back-forward-cache/media")
        fixture.serve(handler)
        body = handler.wfile.getvalue().decode()
        self.assertIn(f'artist:"{fixture.ARTIST}"', body)
        self.assertIn(f'src:"{fixture.ARTWORK}",sizes:"96x96",type:"image/png"', body)
        self.assertIn(f'session.metadata=track("{fixture.TRACK}");', body)
        self.assertIn('session.setActionHandler("previoustrack",()=>{});', body)
        self.assertIn('session.setActionHandler("nexttrack",()=>{});', body)
        # Only a later restore changes them, and the change must win over what the browser kept.
        change = body[body.index('addEventListener("pageshow"'):]
        self.assertIn(f"if(e.persisted&&++restores==={fixture.CHANGED_ON_RESTORE})", change)
        self.assertIn(f'session.metadata=track("{fixture.CHANGED_TRACK}");', change)
        self.assertIn('session.setActionHandler("nexttrack",null);', change)
        self.assertNotIn("previoustrack", change)

    def test_artwork_is_a_png_large_enough_for_the_engine(self):
        handler = Handler(fixture.ARTWORK)
        self.assertTrue(fixture.serve(handler))
        data = handler.wfile.getvalue()
        self.assertEqual(handler.status, 200)
        self.assertEqual(handler.headers["Content-Type"], "image/png")
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        # The engine's media bridge accepts artwork from 48 px.
        self.assertEqual(int.from_bytes(data[16:20], "big"), fixture.ARTWORK_SIZE)
        self.assertGreaterEqual(fixture.ARTWORK_SIZE, 48)
        self.assertEqual(fixture.served("media"), 0)

    def test_icon_is_a_png(self):
        handler = Handler("/back-forward-cache/icon.png")
        fixture.serve(handler)
        data = handler.wfile.getvalue()
        self.assertEqual(handler.headers["Content-Type"], "image/png")
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertEqual(int.from_bytes(data[16:20], "big"), 32)
        self.assertIsNotNone(zlib.decompressobj())

    def test_other_paths_and_queries_are_refused(self):
        self.assertFalse(fixture.serve(Handler("/index.html")))
        for path in ("/back-forward-cache/c", "/back-forward-cache/a?x=1", "/back-forward-cache/"):
            handler = Handler(path)
            self.assertTrue(fixture.serve(handler))
            self.assertEqual(handler.status, 404)
        self.assertEqual(fixture.served("a"), 0)


if __name__ == "__main__":
    unittest.main()
