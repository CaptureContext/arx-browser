"""Private windows reach chrome.windows for callers allowed there (DEV-973).

The tabs overlay inserts the windows hook, and this overlay upgrades it. A tree
prepared at ABI22 holds the hook without the incognito permission; preparing it
again must migrate it to the ABI56 text, once, and leave nothing of the old.
"""
from pathlib import Path
import tempfile
import unittest

from Scripts.engine import extension_tabs_overlay as tabs
from Scripts.engine import extension_windows_overlay as windows


def prepare(root, *, abi22):
    """The anchors both overlays need; with `abi22`, the tabs overlay's ABI22 insertions
    and the windows helper as an ABI22 preparation left them."""
    for relative, before, after in tabs.abi21_patches():
        write(root, relative, windows.upgrade_abi22(after) if abi22 else before)
    for relative, before, after in windows.patches():
        if abi22 and relative == windows.WINDOWS_SOURCE and after == windows.upgrade(windows.WINDOWS_HELPER):
            write(root, relative, windows.WINDOWS_HELPER + before)
        elif before not in "".join(windows.upgrade_abi22(a) for _, _, a in tabs.abi21_patches()):
            write(root, relative, before)


def write(root, relative, text):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as stream:
        stream.write(text + "\n")


def apply(root):
    tabs.apply(root)
    windows.apply(root)


def snapshot(root):
    return {path.relative_to(root): path.read_text() for path in root.rglob("*") if path.is_file()}


class ExtensionWindowsOverlayTests(unittest.TestCase):
    def check(self, abi22):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root, abi22=abi22)
            apply(root)
            first = snapshot(root)
            apply(root)
            self.assertEqual(first, snapshot(root))
            text = "".join(first.values())
            for before, after in windows.ABI56_UPGRADES:
                self.assertEqual(text.count(after), 1, after)
            self.assertNotIn('dict.Set("incognito", false);', text)
            self.assertNotIn("return windows.Run(browser_context, sender);", text)
            self.assertEqual(text.count("include_incognito_information());"), 2)
            # DEV-1019: tabs.executeScript and insertCSS take an embedder tab, once.
            self.assertEqual(text.count("(window || ExtensionTabUtil::GetEmbedderTab(contents));"), 1)
            self.assertNotIn("contents && window;", text)

    def test_an_upstream_tree_gets_the_permission_and_flag(self):
        self.check(abi22=False)

    def test_a_tree_prepared_at_abi22_is_migrated_once(self):
        self.check(abi22=True)

    def test_every_upgrade_fragment_is_in_the_abi22_text_once(self):
        inserted = "".join(windows.upgrade_abi22(after) for _, _, after in tabs.abi21_patches())
        inserted += windows.WINDOWS_HELPER
        for before, _ in windows.ABI56_UPGRADES:
            self.assertEqual(inserted.count(before), 1, before)


if __name__ == "__main__":
    unittest.main()
