import hashlib
import io
import shutil
import struct
import subprocess
import unittest
from html.parser import HTMLParser

from Scripts.core import media_fixture


class Handler:
    def __init__(self, path, byte_range=None):
        self.path = path
        self.headers = {} if byte_range is None else {"Range": byte_range}
        self.wfile = io.BytesIO()
        self.response_headers = {}
        self.status = None

    def send_response(self, status):
        self.status = status

    def send_header(self, key, value):
        self.response_headers[key] = value

    def end_headers(self):
        pass


class MediaFixtureTests(unittest.TestCase):
    def test_checked_in_video_and_range_reconstruct_exact_bytes(self):
        for path, (video, digest) in media_fixture.VIDEOS.items():
            data = video.read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
            self.assertIn(b"V_VP8", data)
            self.assertIn(b"A_OPUS", data)
            parts = []
            for byte_range in ["bytes=0-99", "bytes=100-"]:
                handler = Handler(path, byte_range)
                self.assertTrue(media_fixture.serve(handler))
                self.assertEqual(handler.status, 206)
                self.assertEqual(len(handler.wfile.getvalue()), int(handler.response_headers["Content-Length"]))
                parts.append(handler.wfile.getvalue())
            self.assertEqual(b"".join(parts), data)

    @unittest.skipUnless(shutil.which("ffmpeg"), "FFmpeg is optional; required only for regeneration/silence verification")
    def test_audio_track_decodes_to_exact_silence(self):
        for video, _ in media_fixture.VIDEOS.values():
            result = subprocess.run([
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(video),
                "-map", "0:a:0", "-f", "f32le", "-",
            ], capture_output=True, check=True, timeout=15)
            self.assertEqual(len(result.stdout), 96_000 * 4)
            self.assertTrue(all(value == 0 for (value,) in struct.iter_unpack("<f", result.stdout)))

    @unittest.skipUnless(shutil.which("ffprobe"), "FFprobe is optional; required only for regeneration checks")
    def test_videos_are_landscape_and_portrait(self):
        sizes = {}
        for path, (video, _) in media_fixture.VIDEOS.items():
            result = subprocess.run([
                "ffprobe", "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=width,height", "-of", "csv=p=0", str(video),
            ], capture_output=True, check=True, text=True, timeout=15)
            sizes[path] = result.stdout.strip()
        self.assertEqual(sizes, {"/media/pattern.webm": "160,90", "/media/pattern-portrait.webm": "90,160"})

    def test_playback_requires_explicit_start_without_mute_or_autoplay(self):
        class Elements(HTMLParser):
            def __init__(self):
                super().__init__()
                self.elements = {}

            def handle_starttag(self, tag, attrs):
                if tag in {"video", "button"}:
                    self.elements[tag] = dict(attrs)

        for case in media_fixture.CASES:
            document = media_fixture.document(case).decode()
            parser = Elements()
            parser.feed(document)
            self.assertEqual(parser.elements["video"]["preload"], "auto")
            self.assertNotIn("muted", parser.elements["video"])
            self.assertNotIn("autoplay", parser.elements["video"])
            self.assertEqual(parser.elements["button"]["id"], "start")
            self.assertEqual(parser.elements["button"]["type"], "button")
            self.assertNotIn("disabled", parser.elements["button"])
            self.assertIn("if(!event.isTrusted||state.starts!==0)return", document)
            self.assertIn("state.starts++;state.trustedStarts++", document)
            self.assertIn("left:16px;top:286px;width:200px;height:44px", document)

    def test_cases_report_what_a_timeout_needs(self):
        # DEV-1177: a timeout tells a hidden page, a stalled fetch and a title that stopped
        # changing apart.
        for case in media_fixture.CASES:
            document = media_fixture.document(case).decode()
            self.assertIn("reports:0}", document)
            self.assertIn("state.visibility=document.visibilityState", document)
            self.assertIn("state.videoReady=video.readyState", document)
            self.assertIn("state.network=video.networkState", document)
            self.assertIn("state.reports++", document)

    def test_full_screen_page_is_controlled(self):
        handler = Handler("/media/full-screen.html")
        self.assertTrue(media_fixture.serve(handler))
        self.assertEqual(handler.status, 200)
        document = handler.wfile.getvalue()
        self.assertNotIn(b"https://", document)
        self.assertIn(b"if(!event.isTrusted)return", document)
        self.assertIn(b"left:16px;top:286px;width:200px;height:44px", document)
        self.assertIn(b"requestFullscreen()", document)
        self.assertIn(b"targets=['video','box']", document)
        # DEV-991: the first entry plays the video, leaving pauses it, and X is the page's own exit.
        self.assertIn(b"if(state.requests===0)video.play()", document)
        self.assertIn(b"state.left++;video.pause()", document)
        self.assertIn(b"event.key==='x'&&document.fullscreenElement)document.exitFullscreen()", document)
        self.assertNotIn(b" muted ", document)
        self.assertIn(b"setActionHandler('enterpictureinpicture'", document)
        # DEV-1183: every report counts, so a stale title shows.
        self.assertIn(b"pipEntries:0,reports:0}", document)
        self.assertIn(b"const report=()=>{state.reports++;", document)

    def test_page_picture_page_is_controlled(self):
        handler = Handler("/media/page-picture.html")
        self.assertTrue(media_fixture.serve(handler))
        self.assertEqual(handler.status, 200)
        document = handler.wfile.getvalue()
        self.assertNotIn(b"https://", document)
        self.assertIn(b"if(event.isTrusted){state.clicks++", document)
        self.assertIn(b"left:16px;top:16px;width:200px;height:44px", document)
        self.assertIn(b"left:16px;top:76px;width:200px;height:32px", document)

    def test_invalid_and_unbounded_range_requests_are_rejected(self):
        for byte_range in ["bytes=-4", "bytes=99-0", "bytes=9999999-", "bytes=0-2,4-8"]:
            handler = Handler("/media/pattern.webm", byte_range)
            self.assertTrue(media_fixture.serve(handler))
            self.assertEqual(handler.status, 416)
            self.assertEqual(handler.wfile.getvalue(), b"")

    def test_cases_are_controlled_and_do_not_fetch_external_media(self):
        for case in media_fixture.CASES:
            handler = Handler(f"/media/{case}.html")
            self.assertTrue(media_fixture.serve(handler))
            self.assertEqual(handler.status, 200)
            source = b"pattern-portrait.webm" if case == "portrait" else b"pattern.webm"
            self.assertIn(b'src="/media/' + source + b'"', handler.wfile.getvalue())
            self.assertNotIn(b"https://", handler.wfile.getvalue())
            self.assertIn(b"video.addEventListener('loadedmetadata'", handler.wfile.getvalue())
            self.assertIn(b"video.addEventListener('play'", handler.wfile.getvalue())
        self.assertIn(b"setTimeout(enter,6000)", media_fixture.document("late"))
        with self.assertRaises(ValueError):
            media_fixture.document("<script>")
        self.assertFalse(media_fixture.serve(Handler("/media/unknown.html")))
        self.assertFalse(media_fixture.serve(Handler("/ordinary-page.html")))
