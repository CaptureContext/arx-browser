"""Arx's developer world hooks apply once and fail closed on a changed anchor (DEV-668)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import developer_world_overlay


def prepare(root):
    for relative, old, _ in developer_world_overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")
    for relative in ["third_party/blink/public/common", "third_party/blink/renderer/platform/bindings"]:
        (root / relative).mkdir(parents=True, exist_ok=True)


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


class DeveloperWorldOverlayTests(unittest.TestCase):
    def test_apply_is_repeatable_and_keys_every_hook_on_the_world(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            developer_world_overlay.apply(root)
            first = snapshot(root)
            developer_world_overlay.apply(root)
            self.assertEqual(first, snapshot(root))

            ids = (root / "chrome/common/chrome_isolated_world_ids.h").read_text()
            self.assertIn("ISOLATED_WORLD_ID_ARX_DEVELOPER,", ids)
            self.assertLess(ids.index("ISOLATED_WORLD_ID_ARX_DEVELOPER"), ids.index("Numbers for isolated worlds"))
            world = (root / "third_party/blink/public/common/arx_developer_world_id.h").read_text()
            self.assertIn("kArxDeveloperWorldId = 6;", world)
            self.assertIn("kArxTranslationWorldId = 7;", world)
            self.assertLess(ids.index("ISOLATED_WORLD_ID_ARX_DEVELOPER"), ids.index("ISOLATED_WORLD_ID_ARX_TRANSLATION"))
            self.assertLess(ids.index("ISOLATED_WORLD_ID_ARX_TRANSLATION"), ids.index("Numbers for isolated worlds"))
            hooks = (root / "third_party/blink/renderer/platform/bindings/arx_developer_world.h").read_text()
            self.assertIn("world == kArxDeveloperWorldId || world == kArxTranslationWorldId", hooks)

            blink = root / "third_party/blink/renderer"
            cookie = (blink / "core/dom/document.cc").read_text()
            self.assertIn("if (IsArxDeveloperWorld(dom_window_->GetIsolate())) return String();", cookie)
            input_header = (blink / "core/html/forms/html_input_element.h").read_text()
            self.assertIn("String valueForBinding() const;", input_header)
            self.assertNotIn("{ return Value(); }", input_header)
            input_source = (blink / "core/html/forms/html_input_element.cc").read_text()
            self.assertEqual(input_source.count("arx_was_password_ |= input_type_->IsPasswordInputType();"), 2)
            self.assertIn("if (arx_was_password_) return g_empty_string;", input_source)
            for token in ["password", "cc-number", "cc-csc", "cc-exp", "one-time-code"]:
                self.assertIn(f'"{token}"', input_source)
            stores = (blink / "modules/cookie_store/cookie_store.cc").read_text()
            self.assertEqual(stores.count("IsArxDeveloperWorld(script_state->GetIsolate())"), 2)
            self.assertIn("return nullptr;", (blink / "modules/cookie_store/global_cookie_store.cc").read_text())
            credentials = (blink / "modules/credentialmanagement/authentication_credentials_container.cc").read_text()
            self.assertEqual(credentials.count("IsArxDeveloperWorld(script_state->GetIsolate())"), 3)
            self.assertIn("ThrowSecurityError", (blink / "core/html/forms/form_data.cc").read_text())

    def test_a_tree_prepared_before_abi57_gains_the_translation_world_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            ids = root / developer_world_overlay.WORLD_IDS
            ids.write_text(ids.read_text().replace(
                developer_world_overlay.WORLD_IDS_ANCHOR, developer_world_overlay.ABI34_WORLD_IDS, 1))
            developer_world_overlay.apply(root)
            developer_world_overlay.apply(root)
            text = ids.read_text()
            self.assertEqual(text.count("ISOLATED_WORLD_ID_ARX_DEVELOPER,"), 1)
            self.assertEqual(text.count("ISOLATED_WORLD_ID_ARX_TRANSLATION,"), 1)

    def test_every_changed_anchor_fails_closed(self):
        patches = developer_world_overlay.patches()
        for index, (relative, old, _) in enumerate(patches):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                path = root / relative
                path.write_text(path.read_text().replace(old, "changed upstream anchor\n", 1))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    developer_world_overlay.apply(root)

    def test_no_anchor_lies_inside_another_hook(self):
        inserted = "".join(new.replace(old, "") for _, old, new in developer_world_overlay.patches())
        for _, old, _ in developer_world_overlay.patches():
            self.assertNotIn(old, inserted)


if __name__ == "__main__":
    unittest.main()
