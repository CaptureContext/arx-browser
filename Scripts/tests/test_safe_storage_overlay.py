"""Safe Storage never resets the key silently, and decrypted secrets are wiped (DEV-900)."""

from pathlib import Path
import shutil
import tempfile
import unittest

from Scripts.engine import safe_storage_overlay as overlay
from Scripts.engine.config import SOURCE
from Scripts.engine.overlay import PACKAGE


def prepare(root):
    for relative, old, _ in overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


class SafeStorageOverlayTests(unittest.TestCase):
    def test_apply_is_repeatable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            first = snapshot(root)
            overlay.apply(root)
            self.assertEqual(first, snapshot(root))

            password = (root / overlay.PASSWORD).read_text()
            # The key is only ever created, never overwritten.
            self.assertNotIn("keychain.AddGenericPassword(", password)
            self.assertIn("keychain.AddGenericPasswordIfAbsent(", password)
            self.assertLess(password.index("if (policy && !policy())"),
                            password.index("return AddRandomPasswordToKeychain("))
            # Arx Dev names its own item from its Info.plist (DEV-1013).
            self.assertIn("service_name(\n      arx::SafeStorageKeyServiceName())", password)
            self.assertIn("account_name(\n      arx::SafeStorageKeyAccountName())", password)
            self.assertIn('@"ArxStorageKeyService"', password)
            self.assertIn('@"ArxStorageKeyAccount"', password)
            self.assertIn('#include "base/apple/bundle_locations.h"', password)
            provider = (root / overlay.PROVIDER).read_text()
            self.assertLess(provider.index("if (g_arx_unavailable_handler)"),
                            provider.index("if (on_failure_)"))
            self.assertNotIn("Helium", (root / overlay.STRINGS).read_text())
            encryptor = (root / overlay.ENCRYPTOR).read_text()
            self.assertEqual(encryptor.count("ArxWipe("), 4)
            password_string = (root / overlay.PASSWORD_STRING).read_text()
            self.assertNotIn("PasswordString::~PasswordString() = default;", password_string)

    def test_every_changed_anchor_fails_closed(self):
        for index, (relative, old, _) in enumerate(overlay.patches()):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                path = root / relative
                path.write_text(path.read_text().replace(old, "changed upstream anchor\n", 1))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    overlay.apply(root)

    def test_hmac_fallback_respects_the_kill_switch(self):
        for relative, old, new in overlay.patches():
            if relative == overlay.PREF_HASHES and "ValidateHmac" in new:
                self.assertIn("kDisallowLegacyPrefMacFallback", new)

    def test_hooks_are_declared_and_copied(self):
        hooks = (PACKAGE / "Native/safe_storage_hooks.h").read_text()
        for setter in ["SetSafeStorageKeyCreationPolicy", "SetSafeStorageUnavailableHandler"]:
            self.assertIn(f"void {setter}(", hooks)
            self.assertTrue(any(f"void arx::{setter}(" in new for _, _, new in overlay.patches()))
        build = (PACKAGE / "Native/BUILD.gn").read_text()
        copied = (Path(overlay.__file__).parent / "overlay.py").read_text()
        for name in ["safe_storage_hooks.h", "safe_storage_bridge.h", "safe_storage_bridge.mm"]:
            self.assertIn(f'"{name}",', build)
            self.assertIn(f'"{name}"', copied)
        bridge = (PACKAGE / "Native/engine_bridge.mm").read_text()
        self.assertIn("safe_storage::Prepare(State().unattended);", bridge)

    @unittest.skipUnless((SOURCE / overlay.PROVIDER).is_file(), "no prepared Chromium tree")
    def test_anchors_match_the_prepared_chromium_tree(self):
        if "g_arx_unavailable_handler" in (SOURCE / overlay.PROVIDER).read_text():
            self.skipTest("the prepared tree already has the overlay")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in {relative for relative, _, _ in overlay.patches()}:
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(SOURCE / relative, root / relative)
            overlay.apply(root)
            overlay.apply(root)


if __name__ == "__main__":
    unittest.main()
