"""Arx Dev, the Debug build, has its own bundle ID, data, Keychain item and icon (DEV-1013)."""

import json
import re
import unittest

from Scripts import signing
from Scripts.core.paths import ROOT


SPEC = ROOT / ".xcodegen/macOS.yml"


def debug_settings(spec):
    block = re.search(r"^        Debug:\n((?:          .*\n|\s*#.*\n)+)", spec, re.MULTILINE)
    assert block, "The app target has no Debug settings"
    return dict(
        line.strip().split(": ", 1) for line in block.group(1).splitlines()
        if ": " in line and not line.strip().startswith("#")
    )


def app_target(spec):
    """The Arx app target's block, so a helper's settings (ArxMCP, ArxFairPlay) never answer for it."""
    block = re.search(r"^  Arx:\n((?:(?:    |\s*#|\s*$).*\n)+)", spec, re.MULTILINE)
    assert block, "The spec has no Arx target"
    return block.group(1)


class ArxDevTests(unittest.TestCase):
    def setUp(self):
        self.spec = app_target(SPEC.read_text())

    def setting(self, name):
        match = re.search(rf"^\s+{name}:\s*(.*)$", self.spec, re.MULTILINE)
        self.assertIsNotNone(match, f"{name} is missing from .xcodegen/macOS.yml")
        return match.group(1).strip()

    def test_debug_builds_are_arx_dev(self):
        debug = debug_settings(self.spec)
        # The ARX_ settings feed PRODUCT_BUNDLE_IDENTIFIER and the icon, so make run and
        # make run-preview can override them on xcodebuild's command line.
        self.assertEqual(debug["ARX_BUNDLE_ID"], signing.DEV_BUNDLE_ID)
        self.assertEqual(debug["ARX_DISPLAY_NAME"], "Arx Dev")
        self.assertEqual(debug["ARX_APP_ICON"], "AppIcon-Dev")
        self.assertEqual(debug["ARX_STORAGE_KEY_SERVICE"], "Arx Dev Storage Key")
        self.assertEqual(debug["ARX_STORAGE_KEY_ACCOUNT"], "Arx Dev")
        # No update feed: Sparkle stays off.
        self.assertEqual(debug["ARX_UPDATE_FEED_URL"], '""')
        self.assertEqual(debug["ARX_UPDATE_BETA_FEED_URL"], '""')

    def test_release_builds_keep_the_installed_arx_identity(self):
        self.assertEqual(self.setting("PRODUCT_BUNDLE_IDENTIFIER"), "$(ARX_BUNDLE_ID)")
        self.assertEqual(self.setting("ARX_BUNDLE_ID"), signing.BUNDLE_ID)
        self.assertEqual(self.setting("ASSETCATALOG_COMPILER_APPICON_NAME"), "$(ARX_APP_ICON)")
        self.assertEqual(self.setting("ARX_APP_ICON"), "AppIcon")
        self.assertEqual(self.setting("ARX_STORAGE_KEY_SERVICE"), "Arx Storage Key")
        self.assertEqual(self.setting("ARX_STORAGE_KEY_ACCOUNT"), "Arx")

    def test_info_plist_names_chromiums_folder_and_the_keychain_item(self):
        # Chromium's folder and Arx's own follow the data folder, which is the bundle ID unless
        # make run-preview gives Arx Preview its own.
        self.assertEqual(self.setting("CrProductDirName"), "$(ARX_DATA_FOLDER)")
        self.assertEqual(self.setting("ArxDataFolder"), "$(ARX_DATA_FOLDER)")
        self.assertEqual(self.setting("ARX_DATA_FOLDER"), "$(PRODUCT_BUNDLE_IDENTIFIER)")
        self.assertEqual(self.setting("ArxSupportName"), "$(ARX_SUPPORT_NAME)")
        self.assertEqual(self.setting("ArxStorageKeyService"), "$(ARX_STORAGE_KEY_SERVICE)")
        self.assertEqual(self.setting("ArxStorageKeyAccount"), "$(ARX_STORAGE_KEY_ACCOUNT)")
        self.assertEqual(self.setting("CFBundleDisplayName"), "$(ARX_DISPLAY_NAME)")

    def test_arx_dev_has_its_own_icon(self):
        icon = ROOT / "Containers/macOS/AppIcon-Dev.icon"
        contents = json.loads((icon / "icon.json").read_text())
        for group in contents["groups"]:
            for layer in group["layers"]:
                self.assertTrue((icon / "Assets" / layer["image-name"]).is_file(), layer["image-name"])
        self.assertNotEqual(contents, json.loads((ROOT / "Containers/macOS/AppIcon.icon/icon.json").read_text()))

    def test_the_app_knows_the_same_bundle_ids(self):
        edition = (ROOT / "Packages/core/Sources/BrowserCore/ArxEdition.swift").read_text()
        self.assertIn(f'bundleIdentifier: "{signing.BUNDLE_ID}"', edition)
        self.assertIn(f'bundleIdentifier: "{signing.DEV_BUNDLE_ID}"', edition)


if __name__ == "__main__":
    unittest.main()
