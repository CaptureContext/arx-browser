"""Security components update without Helium's services consent, and nothing else does (DEV-874)."""

from pathlib import Path
import re
import shutil
import tempfile
import unittest

from Scripts.engine import component_updates_overlay as overlay
from Scripts.engine.config import SOURCE
from Scripts.engine.overlay import PACKAGE

HEADER = PACKAGE / "Native/component_updates.h"


def prepare(root):
    for relative, old, _ in overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


def crx_id(public_key_hash):
    """Chromium's GetCrxIdFromPublicKeyHash: the first 16 bytes, one letter a-p per nibble."""
    return "".join(chr(ord("a") + (byte >> 4)) + chr(ord("a") + (byte & 0xF)) for byte in public_key_hash[:16])


class ComponentUpdatesOverlayTests(unittest.TestCase):
    def test_apply_is_repeatable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            first = snapshot(root)
            overlay.apply(root)
            self.assertEqual(first, snapshot(root))

            installer = (root / overlay.INSTALLER).read_text()
            self.assertNotIn("kAllowedComponents", installer)
            self.assertIn("arx::IsNetworkUpdatedComponent(registration_info->crx_id)", installer)
            service = (root / overlay.SERVICE).read_text()
            self.assertIn("arx::IsNetworkUpdatedComponent(item->app_id)", service)
            configurator = (root / overlay.CONFIGURATOR).read_text()
            self.assertNotIn("helium::GetComponentUpdateURL", configurator)
            self.assertIn("return {GURL(arx::kComponentUpdateURL)};", configurator)
            self.assertIn("// Arx sends no install or update pings.\n  return {};", configurator)
            self.assertIn("return std::make_unique<ArxComponentProtocolHandlerFactory>();", configurator)
            self.assertLess(configurator.index("class ArxComponentRequestSerializer"),
                            configurator.index("class ChromeConfigurator"))
            page = (root / overlay.COMPONENTS_PAGE).read_text()
            self.assertNotIn("ShouldAccessComponentUpdateService", page)

    def test_every_changed_anchor_fails_closed(self):
        for index, (relative, old, _) in enumerate(overlay.patches()):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                path = root / relative
                path.write_text(path.read_text().replace(old, "changed upstream anchor\n", 1))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    overlay.apply(root)

    def test_signing_stays_on_and_widevine_stays_off(self):
        replacements = {old: new for _, old, new in overlay.patches()}
        self.assertIn("return true;", replacements["  return configurator_impl_.EnabledCupSigning();\n"])
        header = HEADER.read_text()
        allowlist = header[header.index("kNetworkUpdatedComponents ="):]
        allowlist = allowlist[:allowlist.index("});")]
        self.assertEqual(re.findall(r"k\w+ComponentId", allowlist),
                         ["kCRLSetComponentId", "kPKIMetadataComponentId", "kSSLErrorAssistantComponentId"])
        self.assertNotIn("oimompecagnajdejgnnjijobebaeigek", allowlist)

    def test_request_never_names_this_mac(self):
        header = HEADER.read_text()
        kept = set(re.findall(r'"([@\w]+)"', header[header.index("kComponentRequestKeys"):]))
        for field in ["hw", "updaters", "ping", "cohort", "iid", "installdate", "brand", "lang",
                      "domainjoined", "dlpref", "events", "data", "cached_items", "installedby"]:
            self.assertNotIn(field, kept)

    def test_header_is_copied_into_the_engine(self):
        build = (PACKAGE / "Native/BUILD.gn").read_text()
        self.assertIn('"component_updates.h",', build)
        self.assertIn('"component_updates.h"', (Path(overlay.__file__).parent / "overlay.py").read_text())

    @unittest.skipUnless((SOURCE / overlay.CONFIGURATOR).is_file(), "no prepared Chromium tree")
    def test_ids_and_anchors_match_the_prepared_chromium_tree(self):
        header = HEADER.read_text()
        installers = SOURCE / "chrome/browser/component_updater"
        for name, source in [("kCRLSetComponentId", "crl_set_component_installer.cc"),
                             ("kPKIMetadataComponentId", "pki_metadata_component_installer_policy.cc"),
                             ("kSSLErrorAssistantComponentId", "ssl_error_assistant_component_installer.cc")]:
            text = (installers / source).read_text()
            key = re.search(r"k\w+PublicKeySHA256\[(?:32)?\]\s*=\s*\{([^}]*)\}", text)
            expected = crx_id([int(byte, 16) for byte in re.findall(r"0x([0-9a-fA-F]{2})", key.group(1))])
            self.assertIn(f'{name} =\n    "{expected}"', header)
        if "arx::kComponentUpdateURL" in (SOURCE / overlay.CONFIGURATOR).read_text():
            self.skipTest("the prepared tree already has the overlay")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in {relative for relative, _, _ in overlay.patches()}:
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(SOURCE / relative, root / relative)
            overlay.apply(root)
            overlay.apply(root)


if __name__ == "__main__":
    unittest.main()
