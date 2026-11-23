"""The overnight WebKit fallback phase's fixture and marker (DEV-877)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.core import webkit_fallback_smoke


class WebKitFallbackSmokeTests(unittest.TestCase):
    def test_runs_only_overnight(self):
        self.assertFalse(webkit_fallback_smoke.enabled({}))
        self.assertFalse(webkit_fallback_smoke.enabled({"ARX_SMOKE_OVERNIGHT": "0"}))
        self.assertTrue(webkit_fallback_smoke.enabled({"ARX_SMOKE_OVERNIGHT": "1"}))

    def test_page_asks_for_widevine_and_sets_the_phase(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = webkit_fallback_smoke.prepare(root)
            page = (root / webkit_fallback_smoke.PAGE).read_text()
            self.assertIn("requestMediaKeySystemAccess('com.widevine.alpha'", page)
            # DEV-1144: access resolves, so the page creates keys to reach the failure.
            self.assertIn("access.createMediaKeys()", page)
            self.assertIn("'Protected media keys refused: ' + error.name", page)
            self.assertIn("'" + webkit_fallback_smoke.REFUSED + "'", page)
            redirect = (root / webkit_fallback_smoke.REDIRECT).read_text()
            self.assertIn("target.hostname = new URLSearchParams(location.search).get('to')", redirect)
            self.assertIn("location.replace(target.href)", redirect)
            # DEV-1205: the probe makes bot detection's calls and titles itself with the answers.
            probe = (root / webkit_fallback_smoke.PROBE).read_text()
            self.assertIn("navigator.mediaCapabilities.decodingInfo({", probe)
            self.assertIn("keySystemConfiguration: {keySystem: 'com.widevine.alpha',", probe)
            self.assertIn("video: {robustness: 'SW_SECURE_CRYPTO'}}", probe)
            self.assertIn("configuration.sessionTypes = ['persistent-license'];", probe)
            for key_system in ("com.microsoft.playready", "com.youtube.playready", "webkit-org.w3.clearkey",
                               "org.w3.clearkey", "com.adobe.primetime", "com.adobe.access",
                               "com.apple.fairplay"):
                self.assertIn("'" + key_system + "'", probe)
            self.assertIn("document.title = `DRM probe: decodingInfo=${decodingInfo} wv=${wv}", probe)
            self.assertTrue(webkit_fallback_smoke.PROBE_ANSWER.startswith("DRM probe: decodingInfo=true wv=true"))
            refused = (root / webkit_fallback_smoke.REFUSED_ONLY).read_text()
            self.assertIn("navigator.requestMediaKeySystemAccess('com.microsoft.playready'", refused)
            self.assertIn("'Protected media refused: ' + error.name", refused)
            # DEV-1211: the player's <video> meets encrypted media; the keys-only page has none.
            self.assertIn("const source = new MediaSource();", page)
            self.assertIn("source.addSourceBuffer('video/webm; codecs=\"vp8\"')", page)
            self.assertIn("fetch('" + webkit_fallback_smoke.ENCRYPTED_INIT + "')", page)
            self.assertEqual((root / webkit_fallback_smoke.ENCRYPTED_INIT).read_bytes(),
                             webkit_fallback_smoke.encrypted_init_segment())
            keys_only = (root / webkit_fallback_smoke.KEYS_ONLY).read_text()
            self.assertIn("navigator.requestMediaKeySystemAccess('com.widevine.alpha'", keys_only)
            self.assertIn("access.createMediaKeys()", keys_only)
            self.assertIn("'Keys only: keys refused: ' + error.name", keys_only)
            self.assertIn("'" + webkit_fallback_smoke.KEYS_ONLY_REFUSED + "'", keys_only)
            for media in ("createElement", "<video", "<audio", "MediaSource", "setMediaKeys"):
                self.assertNotIn(media, keys_only)
            # DEV-1211: a player's video in a same-origin iframe, its keys in the parent.
            framed = (root / webkit_fallback_smoke.FRAMED_PLAYER).read_text()
            self.assertIn("<iframe src='" + webkit_fallback_smoke.FRAMED_VIDEO + "'", framed)
            self.assertIn("access.createMediaKeys()", framed)
            self.assertIn("'Framed player keys refused: ' + error.name", framed)
            self.assertIn("'" + webkit_fallback_smoke.FRAMED_REFUSED + "'", framed)
            self.assertNotIn("MediaSource", framed)
            video = (root / webkit_fallback_smoke.FRAMED_VIDEO).read_text()
            self.assertIn("fetch('" + webkit_fallback_smoke.ENCRYPTED_INIT + "')", video)
            self.assertNotIn("requestMediaKeySystemAccess", video)
            self.assertEqual(environment, {"ARX_WEBKIT_FALLBACK_SMOKE": "1"})
            with self.assertRaises(FileExistsError):
                webkit_fallback_smoke.prepare(root)

    def test_encrypted_init_segment_names_one_encrypted_vp8_track(self):
        # DEV-1211: WebM's ContentEncryption for one VP8 track, AES in CTR mode, with the key ID
        # the `encrypted` event carries (Chromium's WebM parser reads it so).
        segment = webkit_fallback_smoke.encrypted_init_segment()
        self.assertTrue(segment.startswith(bytes.fromhex("1A45DFA3")))
        self.assertIn(bytes.fromhex("4282") + bytes([0x84]) + b"webm", segment)
        self.assertIn(bytes.fromhex("18538067") + bytes.fromhex("01FFFFFFFFFFFFFF"), segment)
        self.assertIn(bytes([0x86, 0x85]) + b"V_VP8", segment)
        self.assertIn(bytes.fromhex("47E1") + bytes([0x81, 5]), segment)
        self.assertIn(bytes.fromhex("47E2") + bytes([0x90]) + webkit_fallback_smoke.KEY_ID, segment)
        self.assertIn(bytes.fromhex("47E7") + bytes([0x84]) + bytes.fromhex("47E8") + bytes([0x81, 1]), segment)
        # Sizes: a 128-byte payload needs two size bytes, never the reserved all-ones value.
        self.assertEqual(webkit_fallback_smoke._ebml(0xEC, bytes(126))[1:2], bytes([0xFE]))
        self.assertEqual(webkit_fallback_smoke._ebml(0xEC, bytes(127))[1:3], bytes.fromhex("407F"))

    def test_marker_must_be_a_whole_line(self):
        markers = ("ARX_KEYS_ONLY_SMOKE quiet\nARX_FRAMED_PLAYER_SMOKE offered\n"
                   "ARX_WEBKIT_FALLBACK_KEPT_SMOKE offered\n")
        webkit_fallback_smoke.verify("x\n" + markers + "ARX_WEBKIT_FALLBACK_SMOKE_SUCCESS\n")
        with self.assertRaises(ValueError):
            webkit_fallback_smoke.verify(markers + "ARX_WEBKIT_FALLBACK_SMOKE_SUCCESS_NOT\n")

    def test_the_keys_only_page_must_stay_quiet(self):
        # DEV-1211: keys made for no media on a site nobody listed are a likely bot check.
        with self.assertRaisesRegex(ValueError, "ARX_KEYS_ONLY_SMOKE quiet"):
            webkit_fallback_smoke.verify("ARX_FRAMED_PLAYER_SMOKE offered\n"
                                         "ARX_WEBKIT_FALLBACK_KEPT_SMOKE offered\nARX_WEBKIT_FALLBACK_SMOKE_SUCCESS\n")

    def test_the_framed_player_must_be_offered_webkit(self):
        # DEV-1211: media in a same-origin frame of the page counts for keys made in another.
        with self.assertRaisesRegex(ValueError, "ARX_FRAMED_PLAYER_SMOKE offered"):
            webkit_fallback_smoke.verify("ARX_KEYS_ONLY_SMOKE quiet\nARX_WEBKIT_FALLBACK_KEPT_SMOKE offered\n"
                                         "ARX_WEBKIT_FALLBACK_SMOKE_SUCCESS\n")

    def test_the_kept_page_must_be_offered_webkit(self):
        # DEV-1188: a page kept in Chromium at a listed site is asked, never moved silently.
        with self.assertRaisesRegex(ValueError, "ARX_WEBKIT_FALLBACK_KEPT_SMOKE offered"):
            webkit_fallback_smoke.verify("ARX_KEYS_ONLY_SMOKE quiet\nARX_FRAMED_PLAYER_SMOKE offered\n"
                                         "ARX_WEBKIT_FALLBACK_SMOKE_SUCCESS\n")


if __name__ == "__main__":
    unittest.main()
