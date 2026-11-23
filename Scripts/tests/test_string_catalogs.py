"""String catalogs keep one entry per key (DEV-1143).

JSON lets a key appear twice and keeps only one of the values, so a duplicate in an `.xcstrings`
file builds, and one of its strings is silently lost.
"""

import json
import subprocess
import unittest
from pathlib import Path

from Scripts.core.paths import ROOT


def catalogs(root=ROOT):
    """Every string catalog the repository tracks; submodules and build products aren't in it."""
    listed = subprocess.run(
        ["git", "ls-files", "-z", "--", "*.xcstrings"],
        cwd=root, check=True, capture_output=True, text=True,
    ).stdout
    return [root / name for name in listed.split("\0") if name]


def duplicate_keys(text):
    """Each key that appears more than once within one object of the JSON text."""
    duplicates = []

    def check(pairs):
        seen = set()
        for key, _ in pairs:
            if key in seen and key not in duplicates:
                duplicates.append(key)
            seen.add(key)
        return dict(pairs)

    json.loads(text, object_pairs_hook=check)
    return duplicates


class StringCatalogTests(unittest.TestCase):
    def test_every_catalog_has_one_entry_per_key(self):
        found = catalogs()
        self.assertTrue(any(path.name == "AppUI.xcstrings" for path in found), found)
        for path in found:
            with self.subTest(catalog=str(path.relative_to(ROOT))):
                self.assertEqual(duplicate_keys(path.read_text(encoding="utf-8")), [])

    def test_a_key_written_twice_is_found(self):
        text = """{
          "sourceLanguage": "en",
          "strings": {
            "settings.webKitSites": {"localizations": {"en": {"stringUnit": {"value": "WebKit sites"}}}},
            "settings.webKitPages": {"localizations": {"en": {"stringUnit": {"value": "Pages"}}}},
            "settings.webKitSites": {"localizations": {"en": {"stringUnit": {"value": "Sites"}}}}
          }
        }"""
        self.assertEqual(duplicate_keys(text), ["settings.webKitSites"])
        # Plain decoding keeps only the last value, which is why this check exists.
        self.assertEqual(
            json.loads(text)["strings"]["settings.webKitSites"]["localizations"]["en"]["stringUnit"]["value"],
            "Sites",
        )

    def test_the_same_key_in_different_entries_is_not_a_duplicate(self):
        text = """{"strings": {
          "a": {"localizations": {"en": {"stringUnit": {"value": "A"}}}},
          "b": {"localizations": {"en": {"stringUnit": {"value": "B"}}}}
        }}"""
        self.assertEqual(duplicate_keys(text), [])


if __name__ == "__main__":
    unittest.main()
