"""Device choosers reach Arx before Chrome looks for a browser window (DEV-905)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import device_chooser_overlay as overlay


def prepare(root):
    for relative, old, _ in overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


class DeviceChooserOverlayTests(unittest.TestCase):
    def test_apply_is_repeatable_and_asks_the_embedder_first(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            first = snapshot(root)
            overlay.apply(root)
            self.assertEqual(first, snapshot(root))

            source = (root / overlay.SOURCE).read_text()
            self.assertIn('#include "chrome/browser/arx/device_chooser_hooks.h"  // nogncheck', source)
            self.assertEqual(source.count("void arx::SetDeviceChooserHandler("), 1)
            # The setter sits outside Chrome's namespace; the call comes before anything else.
            self.assertLess(source.index("}  // namespace chrome"), source.index("void arx::SetDeviceChooserHandler("))
            self.assertLess(source.index("g_arx_device_chooser(owner, controller, &close)"),
                            source.index("namespace chrome {\n\nbase::OnceClosure ShowDeviceChooserDialog") + 400)

    def test_every_changed_anchor_fails_closed(self):
        for index, (relative, old, _) in enumerate(overlay.patches()):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                path = root / relative
                path.write_text(path.read_text().replace(old, "changed upstream\n"))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    overlay.apply(root)


if __name__ == "__main__":
    unittest.main()
