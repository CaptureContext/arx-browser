"""Arx's autofill suggestions overlay applies once and fails closed on a changed anchor (DEV-875)."""

import os
from pathlib import Path
import tempfile
import unittest

from Scripts.engine import autofill_suggestions_overlay as overlay


def prepare(root):
    for relative, old, _ in overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


class AutofillSuggestionsOverlayTests(unittest.TestCase):
    def test_apply_is_repeatable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            first = snapshot(root)
            overlay.apply(root)
            self.assertEqual(first, snapshot(root))

            header = (root / overlay.CLIENT_HEADER).read_text()
            self.assertIn("class EmbedderSuggestions {", header)
            self.assertIn("static void SetEmbedderSuggestions(EmbedderSuggestions* embedder);", header)
            source = (root / overlay.CLIENT_SOURCE).read_text()
            # Asked by show (twice), read, session, update and hide; the address save,
            # which comes earlier in the file, goes through the declared accessor.
            self.assertIn("if (GetEmbedderSuggestions()) {", source)
            self.assertLess(source.index("g_arx_embedder_suggestions = nullptr"),
                            source.index("ChromeAutofillClient::ShowAutofillSuggestions("))
            self.assertEqual(source.count("if (g_arx_embedder_suggestions"), 6)
            self.assertIn("AddressPromptUserDecision::kIgnored", source)
            payments = (root / overlay.PAYMENTS_SOURCE).read_text()
            self.assertIn("SaveCardOfferUserDecision::kIgnored", payments)
            self.assertIn('#include "chrome/browser/ui/autofill/chrome_autofill_client.h"', payments)

    def test_taken_suggestions_close_chromes_popup(self):
        show = next(new for _, old, new in overlay.patches() if old == overlay.SHOW_SIGNATURE)
        taken = show.index("->Show(web_contents()")
        self.assertLess(taken, show.index("suggestion_controller_->Hide("))
        self.assertLess(show.index("suggestion_controller_->Hide("), show.index("return arx_session;"))

    def test_every_changed_anchor_fails_closed(self):
        for index, (relative, old, _) in enumerate(overlay.patches()):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                path = root / relative
                path.write_text(path.read_text().replace(old, "changed upstream anchor\n", 1))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    overlay.apply(root)

    def test_no_anchor_lies_inside_another_hook(self):
        inserted = "".join(new.replace(old, "") for _, old, new in overlay.patches())
        for _, old, _ in overlay.patches():
            self.assertNotIn(old, inserted)

    def test_anchors_match_the_pinned_source(self):
        # ARX_PINNED_ENGINE_SOURCE names a prepared, unpatched tree (read only).
        source = Path(os.environ.get("ARX_PINNED_ENGINE_SOURCE", "/nonexistent"))
        if not (source / overlay.CLIENT_SOURCE).is_file():
            self.skipTest("set ARX_PINNED_ENGINE_SOURCE to check anchors against a source tree")
        for relative, old, _ in overlay.patches():
            with self.subTest(relative=relative):
                self.assertEqual((source / relative).read_text().count(old), 1)


if __name__ == "__main__":
    unittest.main()
