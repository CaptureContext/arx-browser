"""Protect source-update and product identity boundaries without fetching Chromium."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine.overlay import PACKAGE, apply, apply_media_activation, replace_once
from Scripts.tests.test_close_overlay import prepare as prepare_close_overlay
from Scripts.tests.test_media_freeze import FIXTURES as media_freeze_fixtures
from Scripts.tests.test_gesture_ownership import prepare as prepare_gesture_overlay
from Scripts.engine.inspection_overlay import patches as inspection_patches
from Scripts.tests.test_erasure_overlay import prepare as prepare_erasure_overlay
from Scripts.engine.document_capture_prototype import patches as document_patches

from Scripts.engine.extension_install_overlay import patches as extension_install_patches
from Scripts.engine.extension_inventory_overlay import patches as extension_inventory_patches
from Scripts.engine.background_pages_overlay import patches as background_pages_patches
from Scripts.engine.extension_navigation_overlay import patches as extension_navigation_patches
from Scripts.engine.extension_tabs_overlay import patches as extension_tabs_patches
from Scripts.engine.http_auth_overlay import patches as http_auth_patches
from Scripts.engine.extension_windows_overlay import patches as extension_windows_patches
from Scripts.engine.unattended_prompts_overlay import patches as unattended_prompts_patches
from Scripts.engine.bangs_overlay import patches as bangs_patches
from Scripts.engine.services_overlay import patches as services_patches
from Scripts.engine.developer_world_overlay import patches as developer_world_patches
from Scripts.engine.password_manager_overlay import patches as password_manager_patches
from Scripts.engine.autofill_suggestions_overlay import patches as autofill_suggestions_patches
from Scripts.engine.force_click_overlay import DELEGATE as force_click_delegate, patches as force_click_patches
from Scripts.engine.pip_overlay import patches as pip_patches
from Scripts.engine.page_consent_overlay import patches as consent_patches
from Scripts.engine.link_navigation_overlay import patches as link_navigation_patches
from Scripts.engine.external_link_overlay import patches as external_link_patches
from Scripts.engine.webstore_install_overlay import patches as webstore_install_patches
from Scripts.engine.startup_metrics_overlay import patches as startup_metrics_patches
from Scripts.engine.session_cookies_overlay import patches as session_cookies_patches
from Scripts.engine.component_updates_overlay import patches as component_updates_patches
from Scripts.engine.safe_storage_overlay import patches as safe_storage_patches
from Scripts.engine.badge_overlay import patches as badge_patches
from Scripts.engine.notification_overlay import patches as notification_patches
from Scripts.engine.cast_overlay import patches as cast_patches
from Scripts.engine.overlay import EXTRA_EXPORTS
from Scripts.tests.test_audio_volume_overlay import append_anchors as append_audio_volume_anchors
from Scripts.engine.dark_pages_overlay import patches as dark_pages_patches
from Scripts.engine.native_messaging_overlay import patches as native_messaging_patches
from Scripts.engine.extension_uninstall_overlay import patches as extension_uninstall_patches
from Scripts.engine.content_blocking_overlay import patches as content_blocking_patches
from Scripts.engine.private_extension_routing_overlay import patches as private_extension_routing_patches
from Scripts.engine.protected_media_overlay import patches as protected_media_patches
from Scripts.engine.widevine_answer_overlay import patches as widevine_answer_patches
from Scripts.engine import browser_scheme_link_overlay, page_media_overlay
from Scripts.engine.device_chooser_overlay import patches as device_chooser_patches
from Scripts.engine.live_connection_overlay import patches as live_connection_patches
from Scripts.engine.bfcache_media_session_overlay import patches as bfcache_media_session_patches
from Scripts.engine.file_stream_guard_overlay import patches as file_stream_guard_patches
from Scripts.engine.extension_window_create_overlay import patches as extension_window_create_patches
from Scripts.engine.extension_tab_create_overlay import patches as extension_tab_create_patches


class EngineOverlayTests(unittest.TestCase):
    def test_changed_upstream_anchor_fails_without_replacing_unrelated_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.cc"
            path.write_text("new upstream implementation")
            with self.assertRaises(ValueError):
                replace_once(path, "old implementation", "replacement")
            self.assertEqual(path.read_text(), "new upstream implementation")

    def test_ambiguous_anchor_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.cc"
            path.write_text("anchor anchor")
            with self.assertRaises(ValueError):
                replace_once(path, "anchor", "replacement")

    def test_page_badges_link_outside_the_file_and_end_with_their_document(self):
        native = (PACKAGE / "Native/engine_bridge.mm").read_text()
        # badge_manager.cc calls the arx::PageBadgeChanged engine_bridge.h declares.
        anonymous_end = native.index("}  // namespace\n")
        self.assertGreater(native.index("void PageBadgeChanged(content::WebContents*"), anonymous_end)
        navigation = native[native.index("void DidFinishNavigation(content::NavigationHandle* navigation) override {\n    ClearEscape();"):]
        new_document = navigation[navigation.index("!navigation->IsSameDocument()"):navigation.index("error_ = navigation->GetNetErrorCode();")]
        self.assertIn("PageBadgeChanged(web_contents(), false, 0, false);", new_document)

    def test_overlay_is_repeatable_and_separates_helium_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {
                "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h": '#include "base/memory/raw_ptr.h"\n  // Called to notify that the initiator web contents should be focused.\n  void FocusInitiator();\n private:\n',
                "chrome/browser/picture_in_picture/picture_in_picture_window_manager.cc": '    case UiBehavior::kCloseWindowAndFocusOpener:\n      pip_window_controller_->CloseAndFocusInitiator();\n      break;\nvoid PictureInPictureWindowManager::FocusInitiator() {\n  if (pip_window_controller_)\n    pip_window_controller_->FocusInitiator();\n}\n',
                "chrome/browser/chrome_browser_main.cc": '#include "chrome/browser/chrome_browser_main.h"\n  return main_parts;\n',
                "chrome/browser/devtools/chrome_devtools_manager_delegate.cc": '#include "chrome/browser/devtools/chrome_devtools_manager_delegate.h"\n\nstd::string ChromeDevToolsManagerDelegate::GetTargetType(\n    content::WebContents* web_contents) {\n  return DevToolsAgentHost::kTypeOther;\n}\n',
                "chrome/browser/app_controller_mac.mm": '#import "chrome/browser/app_controller_mac.h"\n- (void)setLastProfile:(Profile*)profile {\n}\n- (NSMenu*)applicationDockMenu:(NSApplication*)sender {\n}\n- (BOOL)shouldQuitWithInProgressDownloads {\n}\n',
                "chrome/browser/BUILD.gn": '\nsource_set("core") {\n  sources = []\n}\n',
                "chrome/app/framework.exports": "_ChromeMain\n",
                "chrome/browser/ui/views/profiles/profile_picker_view.cc": "void ProfilePicker::Show(Params&& params) {\n}\n",
                "components/download/public/common/download_item_impl.h": "  bool AllDataSaved() const override;\n",
                "chrome/browser/chrome_content_browser_client.cc": '#include "chrome/browser/chrome_content_browser_client.h"\n  const BlockedWindowParams blocked_params(\n',
                "chrome/browser/ui/blocked_content/chrome_popup_navigation_delegate.cc": '#include "build/build_config.h"\n#if BUILDFLAG(IS_ANDROID)\n  TabModelList::HandlePopupNavigation(&params_);\n#else\n  ::Navigate(&params_);\n#endif\n',
                "chrome/browser/ui/blocked_content/BUILD.gn": 'source_set("impl") {\n  deps = []\n}\n',

                "chrome/app/theme/chromium/BRANDING": "MAC_BUNDLE_ID=net.imput.helium\nMAC_TEAM_ID=S4Q33XPHB4\n",
                "components/os_crypt/common/keychain_password_mac.mm": 'const char kDefaultServiceName[] = "Helium Storage Key";\nconst char kDefaultAccountName[] = "Helium";\n',
                "chrome/browser/media/chrome_media_session_client.cc": '  return Profile::FromBrowserContext(browser_context)\n      ->IsPrimaryOTRProfileWithRegularParent();\n',
                "chrome/common/chrome_paths_mac.mm": 'product_dir_name = "net.imput.helium";\n',
            }
            files.update({"components/performance_manager/" + name: text
                          for name, text in media_freeze_fixtures.items()})
            for filename, text in files.items():
                path = root / filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            prepare_close_overlay(root)
            (root / "content/public/browser/context_menu_params.h").write_text(
                'struct ContextMenuParams : UntrustworthyContextMenuParams {\n  bool is_subframe = false;\n};\n'
            )
            with (root / "content/browser/renderer_host/render_frame_host_impl.cc").open("a") as stream:
                stream.write('  gfx::PointF transformed_point_f;\n  if (transform_succeeded) {\n    validated_params.y = root_point.y();\n  }\n')
            prepare_erasure_overlay(root)
            for relative, old, _ in [*inspection_patches(), *document_patches()]:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(old + "\n")
            public_build = root / "content/public/browser/BUILD.gn"
            public_anchors = public_build.read_text()
            prepare_gesture_overlay(root)
            with public_build.open("a") as stream:
                stream.write(public_anchors)
            # ABI24 extends the gesture overlay's delegate edits.
            for relative, old, _ in force_click_patches():
                if relative == force_click_delegate:
                    continue
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(old + "\n")
            for relative, old, _ in pip_patches():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(old + "\n")

            for relative, old, _ in [*extension_install_patches(), *extension_inventory_patches(), *background_pages_patches(), *extension_navigation_patches(), *extension_tabs_patches(), *http_auth_patches(), *consent_patches()]:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(old + "\n")
            # ABI22 extends the ABI21 edits: anchors inside their insertions come from them.
            inserted = "".join(new for _, _, new in [*extension_tabs_patches(), *http_auth_patches()])
            for relative, old, _ in [*extension_windows_patches(), *unattended_prompts_patches()]:
                if old in inserted:
                    continue
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(old + "\n")
            for relative, old, _ in [*bangs_patches(), *services_patches(), *developer_world_patches(), *password_manager_patches(), *autofill_suggestions_patches(), *link_navigation_patches(), *external_link_patches(), *webstore_install_patches(), *badge_patches(), *startup_metrics_patches(), *component_updates_patches(), *safe_storage_patches()]:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(old + "\n")
            append_audio_volume_anchors(root)
            for relative, old, _ in [*session_cookies_patches(), *native_messaging_patches(), *extension_uninstall_patches(), *content_blocking_patches(), *private_extension_routing_patches(), *notification_patches(), *protected_media_patches(), *device_chooser_patches(), *cast_patches(), *live_connection_patches(), *bfcache_media_session_patches(), *dark_pages_patches(), *widevine_answer_patches(), *file_stream_guard_patches(),
                                     # DEV-1144: the page media overlay's renderer anchors come from inspection_overlay.py.
                                     *page_media_overlay.upstream_patches(),
                                     # DEV-1193: pages' refused chrome:// links.
                                     *browser_scheme_link_overlay.patches(),
                                     # DEV-1240: extension windows in Little Arx.
                                     *extension_window_create_patches(),
                                     # DEV-1314: an extension's own tab in Little Arx.
                                     *extension_tab_create_patches()]:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as stream:
                    stream.write(old + "\n")
            # Grit's message ids, stood in by a stable hash: the branding pass renames a message
            # and its translations' ids, and the fake tree has no Chromium checkout.
            extern = root / "tools/grit/grit/extern"
            extern.mkdir(parents=True, exist_ok=True)
            (root / "tools/grit/grit/__init__.py").write_text("")
            (extern / "__init__.py").write_text("")
            (extern / "tclib.py").write_text(
                "import hashlib\n\ndef GenerateMessageId(text, meaning=''):\n"
                "    return str(int(hashlib.sha1((meaning + '|' + text).encode()).hexdigest()[:12], 16))\n"
            )
            # A string file the anchors made is XML in a real tree; the branding pass parses it.
            for path in root.rglob("*"):
                if path.suffix in (".grd", ".grdp", ".xtb") and not path.read_text().lstrip().startswith("<"):
                    path.write_text("<grit-part>\n<message name=\"IDS_ANCHORS\">\n" + path.read_text() + "</message>\n</grit-part>\n")
            apply(root)
            first = {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}
            apply(root)
            second = {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}
            self.assertEqual(first, second)
            media = (root / "chrome/browser/media/chrome_media_session_client.cc").read_text()
            self.assertIn("return browser_context->IsOffTheRecord();", media)
            self.assertNotIn("IsPrimaryOTRProfileWithRegularParent", media)
            manager = (root / "chrome/browser/picture_in_picture/picture_in_picture_window_manager.cc").read_text()
            self.assertIn("initiator_activation_callback_.Run", manager)
            self.assertIn("CloseAndFocusInitiator();", manager)
            self.assertIn("Close(/*should_pause_video=*/false)", manager)
            delegate = (root / "chrome/browser/devtools/chrome_devtools_manager_delegate.cc").read_text()
            # DEV-785: Arx pages are DevTools "page" targets; the key is defined once.
            self.assertEqual(delegate.count("GetUserData(arx::DevToolsPageKey())"), 1)
            self.assertEqual(delegate.count("const void* arx::DevToolsPageKey()"), 1)
            manager_path = root / "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
            manager_path.write_text(manager_path.read_text().replace("  void FocusInitiator();", "  void DifferentUpstreamAPI();"))
            with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                apply_media_activation(root)
            for native in (PACKAGE / "Native").iterdir():
                if native.suffix in {".h", ".mm", ".gn"}:
                    self.assertEqual(native.read_bytes(), (root / "chrome/browser/arx" / native.name).read_bytes())
            branding = (root / "chrome/app/theme/chromium/BRANDING").read_text()
            self.assertIn("MAC_BUNDLE_ID=dev.capturecontext.arx\n", branding)
            self.assertIn("MAC_TEAM_ID=\n", branding)
            self.assertNotIn("S4Q33XPHB4", branding)
            # The exports the app looks up outside the ABI table (overlay.EXTRA_EXPORTS).
            exports = (root / "chrome/app/framework.exports").read_text().splitlines()
            self.assertEqual(exports, ["_ChromeMain", "_ArxEngineGetAPI", *EXTRA_EXPORTS])
            # DEV-1144: the page media agent is created once, after the inspection Inspector.
            renderer = (root / "chrome/renderer/chrome_content_renderer_client.cc").read_text()
            self.assertEqual(renderer.count("new arx::page_media::PageMediaAgent(render_frame);"), 1)
            self.assertEqual(renderer.count("new arx::inspection::Inspector(render_frame);"), 1)
            badges = (root / "chrome/browser/badging/badge_manager.cc").read_text()
            self.assertEqual(badges.count("arx::PageBadgeChanged"), 1)
            self.assertIn('"Arx Storage Key"', (root / "components/os_crypt/common/keychain_password_mac.mm").read_text())


if __name__ == "__main__":
    unittest.main()
