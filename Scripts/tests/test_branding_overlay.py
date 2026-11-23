"""Arx's branding in place of Helium's (DEV-1100): logos, names and the checks that guard them."""

from pathlib import Path
import tempfile
import textwrap
import unittest

from Scripts.engine import branding_overlay

# Grit's message ids, stood in by a stable hash so the test needs no Chromium tree.
TCLIB = textwrap.dedent('''
    import hashlib

    def GenerateMessageId(text, meaning=""):
        return str(int(hashlib.sha1((meaning + "|" + text).encode()).hexdigest()[:12], 16))
''')

GRD = textwrap.dedent('''\
    <?xml version="1.0" encoding="UTF-8"?>
    <grit-part>
      <!-- Helium's own strings. -->
      <message name="IDS_A" desc="About">Helium is up to date. <ph name="LINK">$1</ph> Open helium://settings in Helium.</message>
      <message name="IDS_COPYRIGHT" desc="Copyright">Copyright <ph name="YEAR">$1</ph> The Helium Authors.</message>
      <message name="IDS_UNTOUCHED" desc="Plain">Nothing to rename.</message>
    </grit-part>
''')


def fingerprint(text, meaning=""):
    import hashlib
    return str(int(hashlib.sha1((meaning + "|" + text).encode()).hexdigest()[:12], 16))


def prepare(root):
    for relative in branding_overlay.LOGOS:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"Helium's logo")
    tclib = root / "tools/grit/grit/extern"
    tclib.mkdir(parents=True)
    (root / "tools/grit/grit/__init__.py").write_text("")
    (tclib / "__init__.py").write_text("")
    (tclib / "tclib.py").write_text(TCLIB)
    strings = root / "chrome/app"
    strings.mkdir(parents=True, exist_ok=True)
    (strings / "about_strings.grdp").write_text(GRD)
    old = fingerprint("Helium is up to date. LINK Open helium://settings in Helium.")
    (strings / "resources").mkdir()
    (strings / "resources/about_de.xtb").write_text(textwrap.dedent(f'''\
        <?xml version="1.0" ?>
        <translationbundle lang="de">
        <translation id="{old}">Helium ist aktuell. <ph name="LINK"/> helium://settings in Helium-Fenster öffnen. 重新安装Helium, Helium이.</translation>
        </translationbundle>
    '''))
    # Platforms Arx doesn't build are left alone.
    (root / "ios").mkdir()
    (root / "ios/strings.grd").write_text(GRD)


class BrandingOverlayTests(unittest.TestCase):
    def test_every_logo_becomes_arxs_and_helium_is_renamed_with_translations_kept(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            branding_overlay.apply(root)
            for relative, asset in branding_overlay.LOGOS.items():
                self.assertEqual((root / relative).read_bytes(), (branding_overlay.ASSETS / asset).read_bytes(), relative)

            strings = (root / "chrome/app/about_strings.grdp").read_text()
            self.assertIn("Arx is up to date.", strings)
            self.assertIn("helium://settings in Arx.", strings)
            self.assertIn("The Helium Authors.", strings)
            self.assertIn("Helium's own strings", strings)  # Comments are kept, but read as names.
            translation = (root / "chrome/app/resources/about_de.xtb").read_text()
            new = fingerprint("Arx is up to date. LINK Open helium://settings in Arx.")
            self.assertIn(f'id="{new}"', translation)
            self.assertIn("Arx ist aktuell.", translation)
            # Compounds and names beside Han or Hangul text are renamed too.
            self.assertIn("helium://settings in Arx-Fenster öffnen. 重新安装Arx, Arx이.", translation)
            self.assertIn("Helium is up to date.", (root / "ios/strings.grd").read_text())

            # A second pass changes nothing.
            before = {path: path.read_bytes() for path in root.rglob("*") if path.is_file()}
            branding_overlay.apply(root)
            self.assertEqual(before, {path: path.read_bytes() for path in root.rglob("*") if path.is_file()})

    def test_the_check_stops_preparation_when_helium_comes_back(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            branding_overlay.apply(root)
            # The comment still names Helium: only what the engine shows counts.
            branding_overlay.check(root)
            logo = root / "chrome/app/theme/chromium/product_logo_256.png"
            logo.write_bytes(b"Helium's logo")
            with self.assertRaisesRegex(ValueError, "product_logo_256.png"):
                branding_overlay.check(root)
            branding_overlay.apply(root)
            (root / "chrome/app/extra_strings.grdp").write_text(GRD)
            with self.assertRaisesRegex(ValueError, "extra_strings.grdp"):
                branding_overlay.check(root)

    def test_the_built_framework_bundles_arxs_logo_and_english_strings(self):
        with tempfile.TemporaryDirectory() as directory:
            resources = Path(directory)
            (resources / "en.lproj").mkdir()
            (resources / "product_logo_32.png").write_bytes((branding_overlay.ASSETS / "product_logo_32.png").read_bytes())
            (resources / "en.lproj/locale.pak").write_bytes(b"\x05Arx is up to date\x00Copyright The Helium Authors\x00helium://settings")
            branding_overlay.check_framework(resources)
            (resources / "en.lproj/locale.pak").write_bytes(b"Helium is up to date")
            with self.assertRaisesRegex(ValueError, "name Helium"):
                branding_overlay.check_framework(resources)
            (resources / "product_logo_32.png").write_bytes(b"Helium's logo")
            with self.assertRaisesRegex(ValueError, "Helium's logo"):
                branding_overlay.check_framework(resources)

    def test_the_built_frameworks_alerts_helper_has_arxs_icon(self):
        with tempfile.TemporaryDirectory() as directory:
            version = Path(directory)
            resources = version / "Resources"
            resources.mkdir()
            (resources / "product_logo_32.png").write_bytes((branding_overlay.ASSETS / "product_logo_32.png").read_bytes())
            icon = version / "Helpers/Arx Helper (Alerts).app/Contents/Resources/app.icns"
            icon.parent.mkdir(parents=True)
            icon.write_bytes((branding_overlay.ASSETS / "app.icns").read_bytes())
            branding_overlay.check_framework(resources)
            icon.write_bytes(b"Helium's icon")
            with self.assertRaisesRegex(ValueError, "helper has Helium's icon"):
                branding_overlay.check_framework(resources)


if __name__ == "__main__":
    unittest.main()


class PrologTests(unittest.TestCase):
    """A renamed string file keeps what came before its root element exactly: Helium's own
    generators read some of them as text and expect the root first (helium_onboarding)."""

    def test_a_file_without_a_declaration_gets_none(self):
        self.assertEqual(branding_overlay._prolog("<grit-part>\n<message/>\n</grit-part>\n"), "")

    def test_a_declaration_doctype_and_comment_are_kept_as_written(self):
        text = '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE translationbundle>\n<!-- c -->\n<translationbundle/>\n'
        self.assertEqual(
            branding_overlay._prolog(text),
            '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE translationbundle>\n<!-- c -->\n'
        )

    def test_renaming_a_grdp_without_a_declaration_writes_none(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            path = root / "components/helium_onboarding/helium_onboarding_strings.grdp"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('<grit-part>\n<message name="IDS_T" desc="Title">Helium Setup</message>\n</grit-part>\n')
            branding_overlay.rename_strings(root)
            written = path.read_text()
            self.assertTrue(written.startswith("<grit-part>"), written)
            self.assertIn("Arx Setup", written)


class ReferenceTests(unittest.TestCase):
    """Character references come back exactly as written: a decoded `&#36;` before a digit is
    a placeholder outside <ph> to grit, which stops the build."""

    def test_a_renamed_message_keeps_its_character_references(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            path = root / "chrome/app/os_settings_strings.grdp"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n<grit-part>\n'
                '<message name="IDS_DEAL" desc="Deal">Save &#36;50 in Helium &amp; more, &quot;now&quot;&#160;!</message>\n'
                '</grit-part>\n'
            )
            branding_overlay.rename_strings(root)
            written = path.read_text()
            self.assertIn("Save &#36;50 in Arx &amp; more, &quot;now&quot;&#160;!", written)
