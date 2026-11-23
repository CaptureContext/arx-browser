"""An extension's own window reaches Arx before Chrome builds a browser window (DEV-1240)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import extension_window_create_overlay as overlay
from Scripts.engine.config import SOURCE


def prepare(root):
    for relative, old, _ in overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


class ExtensionWindowCreateOverlayTests(unittest.TestCase):
    def test_apply_is_repeatable_and_asks_arx_first(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            first = snapshot(root)
            overlay.apply(root)
            self.assertEqual(first, snapshot(root))

            source = (root / overlay.SOURCE).read_text()
            self.assertEqual(source.count('#include "chrome/browser/arx/extension_window_hooks.h"  // nogncheck'), 1)
            for call in ("arx::OpenExtensionWindow(", "arx::UpdateExtensionWindow(", "arx::RemoveExtensionWindow("):
                self.assertEqual(source.count(call), 1, call)
            # Arx is asked before Chrome creates its window, and answers later.
            self.assertLess(source.index("arx::OpenExtensionWindow("), source.index(overlay.CREATE))
            self.assertIn("return RespondLater();", source)
            # update and remove ask after their parameters are validated.
            self.assertLess(source.index(overlay.UPDATE), source.index("arx::UpdateExtensionWindow("))
            self.assertLess(source.index(overlay.REMOVE), source.index("arx::RemoveExtensionWindow("))

    def test_every_changed_anchor_fails_closed(self):
        for index, (relative, old, _) in enumerate(overlay.patches()):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                path = root / relative
                path.write_text(path.read_text().replace(old, "changed upstream\n"))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    overlay.apply(root)

    @unittest.skipUnless((SOURCE / overlay.SOURCE).is_file(), "needs the prepared Chromium 157 tree")
    def test_each_anchor_is_unique_in_the_pinned_source(self):
        text = (SOURCE / overlay.SOURCE).read_text()
        for _, old, new in overlay.patches():
            self.assertTrue(text.count(old) == 1 or text.count(new) == 1, old)


if __name__ == "__main__":
    unittest.main()
