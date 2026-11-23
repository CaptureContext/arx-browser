"""Arx's password manager overlay applies once and fails closed on a changed anchor (DEV-708)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import password_manager_overlay


def prepare(root):
    for relative, old, _ in password_manager_overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


class PasswordManagerOverlayTests(unittest.TestCase):
    def test_apply_is_repeatable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            password_manager_overlay.apply(root)
            first = snapshot(root)
            password_manager_overlay.apply(root)
            self.assertEqual(first, snapshot(root))

            policy = (root / password_manager_overlay.POLICY).read_text()
            self.assertNotIn("kCredentialsEnableService", policy)
            visibility = (root / password_manager_overlay.ACTOR_LOGIN).read_text()
            self.assertIn('"//chrome/browser/arx:*",', visibility)
            header = (root / password_manager_overlay.CLIENT_HEADER).read_text()
            self.assertIn("static void SetEmbedderSavePrompt(EmbedderSavePrompt prompt);", header)
            source = (root / password_manager_overlay.CLIENT_SOURCE).read_text()
            self.assertEqual(source.count("ArxEmbedderSavePrompt()"), 4)
            self.assertLess(source.index("ArxEmbedderSavePrompt() {"),
                            source.index("PromptUserToSaveOrUpdatePassword("))

    def test_passkeys_stay_forced_off(self):
        policy = next(new for relative, _, new in password_manager_overlay.patches()
                      if relative == password_manager_overlay.POLICY)
        self.assertNotIn("kCredentialsEnablePasskeys", policy)

    def test_every_changed_anchor_fails_closed(self):
        for index, (relative, old, _) in enumerate(password_manager_overlay.patches()):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                path = root / relative
                path.write_text(path.read_text().replace(old, "changed upstream anchor\n", 1))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    password_manager_overlay.apply(root)

    def test_no_anchor_lies_inside_another_hook(self):
        inserted = "".join(new.replace(old, "") for _, old, new in password_manager_overlay.patches())
        for _, old, _ in password_manager_overlay.patches():
            self.assertNotIn(old, inserted)


if __name__ == "__main__":
    unittest.main()
