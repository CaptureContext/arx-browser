"""Helium's omnibox bang manager answers at once and never builds its loader."""

from pathlib import Path
import re
import shutil
import tempfile
import unittest

from Scripts.engine import bangs_overlay

FIXTURE = Path(__file__).parent / "fixtures/bangs-overlay/template_url_bang_manager.cc"


def prepare(root):
    target = root / bangs_overlay.MANAGER
    target.parent.mkdir(parents=True)
    shutil.copy2(FIXTURE, target)
    return target


def load_bangs(source):
    match = re.search(r"void BangManager::LoadBangs\(.*?\n}\n", source, re.S)
    return match.group(0)


class BangsOverlayTests(unittest.TestCase):
    def test_load_answers_without_a_fetch_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            target = prepare(Path(directory))
            self.assertIn("  StartFetch();\n", load_bangs(FIXTURE.read_text()))
            bangs_overlay.apply(Path(directory))
            first = target.read_text()
            bangs_overlay.apply(Path(directory))
            self.assertEqual(first, target.read_text())

            body = load_bangs(first)
            self.assertNotIn("StartFetch", body)
            self.assertNotIn("ShouldFetchBangs", body)
            self.assertEqual(
                body.count("OnBangsLoaded(base::MakeRefCounted<Catalogue>(std::vector<Bang>()));"), 1)
            # The fetch stays defined; only the retry after a failed load calls it,
            # and an empty catalogue isn't a failure.
            self.assertEqual(first.count("&BangManager::StartFetch"), 1)
            self.assertIn("if (!result && helium::ShouldFetchBangs(*prefs_)) {", first)

    def test_changed_anchor_fails_closed(self):
        for _, anchor, _ in bangs_overlay.patches():
            lines = anchor.splitlines(keepends=True)
            for index, line in enumerate(lines):
                if not line.strip():
                    continue
                changed = "".join(lines[:index] + [line.rstrip("\n") + " // changed upstream\n"] + lines[index + 1:])
                with self.subTest(line=line), tempfile.TemporaryDirectory() as directory:
                    target = prepare(Path(directory))
                    target.write_text(target.read_text().replace(anchor, changed, 1))
                    with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                        bangs_overlay.apply(Path(directory))


if __name__ == "__main__":
    unittest.main()
