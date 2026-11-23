import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from Scripts.core import media_smoke


class MediaSmokeTests(unittest.TestCase):
    def test_prepare_requires_owned_profile_and_cannot_reuse_marker(self):
        with tempfile.TemporaryDirectory(prefix="app-smoke-") as directory:
            root = Path(directory)
            (root / "profile").mkdir(mode=0o700)
            self.assertEqual(media_smoke.prepare(root), {"ARX_MEDIA_SMOKE_ROOT": str(root)})
            marker = root / ".arx-media-smoke"
            self.assertEqual(marker.read_text(), media_smoke.SENTINEL)
            self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                media_smoke.prepare(root)

    def test_rejects_nonfixture_roots_permissions_and_symlink_profiles(self):
        with tempfile.TemporaryDirectory(prefix="ordinary-") as directory:
            with self.assertRaises(ValueError):
                media_smoke.prepare(Path(directory))
        with tempfile.TemporaryDirectory(prefix="app-smoke-") as directory:
            root = Path(directory)
            profile = root / "profile"
            profile.mkdir(mode=0o755)
            with self.assertRaises(ValueError):
                media_smoke.prepare(root)
            profile.rmdir()
            (root / "other").mkdir(mode=0o700)
            profile.symlink_to(root / "other", target_is_directory=True)
            with self.assertRaises(ValueError):
                media_smoke.prepare(root)
            self.assertFalse((root / ".arx-media-smoke").exists())

    def test_every_complete_marker_is_required(self):
        media_smoke.verify("\n".join(media_smoke.MARKERS))
        for marker in media_smoke.MARKERS:
            with self.assertRaises(ValueError):
                media_smoke.verify("\n".join(m for m in media_smoke.MARKERS if m != marker))
        with self.assertRaises(ValueError):
            media_smoke.verify("quoted: " + " quoted: ".join(media_smoke.MARKERS))

    def test_full_screen_phase_may_be_skipped_only_for_missing_spaces(self):
        skipped = "ARX_AUTOMATIC_PIP_FULL_SCREEN_SKIPPED reason=no-full-screen-spaces"
        others = [marker for marker in media_smoke.MARKERS if marker != "ARX_AUTOMATIC_PIP_FULL_SCREEN_SUCCESS"]
        self.assertEqual(media_smoke.verify("\n".join([*others, skipped])),
                         ["PiP over a full-screen window: skipped: no full-screen Spaces"])
        # DEV-1322: both OS workspace steps need the same full-screen Space, and are skipped with it.
        windowed = "ARX_AUTOMATIC_PIP_OS_WORKSPACE_WINDOWED_SKIPPED reason=no-full-screen-spaces"
        full_screen = "ARX_AUTOMATIC_PIP_OS_WORKSPACE_FULL_SCREEN_SKIPPED reason=no-full-screen-spaces"
        rest = [marker for marker in others if marker not in ("ARX_AUTOMATIC_PIP_OS_WORKSPACE_WINDOWED_STAYS_SUCCESS",
                                                              "ARX_AUTOMATIC_PIP_OS_WORKSPACE_FULL_SCREEN_SUCCESS")]
        self.assertEqual(media_smoke.verify("\n".join([*rest, skipped, windowed, full_screen])),
                         ["PiP over a full-screen window: skipped: no full-screen Spaces",
                          "No PiP when a window that isn't full screen leaves the display: skipped: no full-screen Spaces",
                          "PiP when a full-screen window's OS workspace leaves the display: skipped: no full-screen Spaces"])
        self.assertEqual(media_smoke.verify("\n".join(media_smoke.MARKERS)), [])
        for line in ("ARX_AUTOMATIC_PIP_FULL_SCREEN_SKIPPED", "ARX_AUTOMATIC_PIP_FULL_SCREEN_SKIPPED reason=other",
                     "quoted: " + skipped):
            with self.subTest(line=line), self.assertRaises(ValueError):
                media_smoke.verify("\n".join([*others, line]))
        with self.assertRaises(ValueError):
            media_smoke.verify("\n".join([*others, skipped]).replace("ARX_AUTOMATIC_PIP_SMOKE_SUCCESS\n", ""))

    def test_full_screen_host_is_another_app_built_into_the_runner_root(self):
        # DEV-962: PiP is checked over another app's full-screen window, not one of Arx's own.
        root = Path("/runner/app-smoke-x")
        with mock.patch.object(media_smoke, "run") as run:
            environment = media_smoke.build_full_screen_host(root)
        self.assertEqual(environment, {"ARX_MEDIA_SMOKE_FULL_SCREEN_HOST": str(root / "full-screen-host")})
        arguments = run.call_args.args[0]
        self.assertEqual(arguments[:2], ["xcrun", "swiftc"])
        self.assertTrue(arguments[-3].endswith("Scripts/fixtures/FullScreenHostFixture.swift"))
        self.assertEqual(arguments[-2:], ["-o", str(root / "full-screen-host")])
        self.assertTrue((media_smoke.ROOT / media_smoke.FULL_SCREEN_HOST).is_file())

    def test_dev852_window_phases_are_required(self):
        for marker in ("ARX_AUTOMATIC_PIP_FULL_SCREEN_SUCCESS", "ARX_AUTOMATIC_PIP_FLING_SUCCESS",
                       "ARX_AUTOMATIC_PIP_TIME_LABELS_SUCCESS", "ARX_AUTOMATIC_PIP_DISPLAY_CHANGE_SUCCESS"):
            self.assertIn(marker, media_smoke.MARKERS)

    def test_dev949_page_full_screen_phases_are_required(self):
        for marker in ("ARX_PAGE_FULL_SCREEN_VIDEO_SUCCESS", "ARX_PAGE_FULL_SCREEN_ESCAPE_SUCCESS",
                       "ARX_PAGE_FULL_SCREEN_ELEMENT_SUCCESS", "ARX_PAGE_FULL_SCREEN_TAB_SWITCH_SUCCESS",
                       "ARX_PAGE_FULL_SCREEN_KEEPS_WINDOW_SUCCESS", "ARX_PAGE_FULL_SCREEN_SMOKE_SUCCESS"):
            self.assertIn(marker, media_smoke.MARKERS)

    def test_dev991_page_full_screen_phases_are_required(self):
        for marker in ("ARX_PAGE_FULL_SCREEN_STAYS_SUCCESS", "ARX_PAGE_FULL_SCREEN_PAGE_EXIT_SUCCESS",
                       "ARX_PAGE_FULL_SCREEN_SIDEBAR_SUCCESS", "ARX_PAGE_FULL_SCREEN_APP_WINDOW_STAYS_SUCCESS",
                       "ARX_PAGE_FULL_SCREEN_APP_WINDOW_SIDEBAR_SUCCESS", "ARX_PAGE_FULL_SCREEN_APP_WINDOW_RESTORE_SUCCESS"):
            self.assertIn(marker, media_smoke.MARKERS)

    def test_dev950_page_picture_phases_are_required(self):
        for marker in ("ARX_PAGE_PICTURE_CLICK_SUCCESS", "ARX_PAGE_PICTURE_TYPING_SUCCESS",
                       "ARX_PAGE_PICTURE_RETURN_SUCCESS", "ARX_PAGE_PICTURE_SMOKE_SUCCESS"):
            self.assertIn(marker, media_smoke.MARKERS)
