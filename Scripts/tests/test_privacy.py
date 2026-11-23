"""Privacy usage descriptions (DEV-861): macOS terminates Arx when Chromium asks for a permission
whose description is missing from Info.plist, as a passkey sign-in did with Bluetooth."""

import re
import unittest

from Scripts.core.paths import ROOT
from Scripts.core.privacy import BONJOUR_SERVICES, USAGE_DESCRIPTIONS
from Scripts.engine.config import SOURCE


CHROMIUM_STRINGS = SOURCE / "chrome/tools/build/mac/infoplist_strings_util.cc"


class UsageDescriptionTests(unittest.TestCase):
    def test_app_declares_every_description(self):
        spec = (ROOT / ".xcodegen/macOS.yml").read_text()
        for key, text in USAGE_DESCRIPTIONS.items():
            with self.subTest(key=key):
                match = re.search(rf"^\s+{key}:\s*(.*)$", spec, re.MULTILINE)
                self.assertIsNotNone(match, f"{key} is missing from .xcodegen/macOS.yml")
                self.assertEqual(match.group(1).strip(), text)

    def test_app_declares_nothing_beyond_the_table(self):
        spec = (ROOT / ".xcodegen/macOS.yml").read_text()
        declared = set(re.findall(r"^\s+(NS\w+UsageDescription):", spec, re.MULTILINE))
        self.assertEqual(declared, set(USAGE_DESCRIPTIONS))

    def test_app_lists_the_cast_bonjour_service(self):
        spec = (ROOT / ".xcodegen/macOS.yml").read_text()
        match = re.search(r"^\s+NSBonjourServices:\s*\[(.*)\]$", spec, re.MULTILINE)
        self.assertIsNotNone(match, "NSBonjourServices is missing from .xcodegen/macOS.yml")
        self.assertEqual([item.strip() for item in match.group(1).split(",")], BONJOUR_SERVICES)

    def test_table_covers_chromium(self):
        if not CHROMIUM_STRINGS.exists():
            self.skipTest("engine source is not checked out")
        chromium = set(re.findall(r'"(NS\w+UsageDescription)"', CHROMIUM_STRINGS.read_text()))
        self.assertTrue(chromium, "found no usage descriptions in Chromium's Info.plist strings")
        self.assertEqual(chromium - set(USAGE_DESCRIPTIONS), set())


if __name__ == "__main__":
    unittest.main()
