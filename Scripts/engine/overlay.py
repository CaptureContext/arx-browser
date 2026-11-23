"""Apply small, fail-closed edits after Helium's own patches and substitutions."""

import os
import re
import shutil
import traceback
from pathlib import Path

from .config import LOCK, PACKAGE, SOURCE


EXTRA_EXPORTS = [
    "_ArxEngineSetPageAudioVolume",
    "_ArxEngineReleaseProfile",
    "_ArxEngineProfileIsLoaded",
    "_ArxEngineUnloadPage",
    "_ArxEnginePageIsUnloaded",
    "_ArxEngineRestoreUnloadedPage",
    "_ArxEngineCopyProcesses",
    "_ArxEngineEndProcess",
    "_ArxEngineDownloadControl",
    "_ArxEngineSetDownloadPaused",
    "_ArxEngineRemoveDownload",
    "_ArxEngineLostOnQuitDownloadCount",
    "_ArxEngineEndPictureInPicture",
    "_ArxEngineCaptureWholePage",
    "_ArxEngineCancelWholePageCapture",
    "_ArxEngineSetNetworkCapture",
    "_ArxEngineCheckPageFormEdits",
    "_ArxEngineReadNetworkCapture",
    "_ArxEngineSetContentBlocking",
    "_ArxEngineSetExtensionPopupPresenter",
    "_ArxEngineFollowsAllShortcutKeys",
    "_ArxEngineAppendLinkExtensionItems",
    "_ArxEngineCopyNavigationState",
    "_ArxEngineCreateRestoredPage",
    "_ArxEngineLoadRestoredPage",
    "_ArxEngineSetPageBadgeHandler",
    "_ArxEngineSetProtectedMediaHandler",
    "_ArxEngineSetProtectedMediaReasonHandler",
    "_ArxEngineSetPageMediaBridge",
    "_ArxEngineSendPageMedia",
    "_ArxEngineSetPageMediaKeepsRunning",
    "_ArxEngineCopySiteCookies",
    "_ArxEngineSetBatterySaverMode",
    "_ArxEngineBatterySaverIsActive",
    "_ArxEngineObserveBatterySaver",
    "_ArxEngineSetDeviceChooserHandler",
    "_ArxEngineCopyDeviceChooser",
    "_ArxEngineAnswerDeviceChooser",
    "_ArxEngineRescanDeviceChooser",
    "_ArxEngineCopyDeviceGrants",
    "_ArxEngineRevokeDeviceGrant",
    "_ArxEngineSetCastPickerHandler",
    "_ArxEngineShowCastPicker",
    "_ArxEngineSetPageDarkPages",
    "_ArxEngineChooseCastDevice",
    "_ArxEngineStopCasting",
    "_ArxEngineCloseCastPicker",
    "_ArxEngineStartElementPicker",
    "_ArxEngineCopyHiddenElements",
    "_ArxEngineCopyElementPickerStatus",
    "_ArxEngineAddFixtureFilters",
    "_ArxEngineShowHiddenElement",
    "_ArxEngineHideElement",
    "_ArxEngineCopyExtensionActionIcon",
    # DEV-1107.
    "_ArxEnginePageUnloadBlockers",
    "_ArxEngineUnloadAnsweredPage",
]


# While `report` runs, the anchors found missing so far; otherwise None.
_missing = None


def replace_once(path, old, new):
    text = path.read_text()
    if text.count(new) == 1:
        return
    if text.count(old) != 1:
        if _missing is not None:
            caller = traceback.extract_stack(limit=2)[0]
            first = next((line for line in old.splitlines() if line.strip()), old)
            _missing.append((Path(caller.filename).name, caller.lineno, path, text.count(old), first.strip()))
            return
        raise ValueError(f"Engine overlay anchor changed: {path}")
    path.write_text(text.replace(old, new, 1))


def report(source=SOURCE):
    """`make engine-overlay-report`: apply every overlay to a prepared tree and list each missing
    anchor, instead of stopping at the first as `make engine-prepare` does.

    The tree keeps every edit that applied. Fix the listed overlays and run `make engine-prepare`
    again; each edit applies once, so the rest go in. An anchor an overlay finds in another
    overlay's text is listed too when that overlay's edit is the one missing.
    """
    global _missing
    if not (source / "chrome/BUILD.gn").is_file():
        raise ValueError("No prepared engine tree. Run make engine-prepare first.")
    _missing = []
    stopped = None
    try:
        apply(source, team=os.environ.get("DEVELOPMENT_TEAM", ""))
    except ValueError as error:
        stopped = error
    finally:
        missing, _missing = _missing, None
    for overlay, line, path, count, anchor in missing:
        print(f"{overlay}:{line}  {Path(path).relative_to(source)}  "
              f"(anchor found {count} times): {anchor}")
    if stopped:
        print(f"Stopped before the remaining overlays: {stopped}")
    if missing or stopped:
        raise ValueError(f"{len(missing)} overlay anchors are missing"
                         + (", and an overlay stopped" if stopped else ""))
    print("Every overlay applies.")


def apply(source=SOURCE, team=""):
    if team and not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("DEVELOPMENT_TEAM must be a ten-character Apple team ID")

    destination = source / "chrome/browser/arx"
    destination.mkdir(parents=True, exist_ok=True)
    for name in ["engine_bridge.h", "engine_bridge.mm", "popup_host.h", "popup_host.mm", "adoption_scope.h", "close_authority.h", "consent_authority.h", "external_handoff_authority.h", "external_consent_fixture.h", "external_consent_fixture.mm", "page_consent_host.h", "page_consent_host.mm", "unhandled_escape_authority.h", "link_context_policy.h", "downloads_bridge.h", "downloads_bridge.mm",
                 "capture_bridge.h", "capture_bridge.mm", "page_capture_bridge.h", "page_capture_bridge.mm", "media_bridge.h", "media_bridge.mm", "media_freeze_policy.h", "extensions_bridge.h", "extensions_bridge.mm", "extensions_install_bridge.h", "extensions_install_bridge.mm", "extension_install_authority.h", "site_icons_bridge.h", "site_icon_links.h", "site_icons_bridge.mm", "inspection_bridge.h", "inspection_bridge.mm", "pdf_bridge.h", "pdf_bridge.mm", "file_chooser_bridge.h", "file_chooser_bridge.mm", "dialog_bridge.h", "dialog_bridge.mm", "devtools_bridge.h", "devtools_bridge.mm", "developer_bridge.h", "developer_bridge.mm", "network_capture_bridge.h", "network_capture_bridge.mm", "focused_link_bridge.h", "focused_link_bridge.mm", "page_zoom_bridge.h", "page_zoom_bridge.mm", "page_unload_bridge.h", "page_unload_bridge.mm", "page_menu_bridge.h", "page_menu_bridge.mm", "context_menu_bridge.h", "context_menu_bridge.mm", "webstore_install_bridge.h", "webstore_install_bridge.mm", "link_navigation_bridge.h", "link_navigation_bridge.mm", "external_link_bridge.h", "notification_bridge.h", "autofill_bridge.h", "autofill_bridge.mm", "autofill_settings.h", "autofill_settings.mm", "password_bridge.h", "password_bridge.mm", "password_settings.h", "password_settings.mm", "credential_import.h", "credential_import.mm", "credential_import_keys.h", "site_settings_bridge.h", "site_settings_bridge.mm", "content_blocking_bridge.h", "content_blocking_bridge.mm", "extension_menu_items.h", "extension_menu_items.mm", "browsing_data_bridge.h", "browsing_data_bridge.mm", "private_download_prefs.h", "private_download_prefs.mm", "unattended_hooks.h", "devtools_hooks.h", "component_updates.h", "safe_storage_hooks.h", "safe_storage_bridge.h", "safe_storage_bridge.mm", "protected_media_hooks.h", "protected_media_bridge.h", "protected_media_bridge.mm", "page_media_hooks.h", "page_media_bridge.h", "page_media_bridge.mm", "battery_saver_bridge.h", "battery_saver_bridge.mm", "dark_pages_bridge.h", "dark_pages_bridge.mm", "device_chooser_hooks.h", "device_chooser_bridge.h", "device_chooser_bridge.mm", "cast_bridge.h", "cast_bridge.mm", "cast_hooks.h", "BUILD.gn", "hovered_link_bridge.h", "hovered_link_bridge.mm", "browser_scheme_link_hooks.h", "browser_scheme_link_bridge.mm"]:
        shutil.copy2(PACKAGE / "Native" / name, destination / name)
    for name in ["extension_action_host.h", "extension_action_host.mm", "extension_action_policy.h"]:
        shutil.copy2(PACKAGE / "Native" / name, destination / name)
    # DEV-1084.
    for name in ["form_edits_bridge.h", "form_edits_bridge.mm"]:
        shutil.copy2(PACKAGE / "Native" / name, destination / name)
    # DEV-1264, DEV-1073.
    for name in ["page_command_key.h", "page_command_key.mm"]:
        shutil.copy2(PACKAGE / "Native" / name, destination / name)
    # DEV-1240.
    for name in ["extension_window_hooks.h", "extension_window_bridge.mm"]:
        shutil.copy2(PACKAGE / "Native" / name, destination / name)
    shutil.copytree(PACKAGE / "Native/profile_erasure", destination / "profile_erasure", dirs_exist_ok=True)
    shutil.copy2(PACKAGE / "Sources/ChromiumBridge/include/ChromiumBridge.h", destination)

    main = source / "chrome/browser/chrome_browser_main.cc"
    replace_once(main, '#include "chrome/browser/chrome_browser_main.h"',
                 '#include "chrome/browser/chrome_browser_main.h"\n'
                 '#if BUILDFLAG(IS_MAC)\n#include "chrome/browser/arx/engine_bridge.h"\n#endif')
    replace_once(main, "  return main_parts;", "#if BUILDFLAG(IS_MAC)\n"
                 "  arx::AttachEngine(main_parts.get());\n#endif\n  return main_parts;")

    controller = source / "chrome/browser/app_controller_mac.mm"
    replace_once(controller, '#import "chrome/browser/app_controller_mac.h"',
                 '#import "chrome/browser/app_controller_mac.h"\n'
                 '#include "chrome/browser/arx/engine_bridge.h"')
    replace_once(controller, '- (void)setLastProfile:(Profile*)profile {',
                 '- (void)setLastProfile:(Profile*)profile {\n'
                 '  // The embedding app owns its menus; Chromium menu tags are absent.\n'
                 '  if (arx::IsEmbedded()) {\n'
                 '    _lastProfile = profile;\n'
                 '    return;\n'
                 '  }')

    # Arx owns profiles and windows. Chromium's picker and Dock menu would offer a
    # second, separate set of them.
    replace_once(controller, '- (NSMenu*)applicationDockMenu:(NSApplication*)sender {',
                 '- (NSMenu*)applicationDockMenu:(NSApplication*)sender {\n'
                 '  if (arx::IsEmbedded()) return nil;')
    # Arx's quit lets downloads in progress or paused end interrupted, to resume next time, as a
    # headless quit already does; its own quit confirmation says so. Chromium's stock "Wait for
    # download" alert would ask a second time, block unattended quits, and its "Cancel download
    # and exit" left nothing to resume (DEV-966).
    replace_once(controller, '- (BOOL)shouldQuitWithInProgressDownloads {',
                 '- (BOOL)shouldQuitWithInProgressDownloads {\n'
                 '  if (arx::IsEmbedded()) return YES;')
    # A quit keeps those transfers' bytes by pausing and interrupting each one still writing to its
    # intermediate file, before Chromium's shutdown cancels it (downloads_bridge.mm). Every other
    # internal state also reads IN_PROGRESS, and Pause or DestinationError would hit NOTREACHED,
    # trip a DCHECK or do nothing in them (DEV-966).
    download_item = source / "components/download/public/common/download_item_impl.h"
    replace_once(download_item, '  bool AllDataSaved() const override;',
                 '  bool AllDataSaved() const override;\n'
                 '  // Arx (DEV-966): writing to its intermediate file, paused or not.\n'
                 '  bool IsWritingToIntermediateFile() const { return state_ == IN_PROGRESS_INTERNAL; }')
    picker = source / "chrome/browser/ui/views/profiles/profile_picker_view.cc"
    replace_once(picker, 'void ProfilePicker::Show(Params&& params) {',
                 'namespace arx { bool IsEmbedded(); }\n\n'
                 'void ProfilePicker::Show(Params&& params) {\n'
                 '  if (arx::IsEmbedded()) return;')

    build = source / "chrome/browser/BUILD.gn"
    text = build.read_text()
    marker = 'source_set("core") {'
    if text.count(marker) != 1:
        raise ValueError("Chromium's browser core target changed")
    start = text.index(marker)
    end = text.index("\n}\n", start)
    addition = '\n  if (is_mac) {\n    deps += [ "//chrome/browser/arx" ]\n  }\n'
    if addition not in text[start:end]:
        build.write_text(text[:end] + addition + text[end:])

    exports = source / "chrome/app/framework.exports"
    # The exports outside the ABI table, which the app looks up: per-tab volume (DEV-800),
    # idle profile release (DEV-880), tab unloading (DEV-873), the Task Manager's process table
    # (DEV-898), download pause, resume and removal (DEV-892), request details (DEV-924),
    # content blocking (DEV-884), extension link menu items (DEV-890), a tab's back/forward
    # history (DEV-878), Badging API reports (DEV-907), the WebKit pages' protected media handler
    # and site cookies (DEV-877), Battery Saver (DEV-915) and device choosers (DEV-905). The Mach-O export list wins over
    # default visibility, so each must be listed.
    for symbol in ["_ArxEngineGetAPI", *EXTRA_EXPORTS]:
        if symbol not in exports.read_text().splitlines():
            exports.write_text(exports.read_text().rstrip() + f"\n{symbol}\n")

    branding = source / "chrome/app/theme/chromium/BRANDING"
    fields = dict(line.split("=", 1) for line in branding.read_text().splitlines() if "=" in line)
    fields.update(COMPANY_FULLNAME="CaptureContext", COMPANY_SHORTNAME="CaptureContext",
                  PRODUCT_FULLNAME="Arx", PRODUCT_SHORTNAME="Arx",
                  PRODUCT_INSTALLER_FULLNAME="Arx Installer", PRODUCT_INSTALLER_SHORTNAME="Arx Installer",
                  MAC_BUNDLE_ID=LOCK["bundle_id"], MAC_TEAM_ID=team)
    branded = "".join(f"{key}={value}\n" for key, value in fields.items())
    if branding.read_text() != branded:
        branding.write_text(branded)
    keychain = source / "components/os_crypt/common/keychain_password_mac.mm"
    replace_once(keychain, 'kDefaultServiceName[] = "Helium Storage Key"',
                 'kDefaultServiceName[] = "Arx Storage Key"')
    replace_once(keychain, 'kDefaultAccountName[] = "Helium"',
                 'kDefaultAccountName[] = "Arx"')
    paths = source / "chrome/common/chrome_paths_mac.mm"
    replace_once(paths, 'product_dir_name = "net.imput.helium";',
                 'product_dir_name = "dev.capturecontext.arx";')

    media = source / "chrome/browser/media/chrome_media_session_client.cc"
    replace_once(media,
                 "  return Profile::FromBrowserContext(browser_context)\n"
                 "      ->IsPrimaryOTRProfileWithRegularParent();",
                 "  // Arx creates unique off-the-record profiles, not primary incognito profiles.\n"
                 "  return browser_context->IsOffTheRecord();")
    from .content_host_overlay import apply as apply_content_host
    apply_content_host(source)
    apply_media_activation(source)
    apply_devtools_page_targets(source)
    from .media_freeze_overlay import apply as apply_media_freeze
    apply_media_freeze(source)
    from .live_connection_overlay import apply as apply_live_connections
    apply_live_connections(source)
    from .gesture_overlay import apply as apply_gestures
    apply_gestures(source)
    from .force_click_overlay import apply as apply_force_click
    apply_force_click(source)
    from .pip_overlay import apply as apply_pip
    apply_pip(source)
    from .close_overlay import apply as apply_authorized_close
    apply_authorized_close(source)
    from .inspection_overlay import apply as apply_inspection
    apply_inspection(source)
    from .link_context_overlay import apply as apply_link_context
    apply_link_context(source)
    from .erasure_overlay import apply as apply_erasure
    apply_erasure(source)
    from .document_capture_overlay import apply as apply_document_capture
    apply_document_capture(source)
    from .extension_install_overlay import apply as apply_extension_install
    apply_extension_install(source)
    from .extension_inventory_overlay import apply as apply_extension_inventory
    apply_extension_inventory(source)
    from .background_pages_overlay import apply as apply_background_pages
    apply_background_pages(source)
    from .page_consent_overlay import apply as apply_page_consent
    apply_page_consent(source)
    from .extension_navigation_overlay import apply as apply_extension_navigation
    apply_extension_navigation(source)
    from .extension_tabs_overlay import apply as apply_extension_tabs
    apply_extension_tabs(source)
    from .http_auth_overlay import apply as apply_http_auth
    apply_http_auth(source)
    from .extension_windows_overlay import apply as apply_extension_windows
    apply_extension_windows(source)
    from .unattended_prompts_overlay import apply as apply_unattended_prompts
    apply_unattended_prompts(source)
    from .bangs_overlay import apply as apply_bangs
    apply_bangs(source)
    from .services_overlay import apply as apply_services
    apply_services(source)
    from .developer_world_overlay import apply as apply_developer_world
    apply_developer_world(source)
    from .password_manager_overlay import apply as apply_password_manager
    apply_password_manager(source)
    from .autofill_suggestions_overlay import apply as apply_autofill_suggestions
    apply_autofill_suggestions(source)
    from .link_navigation_overlay import apply as apply_link_navigation
    apply_link_navigation(source)
    from .external_link_overlay import apply as apply_external_link
    apply_external_link(source)
    from .webstore_install_overlay import apply as apply_webstore_install
    apply_webstore_install(source)
    from .audio_volume_overlay import apply as apply_audio_volume
    apply_audio_volume(source)
    from .startup_metrics_overlay import apply as apply_startup_metrics
    apply_startup_metrics(source)
    from .session_cookies_overlay import apply as apply_session_cookies
    apply_session_cookies(source)
    from .component_updates_overlay import apply as apply_component_updates
    apply_component_updates(source)
    from .safe_storage_overlay import apply as apply_safe_storage
    apply_safe_storage(source)
    from .native_messaging_overlay import apply as apply_native_messaging
    apply_native_messaging(source)
    from .extension_uninstall_overlay import apply as apply_extension_uninstall
    apply_extension_uninstall(source)
    from .content_blocking_overlay import apply as apply_content_blocking
    apply_content_blocking(source)
    from .private_extension_routing_overlay import apply as apply_private_extension_routing
    apply_private_extension_routing(source)
    from .badge_overlay import apply as apply_badges
    apply_badges(source)
    from .notification_overlay import apply as apply_notifications
    apply_notifications(source)
    from .protected_media_overlay import apply as apply_protected_media
    apply_protected_media(source)
    from .widevine_answer_overlay import apply as apply_widevine_answer
    apply_widevine_answer(source)
    from .page_media_overlay import apply as apply_page_media
    apply_page_media(source)
    from .browser_scheme_link_overlay import apply as apply_browser_scheme_links
    apply_browser_scheme_links(source)
    from .device_chooser_overlay import apply as apply_device_chooser
    apply_device_chooser(source)
    from .cast_overlay import apply as apply_cast
    apply_cast(source)
    from .bfcache_media_session_overlay import apply as apply_bfcache_media_session
    apply_bfcache_media_session(source)
    from .dark_pages_overlay import apply as apply_dark_pages
    apply_dark_pages(source)
    from .file_stream_guard_overlay import apply as apply_file_stream_guard
    apply_file_stream_guard(source)
    # DEV-1240: extension windows in Little Arx; after extension_windows_overlay, whose helper it calls.
    from .extension_window_create_overlay import apply as apply_extension_window_create
    apply_extension_window_create(source)
    # DEV-1314: an extension's own tab in Little Arx; after extension_tabs_overlay, uses the same bridge.
    from .extension_tab_create_overlay import apply as apply_extension_tab_create
    apply_extension_tab_create(source)
    # DEV-1100: Arx's logo and name where Helium's were; preparation stops if Helium's come back.
    # Last: the overlays above find their anchors by Helium's own text (the Keychain message's
    # "Helium couldn't access…" included), which the rename would change.
    from .branding_overlay import apply as apply_branding, check as check_branding
    apply_branding(source)
    check_branding(source)


def apply_devtools_page_targets(source):
    """DEV-785: report Arx pages as "page" targets, as Chrome reports its tabs.

    Arx pages have no TabInterface, so they were "other" targets and the DevTools
    frontend, which takes only a "page" child of its tab target as the inspected
    page, never attached to them: every panel stayed empty.
    """
    delegate = source / "chrome/browser/devtools/chrome_devtools_manager_delegate.cc"
    replace_once(delegate, '#include "chrome/browser/devtools/chrome_devtools_manager_delegate.h"\n',
                 '#include "chrome/browser/devtools/chrome_devtools_manager_delegate.h"\n\n'
                 '#include "chrome/browser/arx/devtools_hooks.h"  // nogncheck\n')
    replace_once(delegate, "  return DevToolsAgentHost::kTypeOther;\n}\n", """  // Arx pages are tabs without Chrome's TabInterface (DEV-785).
  if (web_contents->GetUserData(arx::DevToolsPageKey())) {
    return DevToolsAgentHost::kTypePage;
  }

  return DevToolsAgentHost::kTypeOther;
}

const void* arx::DevToolsPageKey() {
  static const int key = 0;
  return &key;
}
""")


def apply_media_activation(source):
    """Expose only native PiP initiator controls, never generic window.focus()."""
    header = source / "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
    replace_once(header, '#include "base/memory/raw_ptr.h"',
                 '#include "base/functional/callback.h"\n#include "base/memory/raw_ptr.h"')
    replace_once(header, "  // Called to notify that the initiator web contents should be focused.\n  void FocusInitiator();", """  // An embedder may handle native PiP source activation. Return false for
  // unowned sources to preserve the default. The callback must not close the
  // controller synchronously; post application ownership changes instead.
  void SetInitiatorActivationCallback(
      base::RepeatingCallback<bool(content::WebContents*)> callback) {
    initiator_activation_callback_ = std::move(callback);
  }

  // Called to notify that the initiator web contents should be focused.
  void FocusInitiator();""")
    replace_once(header, " private:\n", " private:\n  base::RepeatingCallback<bool(content::WebContents*)> initiator_activation_callback_;\n")
    implementation = source / "chrome/browser/picture_in_picture/picture_in_picture_window_manager.cc"
    replace_once(implementation, """    case UiBehavior::kCloseWindowAndFocusOpener:
      pip_window_controller_->CloseAndFocusInitiator();
      break;""", """    case UiBehavior::kCloseWindowAndFocusOpener:
      if (initiator_activation_callback_ &&
          initiator_activation_callback_.Run(pip_window_controller_->GetWebContents())) {
        pip_window_controller_->Close(/*should_pause_video=*/false);
      } else {
        pip_window_controller_->CloseAndFocusInitiator();
      }
      break;""")
    replace_once(implementation, """void PictureInPictureWindowManager::FocusInitiator() {
  if (pip_window_controller_)
    pip_window_controller_->FocusInitiator();
}""", """void PictureInPictureWindowManager::FocusInitiator() {
  if (pip_window_controller_ &&
      (!initiator_activation_callback_ ||
       !initiator_activation_callback_.Run(pip_window_controller_->GetWebContents())))
    pip_window_controller_->FocusInitiator();
}""")
