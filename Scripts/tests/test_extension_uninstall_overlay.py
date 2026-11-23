"""management.uninstall confirmation (DEV-889): the embedder's sheet replaces Chrome's dialog."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import extension_uninstall_overlay
from Scripts.engine.config import PACKAGE


def prepare(root):
    for relative, old, _ in extension_uninstall_overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


class ExtensionUninstallOverlayTests(unittest.TestCase):
    def test_applies_once_and_keeps_chromes_dialog_as_the_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            extension_uninstall_overlay.apply(root)
            source = (root / extension_uninstall_overlay.SOURCE).read_text()
            header = (root / extension_uninstall_overlay.HEADER).read_text()
            extension_uninstall_overlay.apply(root)
            self.assertEqual(source, (root / extension_uninstall_overlay.SOURCE).read_text())
            self.assertEqual(header, (root / extension_uninstall_overlay.HEADER).read_text())

            self.assertIn("static void SetEmbedderUninstallConfirmation(", header)
            self.assertIn('#include "base/functional/callback.h"', header)
            # The hook runs first; Chrome's dialog delegate is still the fallback.
            hook = source.index("g_embedder_uninstall_confirmation(function->GetSenderWebContents()")
            fallback = source.rindex("std::make_unique<ManagementUninstallFunctionUninstallDialogDelegate>(")
            self.assertLess(hook, fallback)
            # The completion keeps the function alive until it answers.
            self.assertIn("base::WrapRefCounted(function)", source)

    def test_changed_anchor_stops_the_build(self):
        for index in range(len(list(extension_uninstall_overlay.patches()))):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                relative, old, _ = list(extension_uninstall_overlay.patches())[index]
                path = root / relative
                path.write_text(path.read_text().replace(old, "changed upstream\n", 1))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    extension_uninstall_overlay.apply(root)

    def test_arx_installs_and_clears_the_hook_with_the_extension_system(self):
        bridge = (PACKAGE / "Native/extensions_bridge.mm").read_text()
        self.assertEqual(bridge.count("SetEmbedderUninstallConfirmation("), 1)
        self.assertIn("enabled ? &ConfirmManagementUninstall : nullptr", bridge)
        # Installed with the extension system and cleared again at shutdown.
        self.assertIn("    ConfigureEmbedderHooks(enabled);", bridge)
        self.assertIn("    ConfigureEmbedderHooks(false);", bridge)
        handler = bridge[bridge.index("bool ConfirmManagementUninstall("):bridge.index("class Extensions final")]
        # Private and windowless requests are answered at once, never left hanging.
        self.assertIn("std::move(done).Run(false, u\"\");", handler)
        # The removal rechecks policy after the sheet.
        self.assertIn("MustRemainInstalled", handler)


if __name__ == "__main__":
    unittest.main()
