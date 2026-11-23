"""An extension's own tab reaches Arx when Chrome has no browser window for it (DEV-1314)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import extension_tab_create_overlay as overlay
from Scripts.engine.config import SOURCE


def prepare(root):
    for relative, old, _ in overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


class ExtensionTabCreateOverlayTests(unittest.TestCase):
    def test_apply_is_repeatable_and_asks_arx_before_bailing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            first = snapshot(root)
            overlay.apply(root)
            self.assertEqual(first, snapshot(root))

            source = (root / overlay.SOURCE).read_text()
            self.assertEqual(source.count('#include "chrome/browser/arx/extension_window_hooks.h"  // nogncheck'), 1)
            self.assertEqual(source.count("arx::OpenExtensionTab("), 1)
            # Arx is asked only where Chrome found no window, before the call
            # answers "No current window", and it answers later.
            self.assertLess(source.index("arx::OpenExtensionTab("), source.index(overlay.BAIL))
            self.assertIn("if (!browser && extension() && !split_with_tab_id_", source)
            self.assertIn("return RespondLater();", source)
            # The answer is the placed page's tab, or the error Chrome gives.
            self.assertIn("CreateTabObjectHelper(contents", source)
            self.assertIn("ExtensionTabUtil::kNoCurrentWindowError", source)

    def test_every_changed_anchor_fails_closed(self):
        for index, (relative, old, _) in enumerate(overlay.patches()):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                path = root / relative
                path.write_text(path.read_text().replace(old, "changed upstream\n"))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    overlay.apply(root)

    def test_the_engine_fingerprint_covers_the_overlay(self):
        from Scripts.engine import artifact

        text = Path(artifact.__file__).read_text()
        self.assertIn("Scripts/engine/extension_tab_create_overlay.py", text)

    @unittest.skipUnless((SOURCE / overlay.SOURCE).is_file(), "needs the prepared Chromium 157 tree")
    def test_each_anchor_is_unique_in_the_pinned_source(self):
        text = (SOURCE / overlay.SOURCE).read_text()
        for _, old, new in overlay.patches():
            self.assertTrue(text.count(old) == 1 or text.count(new) == 1, old)


if __name__ == "__main__":
    unittest.main()
