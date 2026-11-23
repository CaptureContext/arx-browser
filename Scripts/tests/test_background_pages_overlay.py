"""The embedder can refuse background pages in one regular profile (DEV-944)."""

from pathlib import Path
import re
import shutil
import tempfile
import unittest

from Scripts.engine import background_pages_overlay
from Scripts.engine.config import SOURCE

FIXTURES = Path(__file__).parent / "fixtures/background-pages-overlay"


def prepare(root, origin=None):
    targets = []
    for relative in (background_pages_overlay.HEADER, background_pages_overlay.SOURCE):
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2((origin / relative) if origin else FIXTURES / Path(relative).name, target)
        targets.append(target)
    return targets


def allowed_for_context(source):
    return re.search(r"bool ChromeProcessManagerDelegate::AreBackgroundPagesAllowedForContext\(.*?\n}\n",
                     source, re.S).group(0)


class BackgroundPagesOverlayTests(unittest.TestCase):
    def test_refusal_hook_is_checked_for_regular_profiles_only_and_apply_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            header, source = prepare(Path(directory))
            background_pages_overlay.apply(Path(directory))
            first = header.read_text(), source.read_text()
            background_pages_overlay.apply(Path(directory))
            self.assertEqual(first, (header.read_text(), source.read_text()))

            self.assertIn("static void SetEmbedderBackgroundPageRefusal(", first[0])
            self.assertIn("using EmbedderBackgroundPageRefusal = bool (*)(Profile* profile);", first[0])
            body = allowed_for_context(first[1])
            self.assertIn("!profile->IsOffTheRecord() &&\n      g_embedder_background_page_refusal(profile)", body)
            # The refusal comes before Chrome's own guest/system check, which stays.
            self.assertLess(body.index("g_embedder_background_page_refusal"), body.index("is_normal_session"))
            self.assertIn("return is_normal_session || profile->IsOffTheRecord();", body)
            # Per-extension checks fall back to the context check on macOS.
            self.assertIn("return AreBackgroundPagesAllowedForContext(context);", first[1])
            self.assertEqual(first[1].count("g_embedder_background_page_refusal = refusal;"), 1)
            self.assertEqual(first[1].count("g_embedder_background_page_refusal = nullptr;"), 1)

    def test_changed_anchor_fails_closed(self):
        for relative, anchor, _ in background_pages_overlay.patches():
            lines = anchor.splitlines(keepends=True)
            for index, line in enumerate(lines):
                if not line.strip():
                    continue
                changed = "".join(lines[:index] + [line.rstrip("\n") + " // changed upstream\n"] + lines[index + 1:])
                with self.subTest(relative=relative, line=line), tempfile.TemporaryDirectory() as directory:
                    prepare(Path(directory))
                    target = Path(directory) / relative
                    target.write_text(target.read_text().replace(anchor, changed, 1))
                    with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                        background_pages_overlay.apply(Path(directory))

    @unittest.skipUnless((SOURCE / background_pages_overlay.SOURCE).is_file(), "no prepared Chromium tree")
    def test_anchors_match_the_prepared_chromium_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            _, source = prepare(Path(directory), origin=SOURCE)
            background_pages_overlay.apply(Path(directory))
            self.assertIn("g_embedder_background_page_refusal(profile)", allowed_for_context(source.read_text()))


if __name__ == "__main__":
    unittest.main()
