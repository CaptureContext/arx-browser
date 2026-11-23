"""Little Peek evidence must cover both lifecycle phases with real document identity."""

from pathlib import Path
import tempfile
import unittest

from Scripts.core import little_peek_smoke


class LittlePeekSmokeTests(unittest.TestCase):
    def test_document_nonce_is_created_on_load_without_persistent_storage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            little_peek_smoke.prepare(root)
            page = (root / "little-peek.html").read_text()
            self.assertIn("crypto.randomUUID()", page)
            self.assertIn("['dismiss', 'promote-start', 'promote-next']", page)
            self.assertIn("document.title = 'Arx Little Peek ' + phase", page)
            self.assertNotIn("localStorage", page)
            self.assertNotIn("sessionStorage", page)
            with self.assertRaises(FileExistsError):
                little_peek_smoke.prepare(root)

    def test_owned_escape_document_has_consumed_and_navigation_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            little_peek_smoke.prepare(root)
            page = (root / "peek-escape.html").read_text()
            self.assertIn("event.preventDefault()", page)
            self.assertIn("location.assign('peek-escape.html?phase=arrived')", page)
            self.assertIn("event.key !== 'Escape'", page)
            self.assertNotIn("localStorage", page)
            self.assertNotIn("fetch(", page)

    def test_popup_documents_prove_opener_and_keep_blocked_request_unactivated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            little_peek_smoke.prepare(root)
            source = (root / "peek-popup.html").read_text()
            child = (root / "peek-popup-child.html").read_text()
            self.assertIn("if (phase === 'blocked') setTimeout", source)
            self.assertIn("window.open(target, '_blank'", source)
            self.assertIn("window.opener.sessionStorage.getItem('arx-popup-proof')", child)
            self.assertNotIn("localStorage", source + child)
            self.assertNotIn("fetch(", source + child)

    def test_little_popup_messages_its_opener_and_closes_itself(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            little_peek_smoke.prepare(root)
            source = (root / "little-popup.html").read_text()
            child = (root / "little-popup-child.html").read_text()
            self.assertIn("window.open('little-popup-child.html', 'arx-sign-in', 'popup", source)
            self.assertIn("event.source.postMessage('arx-little-popup-ack', location.origin)", source)
            self.assertIn("window.opener.postMessage('arx-little-popup-hello', location.origin)", child)
            self.assertIn("window.close()", child)
            self.assertIn("ARX_LITTLE_POPUP_SMOKE_SUCCESS", little_peek_smoke.MARKERS)
            # DEV-1186: the same popup from a main window opens in Little Arx too.
            self.assertIn("ARX_WINDOW_POPUP_SMOKE_SUCCESS", little_peek_smoke.MARKERS)
            # DEV-1312: a Favorite's plain target="_blank" link, whose page answers its opener.
            favorite = (root / "favorite-new-tab.html").read_text()
            favorite_child = (root / "favorite-new-tab-child.html").read_text()
            self.assertIn('target="_blank" rel="opener"', favorite)
            self.assertIn("event.source.postMessage('arx-favorite-new-tab-ack', location.origin)", favorite)
            self.assertIn("window.opener.postMessage('arx-favorite-new-tab-hello', location.origin)", favorite_child)
            self.assertIn("ARX_FAVORITE_NEW_TAB_SMOKE_SUCCESS", little_peek_smoke.MARKERS)
            self.assertNotIn("localStorage", source + child)
            self.assertNotIn("fetch(", source + child)

    def test_keyboard_document_tabs_to_each_target_from_its_neighbour(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            little_peek_smoke.prepare(root)
            source = (root / "keyboard-link.html").read_text()
            frame = (root / "keyboard-frame.html").read_text()
            target = (root / "keyboard-target.html").read_text()
            self.assertIn("{link: 'start', field: 'link', frame: 'field', button: 'frame-link'}", source)
            self.assertIn("'frame-' + (inner && inner.id", source)
            self.assertIn('<iframe id="frame" src="keyboard-frame.html"', source)
            self.assertIn('href="keyboard-target.html?from=frame"', frame)
            self.assertIn("'Arx Keyboard target '", target)
            self.assertNotIn("localStorage", source + frame + target)
            self.assertNotIn("fetch(", source + frame + target)

    def test_shift_link_counts_the_trusted_mouse_downs_it_sees(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            little_peek_smoke.prepare(root)
            page = (root / "shift-link.html").read_text()
            # The app smoke reads the title back (ShiftClickCheck.PageSaw): the plain title while it
            # has seen nothing, then the counts after a middle dot.
            self.assertIn("'Arx Shift link' + (seen.down ? ` \u00b7 down=${seen.down} shift=${seen.shift}` : '')", page)
            self.assertIn("if (!event.isTrusted) return;", page)
            self.assertIn("if (event.shiftKey) seen.shift++;", page)
            # It only watches: the link still opens what a Shift-click opens.
            self.assertNotIn("preventDefault", page)
            self.assertIn('href="shift-target.html"', page)

    def test_both_exact_markers_are_required(self):
        little_peek_smoke.verify("\n".join(little_peek_smoke.MARKERS))
        for omitted in little_peek_smoke.MARKERS:
            remaining = "\n".join(marker for marker in little_peek_smoke.MARKERS if marker != omitted)
            for diagnostic in ("", f"waiting for {omitted}", f"{omitted}_PENDING"):
                with self.subTest(omitted=omitted, diagnostic=diagnostic):
                    with self.assertRaisesRegex(ValueError, "Little Peek smoke did not complete"):
                        little_peek_smoke.verify(remaining + "\n" + diagnostic)


if __name__ == "__main__":
    unittest.main()
