"""Hand check smoke acceptance; these never launch the application."""

import hashlib
import plistlib
import unittest
from pathlib import Path

from Scripts import hand_check_smoke as hand


class HandCheckSmokeTests(unittest.TestCase):
    def passing(self, phases):
        return "\n".join([*(hand.phase_marker(phase) for phase in phases), "ARX_HAND_CHECK_SMOKE_SUCCESS"]) + "\n"

    def test_every_phase_runs_by_default_in_catalog_order(self):
        self.assertEqual(hand.parse([]), list(hand.PHASES))
        self.assertEqual(hand.parse(["--phase", "private-save", "--phase", "find"]), ["find", "private-save"])

    def test_an_unknown_phase_is_refused(self):
        with self.assertRaises(SystemExit):
            hand.parse(["--phase", "everything"])

    def test_markers_match_the_apps(self):
        # HandCheckSmoke.Phase.successMarker in AppFeature.
        self.assertEqual(hand.phase_marker("full-screen"), "ARX_HAND_CHECK_FULL_SCREEN_SUCCESS")
        self.assertEqual(hand.phase_marker("private-save"), "ARX_HAND_CHECK_PRIVATE_SAVE_SUCCESS")

    def test_environment_names_the_phases_the_profile_and_the_folder(self):
        env = hand.environment(Path("/tmp/p"), 8123, ["find", "address"], Path("/tmp/f"))
        self.assertEqual(env["ARX_HAND_CHECK_SMOKE"], "find,address")
        self.assertEqual(env["ARX_ENGINE_URL"], "http://127.0.0.1:8123/index.html")
        self.assertEqual(env["ARX_ENGINE_PROFILE"], "/tmp/p")
        self.assertEqual(env["ARX_HAND_CHECK_PRIVATE_FOLDER"], "/tmp/f")
        self.assertEqual(env["ARX_HAND_CHECK_PDF_SHA256"], hashlib.sha256(hand.pdf_document()).hexdigest())

    def test_all_phases_passing_is_success(self):
        hand.verify(0, self.passing(hand.PHASES), "", list(hand.PHASES))

    def test_a_failure_line_names_the_phase(self):
        with self.assertRaisesRegex(ValueError, "find: timed out"):
            hand.verify(1, "", "noise\nARX_HAND_CHECK_SMOKE_FAILED: find: timed out: x\n", ["find"])

    def test_a_missing_phase_fails(self):
        stdout = self.passing(["find"])
        with self.assertRaisesRegex(ValueError, "address"):
            hand.verify(0, stdout, "", ["find", "address"])

    def test_a_crash_after_the_phases_fails(self):
        with self.assertRaisesRegex(ValueError, "exited with"):
            hand.verify(-11, self.passing(["find"]), "", ["find"])

    def test_saved_files_come_from_the_apps_lines(self):
        stdout = "x\nARX_HAND_CHECK_PRIVATE_SAVE_FILE path=/a b/page.html\nARX_HAND_CHECK_PRIVATE_SAVE_FILE path=/c.pdf\n"
        self.assertEqual(hand.saved_files(stdout), [Path("/a b/page.html"), Path("/c.pdf")])

    def test_a_bookmark_naming_the_folder_is_caught(self):
        folder = Path("/tmp/hand-check-1/arx-private-save-0123456789ab")
        bookmark = b"book\x00\x00" + b"arx-private-save-0123456789ab" + b"\x00tail"
        exported = plistlib.dumps({hand.APP_KEY: bookmark, "Other": 1})
        self.assertTrue(hand.names_folder(hand.remembered_folder(exported), folder))
        self.assertFalse(hand.names_folder(b"book\x00Downloads\x00", folder))
        self.assertFalse(hand.names_folder(hand.remembered_folder(plistlib.dumps({"Other": 1})), folder))
        self.assertIsNone(hand.remembered_folder(b""))

    def test_where_froms_is_found_in_xattr_listing(self):
        listing = "com.apple.quarantine: 0083;\ncom.apple.metadata:kMDItemWhereFroms:\n00000000  62 70 6C |bpl|\n"
        self.assertTrue(hand.where_froms(listing).startswith(hand.WHERE_FROMS))
        self.assertIsNone(hand.where_froms("com.apple.quarantine: 0083;\n"))

    def test_the_fixture_pdf_has_a_correct_cross_reference(self):
        document = hand.pdf_document()
        self.assertTrue(document.startswith(b"%PDF-1.4"))
        start = int(document.rsplit(b"startxref\n", 1)[1].split(b"\n", 1)[0])
        self.assertTrue(document[start:].startswith(b"xref\n0 6\n"))
        offsets = [int(line[:10]) for line in document[start:].split(b"\n")[3:8]]
        for number, offset in enumerate(offsets, start=1):
            self.assertTrue(document[offset:].startswith(b"%d 0 obj" % number))

    def test_timed_out_output_reads_as_text(self):
        self.assertEqual(hand.text(b"a\xffb"), "a�b")
        self.assertEqual(hand.text(None), "")


if __name__ == "__main__":
    unittest.main()
