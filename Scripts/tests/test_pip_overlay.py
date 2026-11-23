"""Picture in Picture overlay (DEV-825, DEV-852, DEV-962, DEV-1295): whole files, hooks and replaced hunks."""
from pathlib import Path
import tempfile
import unittest

from Scripts.engine import pip_overlay
from Scripts.engine.config import PACKAGE


def prepare(root, previous=False):
    """Writes every anchor; with `previous`, DEV-540's inserted text in place of the anchors it replaced."""
    replaced = {(relative, before): text for relative, before, text in pip_overlay.PREVIOUS}
    for relative, before, _ in pip_overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        text = replaced.get((relative, before), before) if previous else before
        with path.open("a") as stream:
            stream.write(text + "\n")


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


class PipOverlayTests(unittest.TestCase):
    def check(self, previous):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root, previous=previous)
            pip_overlay.apply(root)
            first = snapshot(root)
            pip_overlay.apply(root)
            self.assertEqual(first, snapshot(root))

            for relative, _, after in pip_overlay.patches():
                self.assertEqual((root / relative).read_text().count(after), 1, relative)
            for relative, _, text in pip_overlay.PREVIOUS:
                self.assertNotIn(text, (root / relative).read_text())
            for name in pip_overlay.SOURCES:
                copied = root / pip_overlay.OVERLAY / name
                self.assertEqual(copied.read_bytes(), (PACKAGE / "Native/pip" / name).read_bytes())

    def test_applies_once_to_an_upstream_tree(self):
        self.check(previous=False)

    def test_replaces_earlier_hunks_in_a_tree_patched_before_them(self):
        self.check(previous=True)

    def test_previous_hunks_are_not_part_of_the_new_ones(self):
        inserted = "".join(after for _, _, after in pip_overlay.patches())
        anchors = {(relative, before) for relative, before, _ in pip_overlay.patches()}
        for relative, before, text in pip_overlay.PREVIOUS:
            self.assertNotIn(text, inserted)
            self.assertIn((relative, before), anchors)

    def test_window_rests_at_the_motion_inset(self):
        header = (PACKAGE / "Native/pip/arx_pip_motion.h").read_text()
        self.assertIn("inline constexpr double kEdgeInset = 16;", header)
        self.assertIn("inline constexpr double kCornerRadius = 16;", header)
        views = "".join(after for relative, _, after in pip_overlay.patches() if relative == pip_overlay.VIEWS)
        self.assertIn("  int buffer = 16;\n", views)

    def test_window_joins_full_screen_spaces_before_it_is_shown(self):
        # DEV-852: activation independence and full-screen Spaces right after Init, before
        # Show, as Chromium's Glic window has; canJoinAllApplications when the motion starts.
        views = dict(((relative, before), after) for relative, before, after in pip_overlay.patches())
        created = views[(pip_overlay.VIEWS, "  overlay_window->OnRootViewReady();\n")]
        self.assertIn("overlay_window->SetActivationIndependence(true);", created)
        self.assertIn("overlay_window->SetCanAppearInExistingFullscreenSpaces(true);", created)
        motion = (PACKAGE / "Native/pip/arx_pip_window_motion.mm").read_text()
        self.assertIn("NSWindowCollectionBehaviorCanJoinAllApplications", motion)
        self.assertIn("NSWindowCollectionBehaviorFullScreenAuxiliary", motion)
        self.assertIn("JoinAllSpaces(window);", motion)

    def test_document_picture_in_picture_joins_full_screen_spaces(self):
        # DEV-948: Meet's Document PiP, opened in Chromium's standalone host, between Init and Show.
        hunks = dict(((relative, before), after) for relative, before, after in pip_overlay.patches())
        created = hunks[(pip_overlay.DOCUMENT_HOST, "  widget_->Init(std::move(params));\n")]
        self.assertIn("widget_->SetActivationIndependence(true);", created)
        self.assertIn("widget_->SetCanAppearInExistingFullscreenSpaces(true);", created)

    def test_both_windows_are_non_activating_panels_from_creation(self):
        # DEV-962: macOS decides at creation whether a window may join another app's full-screen
        # Space, so the window class records the panel style before AppKit's init and answers
        # from it, and both PiP windows ask for that style.
        hunks = dict(((relative, before), after) for relative, before, after in pip_overlay.patches())
        window = "".join(after for relative, _, after in pip_overlay.patches() if relative == pip_overlay.NSWINDOW)
        self.assertLess(window.index("_arxNonactivatingAtCreation ="), window.index("[super initWithContentRect:"))
        self.assertLess(window.index("windowStyle &= ~NSWindowStyleMaskNonactivatingPanel;"),
                        window.index("[super initWithContentRect:"))
        self.assertIn("if (_activationIndependence || _arxNonactivatingAtCreation) {", window)
        for relative in (pip_overlay.WIDGET, pip_overlay.DOCUMENT_WIDGET):
            style = next(after for (path, before), after in hunks.items()
                         if path == relative and "params->style_mask" in before)
            self.assertIn("NSWindowStyleMaskNonactivatingPanel", style)

    def test_time_labels_take_the_widest_width_and_relayout(self):
        hunks = dict(((relative, before), after) for relative, before, after in pip_overlay.patches())
        update = hunks[(pip_overlay.VIEWS, "  if (was_live != is_live_) {\n    OnUpdateControlsBounds();\n  }\n")]
        self.assertIn("ArxSizeTimeLabel(\n        timestamp_", update)
        self.assertIn("ArxSizeTimeLabel(arx_duration_", update)
        self.assertIn("ArxSizeTimeLabel(\n        live_status_", update)
        self.assertIn("if (was_live != is_live_ || arx_resized)", update)
        helpers = hunks[(pip_overlay.VIEWS, "void VideoOverlayWindowViews::UpdateTimestampLabel(base::TimeDelta current_time,\n")]
        self.assertIn("SetPreferredSize", helpers)
        self.assertIn("IsDisplayTextTruncated", helpers)

    def test_time_labels_are_as_tall_as_their_line(self):
        # STYLE_BODY_4's line is 18 points; a 16-point label clipped it, and views::Label
        # reported every time as truncated, at 1x and 2x alike.
        hunks = dict(((relative, before), after) for relative, before, after in pip_overlay.patches())
        helpers = hunks[(pip_overlay.VIEWS, "void VideoOverlayWindowViews::UpdateTimestampLabel(base::TimeDelta current_time,\n")]
        self.assertIn("label->GetLineHeight() + label->GetInsets().height()", helpers)
        views = "".join(after for relative, _, after in pip_overlay.patches() if relative == pip_overlay.VIEWS)
        self.assertNotIn("kArxTimeHeight", views)
        self.assertIn("times_center - size.height() / 2", views)
        # A tree patched with the 16-point labels gets both hunks put back first.
        earlier = [text for relative, _, text in pip_overlay.PREVIOUS if "kArxTimeHeight" in text]
        self.assertEqual(len(earlier), 2)
        self.assertTrue(any("const int time_y = bar.y() + (kArxBar - kArxTimeHeight) / 2;" in text for text in earlier))
        self.assertTrue(any("label->SetPreferredSize(gfx::Size(width, kArxTimeHeight));" in text for text in earlier))

    def test_controls_are_bare_symbols_over_scrims(self):
        # DEV-1295, Figma's "Scrim" variant: no glass behind the buttons or the
        # time, Chromium's scrims behind everything, close alone top left.
        views = "".join(after for relative, _, after in pip_overlay.patches() if relative == pip_overlay.VIEWS)
        self.assertNotIn("arx_progress_backing_", views)
        self.assertEqual(views.count("ArxGlass(hang_up_button_"), 1)
        # The definition and the hang-up button: nothing else is glass.
        self.assertEqual(views.count("ArxGlass("), 2)
        self.assertIn("controls_top_scrim_view_->SetBounds(0, 0, width, kArxTopScrim);", views)
        self.assertIn("minimize_button_->SetVisible(false);", views)
        self.assertIn("CreateRoundedRectBackground(kArxLive", views)
        header = "".join(after for relative, _, after in pip_overlay.patches() if relative == pip_overlay.VIEWS_H)
        self.assertNotIn("arx_progress_backing_", header)
        # A tree patched with the glass controls gets them put back first.
        self.assertIn((pip_overlay.VIEWS, pip_overlay.CONTROLS_ANCHOR, pip_overlay.CONTROLS_DEV852), pip_overlay.PREVIOUS)
        self.assertIn((pip_overlay.VIEWS_H, pip_overlay.MEMBERS_ANCHOR, pip_overlay.MEMBERS_DEV852), pip_overlay.PREVIOUS)

    def test_settles_follow_the_target_screen_and_display_changes(self):
        motion = (PACKAGE / "Native/pip/arx_pip_window_motion.mm").read_text()
        self.assertIn("[screen displayLinkWithTarget:self", motion)
        self.assertNotIn("[window displayLinkWithTarget:", motion)
        self.assertNotIn("?: NSScreen.mainScreen", motion)
        self.assertIn("NSApplicationDidChangeScreenParametersNotification", motion)
        self.assertIn("arx_pip::KeptOnScreen(VisibleFrames(), frame)", motion)
        # Smoke checks only under the smoke runner.
        self.assertIn('std::getenv("ARX_MEDIA_SMOKE_ROOT")', motion)


if __name__ == "__main__":
    unittest.main()
