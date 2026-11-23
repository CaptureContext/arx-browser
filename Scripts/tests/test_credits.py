"""The credits the About panel shows stay in step with the notices, the licences and the resolved packages."""

import hashlib
import json
import unittest
from pathlib import Path

from Scripts import credits
from Scripts.core.paths import ROOT


class CreditsTests(unittest.TestCase):
    def test_committed_credits_are_current(self):
        self.assertEqual(
            credits.CREDITS.read_text(), credits.render(),
            "Containers/macOS/Credits.rtf is out of date. Run make credits.",
        )

    def test_every_resolved_package_has_a_notice(self):
        notices = credits.NOTICES.read_text()
        resolved = [ROOT / "Package.resolved", *sorted(ROOT.glob("Packages/*/Package.resolved"))]
        missing = sorted({
            pin["identity"]
            for path in resolved if path.is_file()
            for pin in json.loads(path.read_text()).get("pins", [])
            if f"| [{pin['identity']}](" not in notices
        })
        self.assertEqual(missing, [], "Add these packages to THIRD_PARTY_NOTICES.md, then run make credits.")

    def test_every_submodule_fork_has_a_notice(self):
        notices = credits.NOTICES.read_text()
        forks = [
            line.split("=", 1)[1].strip().removeprefix("Forks/")
            for line in (ROOT / ".gitmodules").read_text().splitlines()
            if line.strip().startswith("path =")
        ]
        self.assertEqual([fork for fork in forks if f"| [{fork}](" not in notices], [])

    def test_helium_licence_texts_are_kept_with_the_engine(self):
        licences = ROOT / "Packages/engine/Licenses"
        for repository in ("helium", "helium-macos"):
            self.assertEqual((licences / repository / "LICENSE").read_text(), credits.HELIUM_LICENSE.read_text())
            self.assertIn("BSD", (licences / repository / "LICENSE.ungoogled_chromium").read_text())
        self.assertEqual(
            (credits.LICENSES / "ungoogled-chromium.txt").read_text(),
            (licences / "helium/LICENSE.ungoogled_chromium").read_text(),
            "The credits show Helium core's ungoogled-chromium licence.",
        )

    def test_markdown_subset(self):
        rendered = credits.markdown(
            "## Title\n\nText with `code`, **bold**, [a link](https://example.com) and [a file](LICENSE).\n\n"
            "- one\n- two\n\n| A | B |\n| -- | -- |\n| 1 | <https://x.test> |\n\n```text\n{raw} \\ é\n```\n"
        )
        self.assertIn(r"{\b\fs24 Title}", rendered)
        self.assertIn(r"{\f1\fs20 code}", rendered)
        self.assertIn(r"{\b bold}", rendered)
        self.assertIn(r'{\field{\*\fldinst{HYPERLINK "https://example.com"}}{\fldrslt a link}}', rendered)
        self.assertIn(" a file.", rendered)
        self.assertEqual(rendered.count(r"\bullet"), 2)
        self.assertIn(r"{\b A \u8212? B}", rendered)
        self.assertIn(r'HYPERLINK "https://x.test"', rendered)
        self.assertIn(r"\{raw\} \\ \u233?", rendered)

    def test_arx_is_licensed_under_the_unmodified_gpl_3(self):
        # The SHA-256 of https://www.gnu.org/licenses/gpl-3.0.txt. Helium's copies fill in the
        # appendix's sample notice, so they can't stand in for Arx's LICENSE.
        self.assertEqual(
            hashlib.sha256(credits.ARX_LICENSE.read_bytes()).hexdigest(),
            "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986",
        )
        self.assertIn("GNU General Public License, version 3", credits.INTRODUCTION)

    def test_non_ascii_and_astral_characters_are_escaped(self):
        self.assertEqual(credits.escape("Roué"), r"Rou\u233?")
        self.assertEqual(credits.escape("😀"), r"\u-10179?\u-8704?")
        self.assertTrue(credits.render().isascii())

    def test_gpl_and_every_licence_text_are_included(self):
        rendered = credits.render()
        self.assertIn("GNU GENERAL PUBLIC LICENSE", rendered)
        self.assertIn("Arx and Helium licence", rendered)
        for name in credits.LICENCE_TITLES:
            self.assertTrue((credits.LICENSES / name).is_file(), name)
        self.assertIn("Apache License", rendered)
        self.assertIn("ungoogled-chromium Authors", rendered)


if __name__ == "__main__":
    unittest.main()
