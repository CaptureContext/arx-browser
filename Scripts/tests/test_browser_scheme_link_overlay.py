"""Refused chrome:// links overlay (DEV-1193): every hook applies once, and again changes nothing."""
from pathlib import Path
import tempfile
import unittest

from Scripts.engine import browser_scheme_link_overlay as overlay
from Scripts.engine.config import PACKAGE


class BrowserSchemeLinkOverlayTests(unittest.TestCase):
    def test_applies_once_to_an_upstream_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative, before, _ in overlay.patches():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(before + "\n")
            overlay.apply(root)
            first = {path: path.read_bytes() for path in root.rglob("*") if path.is_file()}
            overlay.apply(root)
            self.assertEqual(first, {path: path.read_bytes() for path in root.rglob("*") if path.is_file()})
            for relative, _, after in overlay.patches():
                self.assertEqual((root / relative).read_text().count(after), 1, relative)
            self.assertTrue((root / overlay.MOJOM_DIRECTORY / "browser_scheme_link.mojom").is_file())
            self.assertTrue((root / overlay.HELPER_DIRECTORY / "arx_browser_scheme_link.h").is_file())

    def test_every_refusal_reports_and_the_browser_binds_it(self):
        patched = "".join(after for _, _, after in overlay.patches())
        # A link in the frame, a new window and a remote frame's navigation.
        self.assertEqual(patched.count("ArxReportRefusedBrowserLink("), 3)
        self.assertIn("map->Add<blink::mojom::ArxBrowserSchemeLinkHost>(&arx::BindBrowserSchemeLinkHost);", patched)
        self.assertIn('"arx/browser_scheme_link.mojom",', patched)

    def test_only_activated_chrome_links_report(self):
        helper = (PACKAGE / "Native/browser_scheme_link/arx_browser_scheme_link.h").read_text()
        self.assertIn('url.ProtocolIs("chrome")', helper)
        self.assertIn("LocalFrame::HasTransientUserActivation(frame)", helper)
        bridge = (PACKAGE / "Native/browser_scheme_link_bridge.mm").read_text()
        # The browser's own record of the activation decides, not the renderer's word.
        self.assertIn("frame->HasTransientUserActivation()", bridge)
        self.assertIn('url.SchemeIs("chrome")', bridge)
        self.assertIn("kMaximumLinkLength", bridge)

    def test_the_files_are_copied_and_the_link_is_offered_as_an_app_link(self):
        from Scripts.engine import overlay as engine_overlay
        source = Path(engine_overlay.__file__).read_text()
        self.assertIn('"browser_scheme_link_bridge.mm"', source)
        self.assertIn("apply_browser_scheme_links(source)", source)
        bridge = (PACKAGE / "Native/browser_scheme_link_bridge.mm").read_text()
        # The external-link offer (ABI50), guarded by the document that asked; no new export.
        self.assertIn("OfferExternalLink(contents, url, frame->GetLastCommittedOrigin()", bridge)
        # Chrome's own external-protocol guard: it fails once the frame starts leaving.
        self.assertIn("GetDialogDecisionGuard(contents, frame->GetWeakDocumentPtr())", bridge)
        self.assertNotIn("ArxEngineSetBrowserSchemeLinkHandler", source)

if __name__ == "__main__":
    unittest.main()
