#import <AppKit/AppKit.h>

#include "chrome/browser/arx/ChromiumBridge.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "chrome/browser/arx/devtools_hooks.h"
#include "chrome/browser/arx/dark_pages_bridge.h"
#include "chrome/browser/arx/safe_storage_bridge.h"
#include "chrome/browser/arx/popup_host.h"
#include "chrome/browser/arx/page_media_bridge.h"
#include "chrome/browser/arx/extension_action_host.h"
#include "chrome/browser/arx/adoption_scope.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/tab_contents/tab_util.h"
#include "chrome/browser/ui/blocked_content/chrome_popup_navigation_delegate.h"
#include "chrome/browser/ui/navigator/browser_navigator_params_utils.h"
#include "components/blocked_content/popup_blocker.h"
#include "components/blocked_content/popup_blocker_tab_helper.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "chrome/browser/arx/close_authority.h"
#include "chrome/browser/arx/unhandled_escape_authority.h"
#include "chrome/browser/arx/page_command_key.h"
#include "components/input/native_web_keyboard_event.h"
#include "base/time/time.h"
#include "chrome/browser/arx/link_context_policy.h"
#include "chrome/browser/arx/link_navigation_bridge.h"
#include "chrome/browser/arx/downloads_bridge.h"
#include "chrome/browser/arx/private_download_prefs.h"
#include "chrome/browser/arx/capture_bridge.h"
#include "chrome/browser/arx/dialog_bridge.h"
#include "chrome/browser/arx/file_chooser_bridge.h"
#include "content/public/browser/file_select_listener.h"
#include "third_party/blink/public/mojom/choosers/file_chooser.mojom.h"
#include "chrome/browser/arx/pdf_bridge.h"
#include "chrome/browser/arx/developer_bridge.h"
#include "chrome/browser/arx/network_capture_bridge.h"
#include "chrome/browser/arx/focused_link_bridge.h"
#include "chrome/browser/arx/hovered_link_bridge.h"
#include "chrome/browser/arx/page_zoom_bridge.h"
#include "chrome/browser/arx/page_unload_bridge.h"
#include "chrome/browser/arx/page_menu_bridge.h"
#include "chrome/browser/arx/extension_menu_items.h"
#include "chrome/browser/arx/context_menu_bridge.h"
#include "chrome/browser/arx/autofill_bridge.h"
#include "chrome/browser/arx/autofill_settings.h"
#include "chrome/browser/arx/password_bridge.h"
#include "chrome/browser/arx/password_settings.h"
#include "chrome/browser/arx/credential_import.h"
#include "chrome/browser/arx/site_settings_bridge.h"
#include "chrome/browser/arx/browsing_data_bridge.h"
#include "components/paint_preview/arx/document_capture_fixture.h"
#include "chrome/browser/arx/media_bridge.h"
#include "chrome/browser/arx/page_consent_host.h"
#include "chrome/browser/arx/external_consent_fixture.h"
#include "chrome/browser/arx/extensions_bridge.h"
#include "chrome/browser/arx/webstore_install_bridge.h"
#include "chrome/browser/arx/external_link_bridge.h"
#include "chrome/browser/arx/notification_bridge.h"
#include "content/public/browser/page_navigator.h"
#include "url/origin.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/process_map.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/common/result_codes.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/child_process_termination_info.h"
#include "content/public/browser/render_process_host_observer.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "extensions/common/extension.h"
#include "chrome/browser/arx/extensions_install_bridge.h"
#include "chrome/browser/arx/site_icons_bridge.h"
#include "chrome/browser/arx/inspection_bridge.h"
#include "chrome/browser/arx/devtools_bridge.h"
#include "chrome/browser/arx/profile_erasure/bridge.h"
#include "chrome/browser/arx/gestures/controller.h"
#include "chrome/browser/arx/gestures/fixture.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
#include "chrome/browser/extensions/chrome_process_manager_delegate.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/ui/login/http_auth_coordinator.h"
#include "chrome/browser/arx/unattended_hooks.h"
#include "chrome/browser/arx/cast_bridge.h"
#include "chrome/browser/shutdown_watchdog_mac.h"
#include "components/sessions/core/session_id.h"
#include "base/pickle.h"
#include "components/sessions/content/content_serialized_navigation_builder.h"
#include "components/sessions/core/serialized_navigation_entry.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/restore_type.h"
#include "extensions/common/constants.h"

#include <os/log.h>
#include <os/signpost.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <string_view>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include "base/check.h"
#include "base/files/scoped_temp_dir.h"
#include "base/uuid.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "components/javascript_dialogs/app_modal_dialog_manager.h"
#include "content/public/browser/javascript_dialog_manager.h"
#include "components/performance_manager/embedder/performance_manager_registry.h"
#include "components/performance_manager/public/graph/page_node.h"
#include "components/performance_manager/public/performance_manager.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/utf_string_conversions.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/current_thread.h"
#include "base/task/single_thread_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/timer/timer.h"
#include "partition_alloc/memory_reclaimer.h"
#include "chrome/browser/chrome_browser_main.h"
#include "chrome/browser/chrome_browser_main_extra_parts.h"
#include "chrome/browser/lifetime/application_lifetime.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_destroyer.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/media_session.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "services/network/public/mojom/clear_data_filter.mojom.h"
#include "services/network/public/mojom/referrer_policy.mojom-shared.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "base/scoped_observation.h"
#include "base/memory/raw_ptr.h"
#include "components/keep_alive_registry/keep_alive_types.h"
#include "components/keep_alive_registry/scoped_keep_alive.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/back_forward_cache.h"
#include "content/public/browser/document_user_data.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/common/stop_find_action.h"
#include "third_party/blink/public/mojom/frame/find_in_page.mojom.h"
#include "third_party/blink/public/mojom/window_features/window_features.mojom.h"
#include "third_party/skia/include/core/SkColor.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/arx_before_unload.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/keyboard_event_processing_result.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/web_contents_observer.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/mac/coordinate_conversion.h"
#include "url/gurl.h"

extern "C" int ChromeMain(int argc, const char** argv);

namespace arx {
namespace {

class Page;
void DestroyPage(uint64_t id);
void ReportConsumedCommandKey(uint64_t id, PageCommandKey::Key key);
bool ExtensionActionsProfileIsCurrent(Profile* profile);
Profile* ExtensionProfile(const char* key);
Profile* PrivateOpener(Profile* profile);

// ABI22: one page's place in an Arx window, as the app last reported it.
struct ExtensionPlacement {
  int64_t window_number = 0;
  int32_t index = -1;
  bool active = false;
  bool highlighted = false;
};

struct RetiredPrivateProfile {
  uint64_t generation;
  bool cleanup_posted = false;
};

// DEV-943: documents each page keeps in the back/forward cache, back and
// forward together. Chrome keeps 6 per tab; Arx keeps many more tabs open, most
// of them hidden, so it keeps fewer by default. Three cover Back, Back again and
// Forward, where nearly every cache hit happens. Settings › Advanced chooses 0
// (off) to the maximum, read once at launch (BackForwardCacheEntries). Time to
// live stays Chrome's (10 minutes; 3 for Cache-Control: no-store pages): an
// embedder value would replace both. Memory pressure still trims the cache below
// this (content's BFCache policy).
constexpr size_t kDefaultBackForwardCacheEntries = 3;

struct EngineState {
  ArxEngineCallbacks callbacks = {};
  std::string history_url, history_title;
  // DEV-878. The last navigation state handed out, borrowed until the next.
  std::vector<uint8_t> navigation_state;
  bool started = false;
  bool running = false;
  bool document_fixture_enabled = false, document_fixture_started = false;
  std::unique_ptr<document::testing::OwnedCaptureFixture> document_fixture;
  bool gesture_fixture = false;
  bool unattended = false;
  // ABI60 (DEV-1118): the app shows the link status, so pages report hovered
  // links and ask their frames where they navigate. Off by default.
  bool link_hover_reports = false;
  // DEV-943: set at launch; 0 turns the back/forward cache off.
  size_t back_forward_cache_entries = kDefaultBackForwardCacheEntries;
  uint64_t unattended_dialogs = 0;
  // ABI22 unattended shutdown deadline and its expiry report.
  uint32_t shutdown_deadline = 0;
  void (*shutdown_expired)(void*, int) = nullptr;
  void* shutdown_context = nullptr;
  // ABI22 extension windows: placements by page, windows in the app's order,
  // and each live window's stable extension ID.
  std::map<uint64_t, ExtensionPlacement> extension_placements;
  std::vector<int64_t> extension_window_order;
  std::map<int64_t, SessionID> extension_window_ids;
  // DEV-956: the extension ID of each live private window the app doesn't place.
  std::map<int64_t, SessionID> private_window_ids;
  uint64_t next_page = 1;
  uint64_t next_close_token = 1;
  uint64_t next_link_context_token = 1;
  std::unique_ptr<ScopedKeepAlive> keep_alive;
  std::map<uint64_t, std::unique_ptr<Page>> pages;
  AdoptionScope adoption_scope;
  std::map<std::string, std::unique_ptr<ScopedProfileKeepAlive>> profiles;
  std::map<std::string, Profile*> private_profiles;
  // A logical identity never changes storage kind during this runtime. Reserve
  // ordinary keys before asynchronous preparation so private preparation cannot
  // race the disk-backed profile's completion.
  std::set<std::string> ordinary_profile_keys, private_profile_keys;
  std::map<std::string, size_t> preparing_profiles;
  std::map<Profile*, RetiredPrivateProfile> retired_private_profiles;
  uint64_t next_private_retirement = 1;
};

EngineState& State() {
  static base::NoDestructor<EngineState> state;
  return *state;
}

void CheckThread() { CHECK([NSThread isMainThread]); }

bool AllowedURL(const GURL& url) {
  return url.is_valid() && (url.SchemeIsHTTPOrHTTPS() || url.spec() == "about:blank");
}

// ---- ABI55 (DEV-885) web notification clicks; see notification_bridge.h ----
struct NotificationClick {
  uint64_t id = 0;
  std::string profile_key;
  url::Origin origin;
  bool persistent = false;
  bool handled = false;
  bool page_gone = false;
  base::TimeTicks started;
};

// A site may answer its click this long after it started, and the app hears
// of a click this long after its handler settled, so an openWindow() the
// handler didn't wait for still counts as the site's answer.
constexpr base::TimeDelta kNotificationClickWindow = base::Seconds(10);
constexpr base::TimeDelta kNotificationClickSettle = base::Milliseconds(500);
constexpr size_t kNotificationClicksLimit = 32;

std::vector<NotificationClick>& NotificationClicks() {
  static base::NoDestructor<std::vector<NotificationClick>> clicks;
  return *clicks;
}

// The app's key for an ordinary profile Arx prepared, "" for the legacy
// Default profile; nothing for private and unknown profiles.
std::optional<std::string> OrdinaryProfileKey(Profile* profile) {
  auto& state = State();
  if (!state.running || !profile || profile->IsOffTheRecord()) return std::nullopt;
  for (const auto& [key, owner] : state.profiles)
    if (owner->profile() == profile) return key;
  auto* manager = g_browser_process->profile_manager();
  if (!manager) return std::nullopt;
  if (profile->GetPath() == manager->user_data_dir().AppendASCII("Default"))
    return std::string();
  // Chromium loads a profile to dispatch its notification's click even when
  // Arx hasn't prepared it this session or released it while idle (DEV-880):
  // its folder still names its key.
  const std::string folder = profile->GetPath().BaseName().MaybeAsASCII();
  if (profile->GetPath().DirName() != manager->user_data_dir() || !folder.starts_with("Arx-"))
    return std::nullopt;
  const std::string key = folder.substr(4);
  if (!base::Uuid::ParseLowercase(key).is_valid() || state.private_profile_keys.contains(key))
    return std::nullopt;
  return key;
}

// The click on a notification from this profile and origin that may still be
// answered, if any.
NotificationClick* ActiveNotificationClick(const std::string& key, const url::Origin& origin) {
  const auto now = base::TimeTicks::Now();
  for (auto& click : NotificationClicks())
    if (click.profile_key == key && click.origin.IsSameOriginWith(origin) &&
        now - click.started <= kNotificationClickWindow) return &click;
  return nullptr;
}

// True, and the click counts as answered, when `contents` shows the site of a
// notification click in flight: its committed page, or the page openWindow()
// is still loading.
bool ClaimNotificationActivation(content::WebContents* contents) {
  if (!contents || NotificationClicks().empty()) return false;
  const auto key = OrdinaryProfileKey(Profile::FromBrowserContext(contents->GetBrowserContext()));
  if (!key) return false;
  for (const GURL& url : {contents->GetLastCommittedURL(), contents->GetVisibleURL()}) {
    if (!url.SchemeIsHTTPOrHTTPS()) continue;
    if (auto* click = ActiveNotificationClick(*key, url::Origin::Create(url))) {
      click->handled = true;
      return true;
    }
  }
  return false;
}

void ReportNotificationClick(uint64_t id) {
  auto& clicks = NotificationClicks();
  auto found = std::find_if(clicks.begin(), clicks.end(),
                            [id](const NotificationClick& click) { return click.id == id; });
  if (found == clicks.end()) return;
  const NotificationClick click = std::move(*found);
  clicks.erase(found);
  auto& state = State();
  if (!state.running || !state.callbacks.notification_clicked) return;
  uint32_t flags = 0;
  if (click.persistent) flags |= ARX_NOTIFICATION_PERSISTENT;
  if (click.handled) flags |= ARX_NOTIFICATION_HANDLED;
  if (click.page_gone) flags |= ARX_NOTIFICATION_PAGE_GONE;
  const std::string origin = click.origin.Serialize();
  state.callbacks.notification_clicked(state.callbacks.context, click.profile_key.c_str(),
                                       origin.data(), origin.size(), flags);
}
// ---- ABI55 (DEV-885) end ----

// Unattended runs have no user to answer page dialogs. Message text is never kept.
class UnattendedDialogManager final : public content::JavaScriptDialogManager {
 public:
  void RunJavaScriptDialog(content::WebContents*, content::RenderFrameHost*,
                           content::JavaScriptDialogType, const std::u16string&,
                           const std::u16string&, DialogClosedCallback,
                           bool* did_suppress_message) override {
    ++State().unattended_dialogs;
    *did_suppress_message = true;
  }
  void RunBeforeUnloadDialog(content::WebContents*, content::RenderFrameHost*, bool,
                             DialogClosedCallback callback) override {
    ++State().unattended_dialogs;
    std::move(callback).Run(false, std::u16string());
  }
  void CancelDialogs(content::WebContents*, bool) override {}
};

// DEV-1016: renderer processes the engine ended, by id (Chromium never reuses one), so
// every page they drew, the one that asked or another sharing the process, reports the end
// as the engine's.
// A marker lasts until the host launches a new child (a page drawn by it sees
// RenderProcessReady) and at most 30 s, so a later crash of a reused host is its own.
std::map<int, base::TimeTicks>& EndedRenderers() {
  static base::NoDestructor<std::map<int, base::TimeTicks>> ended;
  return *ended;
}

bool EndedByEngine(int process) {
  auto& ended = EndedRenderers();
  const auto now = base::TimeTicks::Now();
  std::erase_if(ended, [&](const auto& item) { return now - item.second > base::Seconds(30); });
  return ended.contains(process);
}

UnattendedDialogManager& UnattendedDialogs() {
  static base::NoDestructor<UnattendedDialogManager> manager;
  return *manager;
}

// ABI21/ABI22 prompt counters belong to the document they were counted in. A
// document restored from the back/forward cache brings its own back; a new
// document starts at zero.
class DocumentPrompts final : public content::DocumentUserData<DocumentPrompts> {
 public:
  ~DocumentPrompts() override = default;
  uint64_t authentication_cancellations = 0;
  uint32_t user_action_requests = 0;

 private:
  explicit DocumentPrompts(content::RenderFrameHost* frame) : DocumentUserData(frame) {}
  friend content::DocumentUserData<DocumentPrompts>;
  DOCUMENT_USER_DATA_KEY_DECL();
};

DOCUMENT_USER_DATA_KEY_IMPL(DocumentPrompts);

// DEV-939: the launch's first painted page, as a signpost beside AppFeature's
// LaunchSignposts (subsystem dev.capturecontext.arx, category Launch), for
// `make benchmark` and Instruments. Only the process's first paint is marked.
void MarkFirstPagePainted() {
  static bool marked = false;
  if (marked) return;
  marked = true;
  static os_log_t launch_log = os_log_create("dev.capturecontext.arx", "Launch");
  os_signpost_event_emit(launch_log, OS_SIGNPOST_ID_EXCLUSIVE, "FirstPagePainted");
}

class Page final : public content::WebContentsDelegate,
                   public content::WebContentsObserver,
                   public content::RenderProcessHostObserver {
 public:
  Page(uint64_t id, Profile* profile) : Page(id, CreateHiddenContents(profile)) {}

  Page(uint64_t id, std::unique_ptr<content::WebContents> contents)
      : id_(id), contents_(std::move(contents)) {
    StartHidden();
    ObserveRenderer(contents_->GetPrimaryMainFrame());
    if (auto* registry = performance_manager::PerformanceManagerRegistry::GetInstance()) {
      registry->MaybeCreatePageNodeForWebContents(contents_.get());
      // Arx owns real browser tabs without Chrome's TabInterface. Leaving their
      // PageNodes unknown bypasses tab MRU protection and freezes them on hide.
      registry->SetPageType(contents_.get(), performance_manager::PageType::kTab);
    }
    // DevTools takes only a "page" target as the page it inspects (DEV-785).
    contents_->SetUserData(DevToolsPageKey(), std::make_unique<base::SupportsUserData::Data>());
    AttachExtensionHelpers(contents_.get());
    // DEV-1020: the page starts with the default dark pages setting, before its
    // first navigation, until the app sets its own.
    AttachDarkPages(contents_.get());
    // ABI35: ordinary pages only; private pages never get password clients.
    AttachPasswordClients(contents_.get(), id);
    // DEV-1144: the page media bridge's script for bridged origins.
    AttachPageMedia(contents_.get());
    ConfigurePageConsentHosting(contents_.get(), false);
    site_icons_ = ObserveSiteIcons(id, contents_.get(),
        [](uint64_t page, const char* url, const char* icon_url) {
          auto& state = State();
          if (state.running && state.callbacks.site_icon_changed)
            state.callbacks.site_icon_changed(state.callbacks.context, page, url, icon_url);
        },
        // ABI51 (DEV-940).
        [](uint64_t page, const char* const* urls, size_t count, bool truncated) {
          auto& state = State();
          if (state.running && state.callbacks.site_icon_redirects)
            state.callbacks.site_icon_redirects(state.callbacks.context, page, urls, count,
                                                truncated);
        });
    contents_->SetDelegate(this);
    if (const size_t entries = State().back_forward_cache_entries)
      contents_->GetController().GetBackForwardCache().SetEmbedderSuppliedCacheSize(entries);
    Observe(contents_.get());
    gestures::Controller::CreateForWebContents(
        contents_.get(), id, 24.0, State().gesture_fixture);
  }

  ~Page() override {
    destroying_ = true;
    // The inspector never outlives or rebinds to another page's contents.
    CloseDevTools(contents_.get());
    DismissLinkContext(link_context_.token());
    extension_action_host_.reset();
    popup_host_.reset();
    ForgetInspectionPage(id_);
    ForgetDeveloperPage(id_);
    ForgetNetworkCapture(id_);
    ForgetPasswordPage(id_);
    ForgetFileChooser(id_);
    TearDownPageConsentHosting(contents_.get());
    media_.reset();
    site_icons_.reset();
    Observe(nullptr);
    contents_->SetDelegate(nullptr);
  }

  content::WebContents* contents() { return contents_.get(); }
  void PublishNavigation() { Notify(); }
  // ABI21: an unattended run cancelled a subframe/subresource HTTP challenge.
  void AuthenticationCancelled() {
    auto& prompts = CurrentPrompts();
    if (prompts.authentication_cancellations != UINT64_MAX) ++prompts.authentication_cancellations;
    Notify();
  }
  uint64_t authentication_cancellations() const {
    auto* prompts = DocumentPrompts::GetForCurrentDocument(contents_->GetPrimaryMainFrame());
    return prompts ? prompts->authentication_cancellations : 0;
  }
  // ABI22: an unattended run refused a sign-in prompt in the current document.
  void UserActionRequired(uint32_t request) {
    auto& prompts = CurrentPrompts();
    if ((prompts.user_action_requests & request) == request) return;
    prompts.user_action_requests |= request;
    Notify();
  }
  uint32_t user_action_requests() const {
    auto* prompts = DocumentPrompts::GetForCurrentDocument(contents_->GetPrimaryMainFrame());
    return prompts ? prompts->user_action_requests : 0;
  }

  // ABI23 find in page.
  void FindInPage(const std::string& text, bool forward, bool new_session) {
    if (new_session) {
      find_matches_ = -1;
      find_active_ = -1;
    }
    auto options = blink::mojom::FindOptions::New();
    options->forward = forward;
    options->new_session = new_session;
    contents_->Find(base::UTF8ToUTF16(text), std::move(options), /*skip_delay=*/false,
                    [](int) {});
  }
  void StopFinding() {
    contents_->StopFinding(content::STOP_FIND_ACTION_KEEP_SELECTION);
    find_matches_ = -1;
    find_active_ = -1;
    Notify();
  }
  // Chromium 157 reports find results to observers only; this page observes its own contents.
  void DidReceiveFindReply(int request_id, int number_of_matches,
                           const gfx::Rect& selection_rect, int active_match_ordinal,
                           bool final_update) override {
    if (number_of_matches != -1) find_matches_ = number_of_matches;
    if (active_match_ordinal != -1) find_active_ = active_match_ordinal;
    Notify();
  }
  int32_t find_matches() const { return find_matches_; }
  int32_t find_active() const { return find_active_; }
  // ABI22: this page's open extension popup, or null.
  content::WebContents* extension_popup() const {
    return extension_action_host_ ? extension_action_host_->PopupContents() : nullptr;
  }
  // DEV-1316: a popup of the page's has the keyboard, so the page is its
  // window's active tab for extensions. A popup left open while the person
  // works in another pane doesn't make it so (Codex review).
  bool HasFocusedExtensionPopup() const {
    return extension_action_host_ && extension_action_host_->HasFocusedPopup();
  }
  // DEV-1316: any of the page's open popups, as more than one can be open.
  bool HostsExtensionPopup(const content::WebContents* contents) const {
    return extension_action_host_ && extension_action_host_->HostsPopup(contents);
  }
  const std::string& document_id() const { return document_id_; }
  uint64_t MainDocuments() const { return main_documents_; }
  uint64_t identifier() const { return id_; }
  // ABI48 (DEV-828). Only a page hosting content has an action host.
  ArxExtensionActionRunStatus RunExtensionAction(const std::string& id, double x, double y) {
    return extension_action_host_ ? extension_action_host_->RunAction(id, x, y)
                                  : ARX_EXTENSION_ACTION_RUN_UNAVAILABLE;
  }
  // DEV-824 follow-up. Empty without an action host, as for running one.
  std::vector<uint8_t> ExtensionActionIcon(const std::string& id, float scale) const {
    return extension_action_host_ ? extension_action_host_->ActionIcon(id, scale)
                                  : std::vector<uint8_t>{};
  }
  // ABI31: the page's JavaScript dialog first (it blocks the renderer), then
  // its permission sheet. Strings are borrowed until the next call.
  bool Dialog(ArxPageDialog* dialog) {
    return (!State().unattended && dialogs_.Pending(dialog)) ||
        PagePermissionPrompt(contents_.get(), dialog);
  }
  ArxPageDialogStatus AnswerDialog(uint64_t token, bool accept, const char* prompt_text) {
    ArxPageDialog current{};
    if (!State().unattended && dialogs_.Pending(&current) && current.token == token)
      return dialogs_.Answer(contents_.get(), token, accept, prompt_text);
    if (prompt_text && *prompt_text) return ARX_PAGE_DIALOG_INVALID;
    return AnswerPagePermissionPrompt(contents_.get(), token, accept);
  }
  void RequestMediaAccessPermission(content::WebContents* contents,
      const content::MediaStreamRequest& request,
      content::MediaResponseCallback callback) override {
    RequestPageMediaAccess(contents, request, std::move(callback));
  }
  bool CheckMediaAccessPermission(content::RenderFrameHost* frame,
      const url::Origin& origin, blink::mojom::MediaStreamType type) override {
    return CheckPageMediaAccess(frame, origin, type);
  }
  MediaBridge* media() { return media_.get(); }
  bool ObserveMedia() {
    if (media_) return true;
    media_ = arx::ObserveMedia(id_, contents_.get(), {
      [](uint64_t page, const ArxMediaSnapshot* snapshot) {
        auto& state = State();
        if (state.running && state.callbacks.media_changed)
          state.callbacks.media_changed(state.callbacks.context, page, snapshot);
      },
      [](uint64_t request, uint64_t page, ArxMediaStatus status) {
        auto& state = State();
        if (state.running && state.callbacks.media_completed)
          state.callbacks.media_completed(state.callbacks.context, request, page, status);
      },
      [](uint64_t page, uint64_t generation) {
        auto& state = State();
        if (state.running && state.callbacks.media_activated)
          state.callbacks.media_activated(state.callbacks.context, page, generation);
      }
    });
    return !!media_;
  }
  content::PictureInPictureResult EnterPictureInPicture(content::WebContents*) override {
    return media_ ? media_->Enter() : content::PictureInPictureResult::kNotSupported;
  }
  void ExitPictureInPicture() override { if (media_) media_->Exit(); }
  // Document PiP (e.g. Google Meet's call window) opens for ordinary pages in
  // Chromium's standalone PiP host; private pages never get it, and neither
  // does an unattended (headless) run, which shows no windows (DEV-948).
  bool IsDocumentPictureInPictureBlockedBySystem() const override {
    return contents_->GetBrowserContext()->IsOffTheRecord() || State().unattended;
  }
  // DEV-943: Back and Forward restore a cached document instead of reloading
  // it, in ordinary and private pages alike, unless Settings › Advanced turned
  // the cache off (back_forward_cache_entries). Prerendering stays off (the
  // delegate default).
  bool IsBackForwardCacheSupported(content::WebContents&) override {
    return State().back_forward_cache_entries > 0;
  }

  // ABI54 (DEV-949). The HTML Fullscreen API: element.requestFullscreen() makes
  // the page fill the screen, as the app shows it. The delegate's defaults did
  // nothing, so YouTube's full-screen button never took effect. Only a page in
  // a visible window may enter, and only with an app that hears the change;
  // otherwise the page's request is refused rather than left pending. Once
  // granted, RenderFrameHostImpl sends the renderer its visual properties, which
  // carry IsFullscreenForTabOrPending, and the app's layout resizes the view.
  // Content exits on its own when the page navigates to another document,
  // crashes or calls document.exitFullscreen(). An unattended (headless) run
  // has no screen to fill: its pages' requests are refused at once.
  bool CanEnterFullscreenModeForTab(content::RenderFrameHost*) override {
    auto& state = State();
    return !destroying_ && state.running && !state.unattended &&
        state.callbacks.page_fullscreen_changed && PopupHostIsVisible();
  }
  void EnterFullscreenModeForTab(content::RenderFrameHost*,
                                 const blink::mojom::FullscreenOptions&) override {
    if (destroying_) return;
    fullscreen_ = true;
    PostFullscreenChange();
  }
  void ExitFullscreenModeForTab(content::WebContents* source) override {
    if (source != contents_.get()) return;
    fullscreen_ = false;
    PostFullscreenChange();
  }
  bool IsFullscreenForTabOrPending(const content::WebContents* source) override {
    return source == contents_.get() && fullscreen_;
  }
  blink::mojom::DisplayMode GetDisplayMode(const content::WebContents* source) override {
    return IsFullscreenForTabOrPending(source) ? blink::mojom::DisplayMode::kFullscreen
                                               : blink::mojom::DisplayMode::kBrowser;
  }
  // ABI54. The app leaves the page's full screen (another tab or space, a
  // closing window, macOS full screen ending). False when it isn't in it.
  bool LeaveFullscreen() {
    if (!fullscreen_ || destroying_) return false;
    // The view's size may not change (a window already in macOS full screen
    // showing only this page), so the renderer is told explicitly.
    contents_->ExitFullscreen(/*will_cause_resize=*/false);
    return true;
  }

  bool ConfigureContentHosting(bool enabled) {
    if (State().adoption_scope.Busy(id_)) return false;
    content_hosting_ = enabled;
    if (!enabled) {
      child_sources_.clear();
      blocked_sources_.clear();
      pending_popup_source_.reset();
      extension_action_host_.reset();
      popup_host_.reset();
      contents_->RemoveUserData(blocked_content::PopupBlockerTabHelper::UserDataKey());
    } else if (!popup_host_) {
      if (popup_host_epoch_ == UINT64_MAX) { content_hosting_ = false; return false; }
      // Retained menus cannot act on a replacement helper's recycled popup IDs.
      const uint64_t host_epoch = ++popup_host_epoch_;
      blocked_content::PopupBlockerTabHelper::CreateForWebContents(contents_.get());
      const auto weak = weak_factory_.GetWeakPtr();
      popup_host_ = std::make_unique<PopupHost>(contents_.get(),
          base::BindRepeating([](base::WeakPtr<Page> owner, uint64_t epoch, int32_t id) {
            if (owner && owner->popup_host_epoch_ == epoch) owner->PopupBlocked(id);
          }, weak, host_epoch),
          base::BindRepeating([](base::WeakPtr<Page> owner, uint64_t epoch) {
            return owner && owner->content_hosting_ && owner->popup_host_epoch_ == epoch
                ? owner->BlockedPopupEntries() : PopupHost::Entries{};
          }, weak, host_epoch),
          base::BindRepeating([](base::WeakPtr<Page> owner, uint64_t epoch, int32_t id) {
            if (owner && owner->popup_host_epoch_ == epoch) owner->OpenBlockedPopup(id);
          }, weak, host_epoch));
    }
    ConfigurePageConsentHosting(contents_.get(), enabled);
    if (enabled && !extension_action_host_ && ExtensionViewsAvailable() &&
        ExtensionActionsProfileIsCurrent(Profile::FromBrowserContext(contents_->GetBrowserContext()))) {
      const auto weak = weak_factory_.GetWeakPtr();
      const auto host_epoch = popup_host_epoch_;
      extension_action_host_ = std::make_unique<ExtensionActionHost>(contents_.get(),
          base::BindRepeating([](base::WeakPtr<Page> owner, uint64_t epoch) -> uint64_t {
            return owner && State().running && owner->content_hosting_ &&
                owner->popup_host_epoch_ == epoch && !State().adoption_scope.DestroyRequested(owner->id_) &&
                ExtensionActionsProfileIsCurrent(Profile::FromBrowserContext(owner->contents_->GetBrowserContext()))
                ? owner->CloseGeneration() : 0;
          }, weak, host_epoch),
          base::BindRepeating([](base::WeakPtr<Page> owner, uint64_t epoch, base::OnceClosure action) {
            if (!owner || !owner->content_hosting_ || owner->popup_host_epoch_ != epoch ||
                !State().adoption_scope.Begin(owner->id_)) return;
            const uint64_t source = owner->id_;
            std::move(action).Run();
            if (State().adoption_scope.End(source)) {
              // Keep Chrome's action runner caller alive until it has unwound.
              base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
                  base::BindOnce([](uint64_t id) { DestroyPage(id); }, source));
            }
          }, weak, host_epoch),
          base::BindRepeating([](base::WeakPtr<Page> owner, uint64_t epoch,
              std::unique_ptr<content::WebContents> child, const GURL& target,
              WindowOpenDisposition disposition) -> content::WebContents* {
            if (!owner || !owner->content_hosting_ || owner->popup_host_epoch_ != epoch ||
                !owner->PopupHostIsVisible() || State().adoption_scope.DestroyRequested(owner->id_) ||
                !ExtensionActionsProfileIsCurrent(Profile::FromBrowserContext(owner->contents_->GetBrowserContext())) ||
                !child || child->GetBrowserContext() != owner->contents_->GetBrowserContext() ||
                !AllowedURL(target)) return nullptr;
            return owner->OfferContents(std::move(child), target, disposition, nullptr);
          }, weak, host_epoch));
    }
    return true;
  }

  void CapturePopupSource(content::RenderFrameHost* opener) {
    pending_popup_source_.reset();
    auto* primary = contents_->GetPrimaryMainFrame();
    if (!content_hosting_ || !opener || !primary || !opener->IsActive() ||
        !opener->IsRenderFrameLive() ||
        content::WebContents::FromRenderFrameHost(opener) != contents_.get() ||
        opener->GetOutermostMainFrame() != primary) return;
    pending_popup_source_ = {opener->GetWeakDocumentPtr(), primary->GetWeakDocumentPtr(),
                             CloseGeneration()};
  }

  bool OwnsBlockedPopupNavigation(NavigateParams* params) {
    if (!content_hosting_) return true;
    if (!opening_popup_ || !blocked_sources_.contains(*opening_popup_) ||
        !PopupSourceIsCurrent(blocked_sources_.at(*opening_popup_)) ||
        params->source_contents != contents_.get() || !PopupHostIsVisible()) return true;
    const auto requests = blocked_content::PopupBlockerTabHelper::FromWebContents(
        contents_.get())->GetBlockedPopupRequests();
    auto found = requests.find(*opening_popup_);
    if (found == requests.end() || found->second != params->url || !AllowedURL(params->url)) return true;
    params->navigated_or_inserted_contents = CreateContentsForNavigation(params, {});
    return true;
  }

  content::WebContents* OpenURLFromTab(content::WebContents* source,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)> callback) override {
    if (!content_hosting_ || source != contents_.get() || !AllowedURL(params.url)) return nullptr;
    if (params.disposition == WindowOpenDisposition::CURRENT_TAB) {
      InvalidateClose();
      auto weak = contents_->GetWeakPtr();
      auto navigation = contents_->GetController().LoadURLWithParams(
          content::NavigationController::LoadURLParams(params));
      if (callback && navigation) std::move(callback).Run(*navigation);
      return weak.get();
    }
    auto* opener = params.initiator_frame_token ? content::RenderFrameHost::FromFrameToken(
        content::GlobalRenderFrameHostToken(params.initiator_process_id,
                                             *params.initiator_frame_token)) : nullptr;
    CapturePopupSource(opener);
    if (!pending_popup_source_) return nullptr;
    NavigateParams navigation(Profile::FromBrowserContext(contents_->GetBrowserContext()),
                              params.url, params.transition);
    navigation.FillNavigateParamsFromOpenURLParams(params);
    navigation.source_contents = contents_.get();
    auto offer = std::make_unique<ChromePopupNavigationDelegate>(std::move(navigation));
    if (blocked_content::ConsiderForPopupBlocking(params.disposition)) {
      auto allowed = blocked_content::MaybeBlockPopup(contents_.get(), nullptr, std::move(offer),
          &params, blink::mojom::WindowFeatures(), HostContentSettingsMapFactory::GetForProfile(
              Profile::FromBrowserContext(contents_->GetBrowserContext())));
      if (!allowed) return nullptr;
      offer.reset(static_cast<ChromePopupNavigationDelegate*>(allowed.release()));
    }
    return CreateContentsForNavigation(offer->nav_params(), std::move(callback));
  }

  // Renderer-created requests must not run before AddNewContents consumes the
  // immutable creation proof and establishes either tab or external ownership.
  bool ShouldResumeRequestsForCreatedWindow() override { return !content_hosting_; }

  void WebContentsCreated(content::WebContents* source,
                          const content::GlobalRenderFrameHostId& opener_id,
                          const std::string&, const GURL& target,
                          content::WebContents* child) override {
    if (!content_hosting_ || source != contents_.get() || !child ||
        child->GetBrowserContext() != source->GetBrowserContext() || !(target.is_empty() || AllowedURL(target) || IsPageExternalTarget(source, target))) return;
    auto* opener = content::RenderFrameHost::FromID(opener_id);
    auto* primary = contents_->GetPrimaryMainFrame();
    if (!opener || !primary || !opener->IsActive() || !opener->IsRenderFrameLive() ||
        content::WebContents::FromRenderFrameHost(opener) != source ||
        opener->GetOutermostMainFrame() != primary) return;
    if (child_sources_.size() >= 16) child_sources_.erase(child_sources_.begin());
    child_sources_[child] = {child->GetWeakPtr(), opener->GetWeakDocumentPtr(), primary->GetWeakDocumentPtr(),
                             CloseGeneration()};
  }

  content::WebContents* AddNewContents(content::WebContents* source,
      std::unique_ptr<content::WebContents> child, const GURL& target,
      WindowOpenDisposition disposition, const blink::mojom::WindowFeatures&,
      bool has_user_gesture, bool* was_blocked) override {
    if (was_blocked) *was_blocked = true;
    auto proof = child_sources_.extract(child.get());
    if (!content_hosting_ || source != contents_.get() || !child || proof.empty() ||
        child->GetBrowserContext() != contents_->GetBrowserContext() || !(target.is_empty() || AllowedURL(target) || IsPageExternalTarget(source, target)) ||
        proof.mapped().child.get() != child.get() ||
        proof.mapped().generation != CloseGeneration()) return nullptr;
    auto* opener = proof.mapped().opener.AsRenderFrameHostIfValid();
    auto* primary = proof.mapped().primary.AsRenderFrameHostIfValid();
    if (!opener || !primary || primary != contents_->GetPrimaryMainFrame() ||
        !opener->IsActive() || !opener->IsRenderFrameLive() ||
        opener->GetOutermostMainFrame() != primary) return nullptr;
    if (disposition == WindowOpenDisposition::NEW_PICTURE_IN_PICTURE)
      return OpenDocumentPictureInPicture(source, std::move(child), has_user_gesture, was_blocked);
    if (IsPageExternalTarget(source, target)) {
      if (!has_user_gesture ||
          (disposition != WindowOpenDisposition::NEW_FOREGROUND_TAB &&
           disposition != WindowOpenDisposition::NEW_BACKGROUND_TAB &&
           disposition != WindowOpenDisposition::NEW_WINDOW &&
           disposition != WindowOpenDisposition::NEW_POPUP)) return nullptr;
      const uint64_t generation = CloseGeneration();
      auto* retained = AdoptPageExternalTarget(std::move(child), source,
          proof.mapped().opener, proof.mapped().primary, target,
          base::BindRepeating([](base::WeakPtr<Page> page, uint64_t generation) {
            return page && page->content_hosting_ && page->CloseGeneration() == generation;
          }, weak_factory_.GetWeakPtr(), generation));
      if (retained && was_blocked) *was_blocked = false;
      return retained;
    }
    // Capture everything before the publication callback: it may close or
    // reconfigure this Page synchronously. Attribution never changes Chrome's
    // actual navigation gesture, sandbox, anti-flood or protocol-policy inputs.
    const bool initially_blank = has_user_gesture &&
        (target.is_empty() || target == GURL("about:blank"));
    auto source_weak = source->GetWeakPtr();
    auto initiator = proof.mapped().opener;
    auto source_primary = proof.mapped().primary;
    const uint64_t generation = CloseGeneration(), host_epoch = popup_host_epoch_;
    auto source_current = base::BindRepeating([](base::WeakPtr<Page> page,
        uint64_t generation, uint64_t host_epoch) {
      return page && !page->destroying_ && generation && host_epoch && State().running && page->content_hosting_ &&
          page->CloseGeneration() == generation && page->popup_host_epoch_ == host_epoch &&
          !State().adoption_scope.DestroyRequested(page->id_);
    }, weak_factory_.GetWeakPtr(), generation, host_epoch);
    // The source callback may synchronously close/reconfigure the opener. Only
    // the accepted exact child and captured weak proofs are touched below.
    auto* accepted = OfferContents(std::move(child), target, disposition, was_blocked);
    if (accepted) {
      if (initially_blank && source_weak)
        BindPublishedBlankChildProvenance(accepted, source_weak.get(), std::move(initiator),
            std::move(source_primary), std::move(source_current));
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
          base::BindOnce([](base::WeakPtr<content::WebContents> child) {
            if (child) child->ResumeLoadingCreatedWebContents();
          }, accepted->GetWeakPtr()));
    }
    return accepted;
  }

  // The standalone host owns the PiP document's WebContents and its window;
  // Arx only resumes the loading it held back for every created window.
  content::WebContents* OpenDocumentPictureInPicture(content::WebContents* source,
      std::unique_ptr<content::WebContents> child, bool has_user_gesture, bool* was_blocked) {
    if (source->GetBrowserContext()->IsOffTheRecord()) return nullptr;
    auto options = child->GetPictureInPictureOptions();
    if (!options) return nullptr;
    auto weak_child = child->GetWeakPtr();
    PictureInPictureWindowManager::GetInstance()->EnterStandaloneDocumentPictureInPicture(
        source, std::move(child), std::move(*options), has_user_gesture);
    if (!weak_child) return nullptr;
    if (was_blocked) *was_blocked = false;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<content::WebContents> child) {
          if (child) child->ResumeLoadingCreatedWebContents();
        }, weak_child));
    return weak_child.get();
  }

  content::WebContents* OfferContents(std::unique_ptr<content::WebContents> child, const GURL& target,
                                     WindowOpenDisposition disposition, bool* was_blocked) {
    ArxNewContentsDisposition intent;
    switch (disposition) {
      case WindowOpenDisposition::NEW_FOREGROUND_TAB: intent = ARX_CONTENTS_FOREGROUND_TAB; break;
      case WindowOpenDisposition::NEW_BACKGROUND_TAB: intent = ARX_CONTENTS_BACKGROUND_TAB; break;
      case WindowOpenDisposition::NEW_WINDOW: intent = ARX_CONTENTS_WINDOW; break;
      case WindowOpenDisposition::NEW_POPUP: intent = ARX_CONTENTS_POPUP; break;
      default: return nullptr;
    }
    auto& state = State();
    if (!state.running || !state.callbacks.new_contents_requested || !state.next_page) return nullptr;
    const std::string target_url = target.is_empty() ? "about:blank" : target.spec();
    if (target_url.size() > 32768 || !state.adoption_scope.Begin(id_)) return nullptr;
    const uint64_t source_id = id_, generation = CloseGeneration(), child_id = state.next_page++;
    auto owned = std::make_unique<Page>(child_id, std::move(child));
    owned->ConfigureContentHosting(content_hosting_);
    Page* exact_child = owned.get();
    state.pages.emplace(child_id, std::move(owned));
    // No source-member access below: a synchronous consumer can close its opener.
    const bool accepted = state.callbacks.new_contents_requested(
        state.callbacks.context, source_id, generation, child_id, target_url.c_str(), target_url.size(), intent);
    if (state.adoption_scope.End(source_id)) {
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(&DestroyPage, source_id));
    }
    auto found = state.pages.find(child_id);
    if (!accepted || !state.running) {
      if (found != state.pages.end() && found->second.get() == exact_child) state.pages.erase(found);
      return nullptr;
    }
    if (found == state.pages.end() || found->second.get() != exact_child) return nullptr;
    if (was_blocked) *was_blocked = false;
    auto result = found->second->contents()->GetWeakPtr();
    found->second->Notify();
    return result.get();
  }

  content::KeyboardEventProcessingResult PreHandleKeyboardEvent(
      content::WebContents* source, const input::NativeWebKeyboardEvent& event) override {
    // ABI54 (DEV-949). Escape leaves page full screen before the page sees it,
    // as Chrome's exclusive access manager does.
    if (source == contents_.get() && fullscreen_ && IsNativeEscape(event) && LeaveFullscreen())
      return content::KeyboardEventProcessingResult::HANDLED;
    // AppKit/system menu handling precedes this exact contents delegate. As in
    // Chrome's high-priority extension registry, a real matching key may invoke
    // the owning profile's command before web content, without a global monitor.
    if (source == contents_.get() && extension_action_host_ && KeyboardHostIsFocused() &&
        extension_action_host_->HandleShortcut(event))
      return content::KeyboardEventProcessingResult::HANDLED;
    if (source == contents_.get() && IsNativeEscape(event)) {
      auto* focused = contents_->GetFocusedFrame();
      auto* primary = contents_->GetPrimaryMainFrame();
      if (focused && primary && focused->IsActive() && focused->IsRenderFrameLive() &&
          focused->GetOutermostMainFrame() == primary && KeyboardHostIsFocused()) {
        escape_event_ = event.os_event;
        escape_source_ = focused->GetWeakDocumentPtr();
        escape_primary_ = primary->GetWeakDocumentPtr();
        escape_authority_.Observe(reinterpret_cast<uintptr_t>(event.os_event.Get()),
                                  CloseGeneration(), EscapeNow());
      }
    }
    // ABI62 (DEV-1264, DEV-1073, DEV-1332). Follow a shortcut key (⌘ or ⌃
    // held, or an F-key) to its ACK, so the app learns whether the page used it.
    if (source == contents_.get() && PageCommandKey::IsCommandKey(event) &&
        State().callbacks.page_command_key && KeyboardHostIsFocused()) {
      auto* focused = contents_->GetFocusedFrame();
      command_key_.Follow(focused ? focused->GetRenderWidgetHost() : nullptr, event,
                          CloseGeneration());
    }
    // Only Chromium's subsequent unconsumed ACK can offer the key to Peek.
    return content::KeyboardEventProcessingResult::NOT_HANDLED;
  }

  bool HandleKeyboardEvent(content::WebContents* source,
                           const input::NativeWebKeyboardEvent& event) override {
    // ABI62 (DEV-1264, DEV-1073, DEV-1332). A followed shortcut key the page left: the app may
    // run its own command for it now.
    if (source != contents_.get()) return false;
    if (const auto key = command_key_.TakeUnconsumed(event)) {
      auto& state = State();
      if (!state.running || !state.callbacks.page_command_key || !KeyboardHostIsFocused() ||
          key->generation != CloseGeneration())
        return false;
      // No member access after this callback: the command may close the page.
      return state.callbacks.page_command_key(state.callbacks.context, id_, key->generation,
                                              key->key_code, key->modifier_flags, key->timestamp,
                                              false);
    }
    if (source != contents_.get() || !IsNativeEscape(event)) return false;
    if (!escape_authority_.Consume(reinterpret_cast<uintptr_t>(event.os_event.Get()),
                                   CloseGeneration(), EscapeNow())) return false;
    auto* focused = escape_source_.AsRenderFrameHostIfValid();
    auto* primary = escape_primary_.AsRenderFrameHostIfValid();
    ClearEscape();
    auto& state = State();
    if (!state.running || !state.callbacks.unhandled_escape || !focused || !primary ||
        focused != contents_->GetFocusedFrame() || primary != contents_->GetPrimaryMainFrame() ||
        !focused->IsActive() || !focused->IsRenderFrameLive() ||
        focused->GetOutermostMainFrame() != primary || !KeyboardHostIsFocused()) return false;
    // No member access after this callback: an accepting consumer must defer its
    // normal before-unload close, but a different embedder may destroy the page.
    return state.callbacks.unhandled_escape(state.callbacks.context, id_, CloseGeneration());
  }

  // ABI24. Chromium reports the link under the pointer, in any frame, as the
  // status URL; empty means the pointer isn't over a link.
  // ABI55 (DEV-885). Chromium asks from a window.focus() the page may make,
  // a service worker's client.focus() and openWindow(). Arx answers only while
  // a click on a notification from the page's site runs; any other
  // window.focus() still does nothing.
  void ActivateContents(content::WebContents* contents) override {
    if (contents != contents_.get() || !State().callbacks.page_activation_requested ||
        !ClaimNotificationActivation(contents)) return;
    const auto weak = weak_factory_.GetWeakPtr();
    const uint64_t id = id_, generation = CloseGeneration();
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<Page> page, uint64_t id, uint64_t generation) {
          auto& state = State();
          if (!page || !state.running || !state.callbacks.page_activation_requested ||
              page->CloseGeneration() != generation) return;
          // No member access after this callback: the app may close the page.
          state.callbacks.page_activation_requested(state.callbacks.context, id, generation);
        }, weak, id, generation));
  }

  void UpdateTargetURL(content::WebContents* source, const GURL& url) override {
    if (source != contents_.get()) return;
    hovered_link_ = url;
    hovered_link_target_ = HoveredLinkTarget::kUnknown;
    const uint64_t ask = ++hovered_link_request_;
    auto& state = State();
    // Nothing shows the link status: no report and no frame asked (DEV-1118).
    // The app hears nothing meanwhile, so the next report after it turns them
    // on again is never taken for a repeat.
    if (!state.link_hover_reports || !state.callbacks.page_link_hovered) {
      hovered_link_reported_.clear();
      hovered_link_flags_reported_ = 0;
      return;
    }
    // ABI60 (DEV-1118): a link waits for where it navigates; no link reports at once.
    if (ReportedHoveredLink().empty()) {
      PostHoveredLinkChange();
      return;
    }
    RequestHoveredLinkTarget(contents_.get(), url, base::BindOnce(
        [](base::WeakPtr<Page> page, uint64_t ask, HoveredLinkTarget target) {
          // A newer hover or document asked again; its own answer reports.
          if (!page || page->hovered_link_request_ != ask) return;
          page->hovered_link_target_ = target;
          page->PostHoveredLinkChange();
        }, weak_factory_.GetWeakPtr(), ask));
  }

  // ABI60 (DEV-1111), staged. The link under the pointer for the app's link
  // status, as Chrome's status bubble shows it. Posted, never inside Chromium's
  // call, and coalesced: the app hears the link hovered when the task runs,
  // once per change, so passing over several links sends only the last.
  void PostHoveredLinkChange() {
    if (hovered_link_post_pending_) return;
    hovered_link_post_pending_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<Page> page) {
          if (!page) return;
          page->hovered_link_post_pending_ = false;
          auto& state = State();
          if (!state.running || !state.callbacks.page_link_hovered) return;
          const std::string spec = page->ReportedHoveredLink();
          uint32_t flags = 0;
          // From the link as hovered: one with credentials is never offered as a
          // cross-site click (ABI43), though its address is shown without them.
          const GURL& hovered = page->hovered_link_;
          if (!spec.empty() && !hovered.has_username() && !hovered.has_password()) {
            auto* primary = page->contents_->GetPrimaryMainFrame();
            if (primary && IsCrossSite(primary->GetLastCommittedURL(), hovered))
              flags |= ARX_HOVERED_LINK_CROSS_SITE;
          }
          if (!spec.empty()) {
            switch (page->hovered_link_target_) {
              case HoveredLinkTarget::kUnknown: break;
              case HoveredLinkTarget::kMainFrame: flags |= ARX_HOVERED_LINK_TARGET_KNOWN; break;
              case HoveredLinkTarget::kSubframe:
                flags |= ARX_HOVERED_LINK_TARGET_KNOWN | ARX_HOVERED_LINK_IN_SUBFRAME;
                break;
              case HoveredLinkTarget::kNewContext:
                flags |= ARX_HOVERED_LINK_TARGET_KNOWN | ARX_HOVERED_LINK_NEW_CONTEXT;
                break;
            }
          }
          if (spec == page->hovered_link_reported_ && flags == page->hovered_link_flags_reported_)
            return;
          page->hovered_link_reported_ = spec;
          page->hovered_link_flags_reported_ = flags;
          const uint64_t id = page->id_, generation = page->CloseGeneration();
          // No member access after this callback: the app may close the page.
          state.callbacks.page_link_hovered(state.callbacks.context, id, generation,
                                            spec.data(), spec.size(), flags);
        }, weak_factory_.GetWeakPtr()));
  }

  // The hovered link without its user name or password; empty for none, an
  // invalid link or one longer than 8192 bytes.
  std::string ReportedHoveredLink() const {
    if (!hovered_link_.is_valid()) return std::string();
    GURL link = hovered_link_;
    if (link.has_username() || link.has_password()) {
      GURL::Replacements replacements;
      replacements.ClearUsername();
      replacements.ClearPassword();
      link = link.ReplaceComponents(replacements);
    }
    std::string spec = link.spec();
    if (spec.size() > 8192) return std::string();
    return spec;
  }

  // ABI49 (DEV-855). The page called window.close() and Blink allowed it: a
  // window a script opened, with one history entry. Posted, never inside
  // Chromium's call, and only while the same document is current. Blink has
  // run before-unload already; the app closes the page's host, nothing here.
  void CloseContents(content::WebContents* source) override {
    if (source != contents_.get()) return;
    const auto weak = weak_factory_.GetWeakPtr();
    const uint64_t id = id_, generation = CloseGeneration();
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<Page> page, uint64_t id, uint64_t generation) {
          auto& state = State();
          if (!page || !state.running || !state.callbacks.page_close_requested ||
              page->CloseGeneration() != generation) return;
          // No member access after this callback: the app may close the page.
          state.callbacks.page_close_requested(state.callbacks.context, id, generation);
        }, weak, id, generation));
  }

  // ABI24. Offers the hovered link to the app for a Force Click. Only http(s)
  // links in an http(s) page of a visible view, without credentials.
  bool ForceClickHoveredLink() {
    auto& state = State();
    if (!state.running || !state.callbacks.link_force_clicked) return false;
    const GURL link = hovered_link_;
    auto* primary = contents_->GetPrimaryMainFrame();
    if (!primary || !primary->GetLastCommittedURL().SchemeIsHTTPOrHTTPS() ||
        !link.is_valid() || !link.SchemeIsHTTPOrHTTPS() || link.has_username() ||
        link.has_password() || link.spec().size() > 8192) return false;
    NSView* view = contents_->GetNativeView().GetNativeNSView();
    if (!view || !view.window || !view.window.visible || view.window.miniaturized ||
        view.hiddenOrHasHiddenAncestor) return false;
    const std::string spec = link.spec();
    // No member access after this callback: the app may close this page.
    return state.callbacks.link_force_clicked(state.callbacks.context, id_, CloseGeneration(),
                                              spec.data(), spec.size());
  }

  // ABI43. Offers a plain click on a link to another site; the throttle has
  // already checked the navigation. Only an ordinary http(s) page in a visible
  // view asks, and only for an http(s) link without credentials.
  bool OfferCrossSiteLink(const GURL& link, int64_t navigation_id) {
    auto& state = State();
    if (!state.running || !state.callbacks.cross_site_link_requested) return false;
    if (contents_->GetBrowserContext()->IsOffTheRecord()) return false;
    auto* primary = contents_->GetPrimaryMainFrame();
    if (!primary || !primary->GetLastCommittedURL().SchemeIsHTTPOrHTTPS() ||
        !link.is_valid() || !link.SchemeIsHTTPOrHTTPS() || link.has_username() ||
        link.has_password() || link.spec().size() > 8192) return false;
    NSView* view = contents_->GetNativeView().GetNativeNSView();
    if (!view || !view.window || !view.window.visible || view.window.miniaturized ||
        view.hiddenOrHasHiddenAncestor) return false;
    const std::string spec = link.spec();
    // A taken link cancels its navigation. Remember it first: the app may
    // close this page in the callback, and then nothing here may be touched.
    taken_link_navigation_ = navigation_id;
    const auto weak = weak_factory_.GetWeakPtr();
    const bool taken = state.callbacks.cross_site_link_requested(
        state.callbacks.context, id_, CloseGeneration(), spec.data(), spec.size());
    if (weak && !taken) weak->taken_link_navigation_ = 0;
    return taken;
  }

  // ABI50 (DEV-857). Offers a link for another app, after a posted task so
  // the app never runs inside Chrome's LaunchUrl. A document that changed
  // first drops it, as Chrome's own source guard would. A declined link, or
  // an app that stopped asking, continues on Chrome's path.
  void OfferExternalLink(const GURL& link, const std::optional<url::Origin>& source_origin,
                         ui::PageTransition transition, bool has_user_gesture,
                         base::RepeatingCallback<bool()> source_guard,
                         base::OnceClosure chrome_path) {
    const bool off_the_record = contents_->GetBrowserContext()->IsOffTheRecord();
    uint32_t flags = 0;
    if (has_user_gesture) flags |= ARX_EXTERNAL_LINK_USER_GESTURE;
    if (transition & (ui::PAGE_TRANSITION_CLIENT_REDIRECT | ui::PAGE_TRANSITION_SERVER_REDIRECT))
      flags |= ARX_EXTERNAL_LINK_REDIRECT;
    if (off_the_record) flags |= ARX_EXTERNAL_LINK_PRIVATE;
    std::string key;
    if (!off_the_record) {
      const auto current = CurrentExtensionProfileKey(
          Profile::FromBrowserContext(contents_->GetBrowserContext()));
      if (current) key = *current;
    }
    std::string origin;
    if (source_origin && !source_origin->opaque()) origin = source_origin->Serialize();
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<Page> page, uint64_t id, uint64_t generation,
                          std::string spec, std::string key, std::string origin, uint32_t flags,
                          base::RepeatingCallback<bool()> source_guard,
                          base::OnceClosure chrome_path) {
          // The initiating frame may have navigated or gone without a new main
          // document: Chrome's own guard decides, as it would for its dialog.
          if (!page || page->CloseGeneration() != generation) return;
          if (source_guard && !source_guard.Run()) return;
          auto& state = State();
          if (!state.running || !state.callbacks.external_link_requested) {
            std::move(chrome_path).Run();
            return;
          }
          // The page keeps the guard for the link it takes, so the app can
          // recheck the source when the person answers (external_link_is_current).
          const uint64_t token = ++page->external_link_tokens_;
          // A declined offer gives back the record of the link taken before it,
          // whose prompt may still be waiting or falling back to Open app.
          ExternalLinkSource previous = page->external_link_;
          page->external_link_ = {token, generation, source_guard};
          // No member access through the raw page after this callback: the app
          // may close it. Chrome's path holds only its own getter and guard.
          const bool taken = state.callbacks.external_link_requested(
              state.callbacks.context, id, generation, token, key.empty() ? nullptr : key.c_str(),
              spec.data(), spec.size(), origin.data(), origin.size(), flags);
          if (!taken) {
            if (page && page->external_link_.token == token)
              page->external_link_ = std::move(previous);
            std::move(chrome_path).Run();
          }
        }, weak_factory_.GetWeakPtr(), id_, CloseGeneration(), link.spec(), std::move(key),
           std::move(origin), flags, std::move(source_guard), std::move(chrome_path)));
  }

  bool HandleContextMenu(content::RenderFrameHost& source,
                         const content::ContextMenuParams& params) override {
    const auto weak = weak_factory_.GetWeakPtr();
    if (HandleLinkContextMenu(source, params)) return true;
    if (!weak) return false;
    // ABI45 (DEV-795): the page itself gets Arx's page menu once the app set it up,
    // with what the page's host can carry out now.
    auto& state = State();
    uint32_t host_items = 0;
    if (PageMenuConfigured() && IsPageMenuContext(params) && state.running &&
        state.callbacks.page_menu_chosen && state.callbacks.page_menu_items) {
      host_items = state.callbacks.page_menu_items(state.callbacks.context, id_) &
          ((1u << ARX_PAGE_MENU_ITEM_COUNT) - 1);
      if (!weak) return true;  // The app may close the page while answering.
    }
    const bool inspect = DevToolsInspectContextEnabled();
    // ABI48 (DEV-814): text fields, selections, images and media get Arx's
    // menus once the app set them up, with the app items the host allows.
    if (ContextMenusConfigured() && ContextMenuKindFor(params) != ContextMenuKind::kNone &&
        state.running) {
      uint64_t app_items = 0;
      if (state.callbacks.context_menu_chosen && state.callbacks.context_menu_items) {
        app_items = state.callbacks.context_menu_items(state.callbacks.context, id_) &
            ((uint64_t{1} << ARX_CONTEXT_MENU_ITEM_COUNT) - 1);
        if (!weak) return true;  // The app may close the page while answering.
      }
      return ShowArxContextMenu(source, params, app_items, inspect);
    }
    if (!host_items && !inspect) return false;
    return ShowPageMenu(source, params, host_items, inspect);
  }

  // ABI48 (DEV-814). The menus for text fields, selections, images and media,
  // checked and rechecked as the page menu is. Native items run on the frame
  // the menu opened on, app items go through context_menu_chosen last.
  bool ShowArxContextMenu(content::RenderFrameHost& source, const content::ContextMenuParams& params,
                          uint64_t app_items, bool inspect) {
    if (!source.IsActive() || !source.IsRenderFrameLive() ||
        content::WebContents::FromRenderFrameHost(&source) != contents_.get()) return false;
    NSView* view = contents_->GetNativeView().GetNativeNSView();
    if (!view || !view.window || !view.window.visible || view.window.miniaturized ||
        view.hiddenOrHasHiddenAncestor) return false;
    // Chromium's params outlive this call, but keep what the menu needs anyway.
    const content::ContextMenuParams menu_params = params;
    const content::WeakDocumentPtr frame = source.GetWeakDocumentPtr();
    const content::WeakDocumentPtr primary = contents_->GetPrimaryMainFrame()->GetWeakDocumentPtr();
    contents_->SetShowingContextMenu(true);
    const auto weak = weak_factory_.GetWeakPtr();
    const ContextMenuSelection chosen = RunContextMenu(
        contents_.get(), menu_params, app_items, inspect ? DevToolsInspectTitle() : std::string());
    if (!weak) return true;
    auto* current = frame.AsRenderFrameHostIfValid();
    const bool same_document = current &&
        primary.AsRenderFrameHostIfValid() == contents_->GetPrimaryMainFrame();
    const bool native = chosen.item != kContextMenuNothing && chosen.item != kContextMenuInspect &&
        !IsAppContextMenuItem(chosen.item);
    // Like Chrome's menu, the command runs before the renderer hears the menu closed.
    if (native && same_document) PerformContextMenuItem(contents_.get(), current, menu_params, chosen);
    if (!weak) return true;
    contents_->SetShowingContextMenu(false);
    contents_->NotifyContextMenuClosed(GURL());
    current = frame.AsRenderFrameHostIfValid();
    if (!current || primary.AsRenderFrameHostIfValid() != contents_->GetPrimaryMainFrame())
      return true;
    if (chosen.item == kContextMenuInspect) {
      InspectElement(contents_.get(), current, menu_params.x, menu_params.y);
    } else if (IsAppContextMenuItem(chosen.item) && (app_items & (uint64_t{1} << chosen.item))) {
      std::string url, text;
      if (!ContextMenuPayload(menu_params, chosen.item, &url, &text)) return true;
      auto& state = State();
      const ArxContextMenuChoice choice{static_cast<ArxContextMenuItem>(chosen.item),
          reinterpret_cast<const uint8_t*>(url.data()), reinterpret_cast<const uint8_t*>(text.data()),
          url.size(), text.size(), static_cast<double>(menu_params.x),
          static_cast<double>(menu_params.y)};
      // No member access after this callback: the app may close this page.
      if (state.running && state.callbacks.context_menu_chosen)
        state.callbacks.context_menu_chosen(state.callbacks.context, id_, CloseGeneration(), &choice);
    }
    return true;
  }

  // The page menu (ABI45) and, in developer mode, Inspect Element. The frame
  // and primary document are rechecked after AppKit's nested tracking loop.
  bool ShowPageMenu(content::RenderFrameHost& source, const content::ContextMenuParams& params,
                    uint32_t host_items, bool inspect) {
    if (!source.IsActive() || !source.IsRenderFrameLive() ||
        content::WebContents::FromRenderFrameHost(&source) != contents_.get()) return false;
    NSView* view = contents_->GetNativeView().GetNativeNSView();
    if (!view || !view.window || !view.window.visible || view.window.miniaturized ||
        view.hiddenOrHasHiddenAncestor) return false;
    const content::WeakDocumentPtr frame = source.GetWeakDocumentPtr();
    const content::WeakDocumentPtr primary = contents_->GetPrimaryMainFrame()->GetWeakDocumentPtr();
    const int x = params.x, y = params.y;
    const content::ContextMenuParams menu_params = params;
    std::shared_ptr<ExtensionMenuItems> extension_items;  // DEV-890
    contents_->SetShowingContextMenu(true);
    const auto weak = weak_factory_.GetWeakPtr();
    const int chosen = RunPageMenu(contents_.get(), host_items,
                                   inspect ? DevToolsInspectTitle() : std::string(), x, y,
                                   &menu_params, &extension_items);
    if (!weak) return true;
    // DEV-890: an extension's item runs, as in Chrome, before the renderer
    // hears the menu closed, on the frame it opened on.
    if (extension_items && frame.AsRenderFrameHostIfValid() &&
        primary.AsRenderFrameHostIfValid() == contents_->GetPrimaryMainFrame())
      extension_items->Execute(chosen, contents_.get(), frame.AsRenderFrameHostIfValid());
    if (!weak) return true;
    contents_->SetShowingContextMenu(false);
    contents_->NotifyContextMenuClosed(GURL());
    auto* current = frame.AsRenderFrameHostIfValid();
    const bool same_document = primary.AsRenderFrameHostIfValid() == contents_->GetPrimaryMainFrame();
    if (chosen == kPageMenuInspect && current && same_document) {
      InspectElement(contents_.get(), current, x, y);
    } else if (chosen == kPageMenuCast && same_document) {
      ShowCastPicker(contents_.get());  // DEV-927
    } else if (chosen >= 0 && chosen < ARX_PAGE_MENU_ITEM_COUNT && same_document) {
      auto& state = State();
      // No member access after this callback: the app may close this page.
      if (state.running && state.callbacks.page_menu_chosen)
        state.callbacks.page_menu_chosen(state.callbacks.context, id_, CloseGeneration(),
                                         static_cast<ArxPageMenuItem>(chosen));
    }
    return true;
  }

  // DEV-890. Adds extensions' items to the app's menu for the current link;
  // a chosen one runs at once if the link's menu is still current.
  bool AppendLinkExtensionItems(uint64_t token, NSMenu* menu) {
    if (!menu || !link_extensions_ || !LinkContextIsCurrent(token)) return false;
    return link_extensions_->AppendTo(menu, base::BindRepeating(&Page::RunLinkExtensionItem,
        weak_factory_.GetWeakPtr(), token, link_extensions_));
  }

  void RunLinkExtensionItem(uint64_t token, std::shared_ptr<ExtensionMenuItems> items, int tag) {
    if (!items || !LinkContextIsCurrent(token)) return;
    items->Execute(tag, contents_.get(), link_source_document_.AsRenderFrameHostIfValid());
  }

  // ABI56 (DEV-851). Download Linked File for the current link menu: from the
  // link's own frame with its sanitized referrer, as Chrome's Save Link As, in
  // the page's ordinary profile. Private pages are refused, as start_download.
  bool DownloadLinkContext(uint64_t token, uint64_t request) {
    if (!LinkContextIsCurrent(token)) return false;
    auto* source = link_source_document_.AsRenderFrameHostIfValid();
    auto* profile = Profile::FromBrowserContext(contents_->GetBrowserContext());
    const auto key = OrdinaryProfileKey(profile);
    if (!source || !key) return false;
    ObserveDownloads(profile, *key, State().callbacks);
    return StartLinkDownload(source, profile, *key, request, link_url_, link_frame_url_,
                             link_referrer_policy_, link_frame_charset_,
                             link_suggested_filename_, State().callbacks);
  }

  ArxDevToolsStatus InspectLinkContext(uint64_t token) {
    if (!LinkContextIsCurrent(token)) return ARX_DEVTOOLS_INVALID;
    auto* source = link_source_document_.AsRenderFrameHostIfValid();
    return InspectElement(contents_.get(), source, link_x_, link_y_);
  }

  bool HandleLinkContextMenu(content::RenderFrameHost& source,
                             const content::ContextMenuParams& params) {
    auto& state = State();
    if (!state.running || !state.callbacks.link_context_requested || params.is_editable ||
        params.form_control_type.has_value() || !source.IsActive() || !source.IsRenderFrameLive() ||
        content::WebContents::FromRenderFrameHost(&source) != contents_.get() ||
        source.GetOutermostMainFrame() != contents_->GetPrimaryMainFrame() ||
        !source.GetLastCommittedURL().SchemeIsHTTPOrHTTPS() ||
        !contents_->GetPrimaryMainFrame()->GetLastCommittedURL().SchemeIsHTTPOrHTTPS()) return false;
    switch (params.source_type) {
      case ui::mojom::MenuSourceType::kMouse:
      case ui::mojom::MenuSourceType::kKeyboard:
      case ui::mojom::MenuSourceType::kTouch:
      case ui::mojom::MenuSourceType::kLongPress:
      case ui::mojom::MenuSourceType::kLongTap:
      case ui::mojom::MenuSourceType::kStylus: break;
      default: return false;
    }
    // link_url has passed Chromium's process filter. Never read unfiltered_link_url,
    // selection_text, form values or suggested filenames.
    // DEV-853: like Chromium's AppendLinkItems, every link gets the menu, whatever its
    // scheme, port or credentials; the app decides which items each link offers.
    // The bound matches Chromium's url::kMaxURLChars.
    constexpr size_t kMaximumLinkBytes = 2 * 1024 * 1024;
    const GURL& link = params.link_url;
    if (!link.is_valid() || link.spec().empty() || link.spec().size() > kMaximumLinkBytes)
      return false;
    if (params.link_text.size() > 4096) return false;
    const std::string text = base::UTF16ToUTF8(params.link_text);
    if (text.size() > 4096 || text.find('\0') != std::string::npos) return false;
    NSView* view = contents_->GetNativeView().GetNativeNSView();
    if (!view || !view.window || !view.window.visible || view.window.miniaturized ||
        view.hiddenOrHasHiddenAncestor) return false;

    DismissLinkContext(link_context_.token());
    const uint64_t token = state.next_link_context_token;
    if (token) ++state.next_link_context_token;  // Exhaustion never recycles identity.
    if (!link_context_.Open(token, CloseGeneration(), params.arx_root_coordinates_valid,
                            params.x, params.y, view.bounds.size.width, view.bounds.size.height))
      return false;
    link_source_document_ = source.GetWeakDocumentPtr();
    link_primary_document_ = contents_->GetPrimaryMainFrame()->GetWeakDocumentPtr();
    link_x_ = params.x;
    link_y_ = params.y;
    link_url_ = link;
    link_frame_url_ = params.frame_url;
    link_referrer_policy_ = params.referrer_policy;
    link_frame_charset_ = params.frame_charset;
    link_suggested_filename_ = params.suggested_filename;
    // DEV-890: extensions' items for this link, for the app's link menu.
    link_extensions_ = std::make_shared<ExtensionMenuItems>(contents_.get(), params);
    const ArxLinkContext menu{token, CloseGeneration(),
        reinterpret_cast<const uint8_t*>(link.spec().data()),
        reinterpret_cast<const uint8_t*>(text.data()), link.spec().size(), text.size(),
        static_cast<double>(params.x), static_cast<double>(params.y)};
    contents_->SetShowingContextMenu(true);
    const auto weak = weak_factory_.GetWeakPtr();
    const bool accepted = state.callbacks.link_context_requested(state.callbacks.context, id_, &menu);
    if (!weak) return true;  // A consumer may synchronously dispose its page.
    if (!accepted) DismissLinkContext(token, false);
    return accepted;
  }

  bool LinkContextIsCurrent(uint64_t token) const {
    auto* source = link_source_document_.AsRenderFrameHostIfValid();
    auto* primary = link_primary_document_.AsRenderFrameHostIfValid();
    const bool current = source && primary && primary == contents_->GetPrimaryMainFrame() &&
        primary->IsActive() && source->IsActive() && source->IsRenderFrameLive() &&
        content::WebContents::FromRenderFrameHost(source) == contents_.get() &&
        source->GetOutermostMainFrame() == primary && contents_->IsShowingContextMenu();
    return link_context_.Current(token, CloseGeneration(), current);
  }

  void DismissLinkContext(uint64_t token, bool notify_renderer = true) {
    if (!link_context_.Dismiss(token)) return;
    link_source_document_ = {};
    link_primary_document_ = {};
    link_extensions_.reset();
    contents_->SetShowingContextMenu(false);
    if (notify_renderer) contents_->NotifyContextMenuClosed(GURL());
  }

  void RenderFrameDeleted(content::RenderFrameHost* frame) override {
    // Only the documents the Escape and link-menu state were taken from end
    // them. Evicting a cached document also deletes its subframes, already
    // pending deletion rather than cached, and those say nothing about the
    // current page (DEV-943). Both are rechecked when used, so other frames
    // never needed to end them. Their weak pointers are still valid here.
    const auto is = [frame](const content::WeakDocumentPtr& document) {
      return document.AsRenderFrameHostIfValid() == frame;
    };
    if (is(escape_source_) || is(escape_primary_)) ClearEscape();
    if (popup_host_) popup_host_->Refresh();
    if (is(link_source_document_) || is(link_primary_document_))
      DismissLinkContext(link_context_.token());
  }

  void PrimaryPageWillBeDeactivated(content::Page&) override {
    InvalidateClose();
    DismissLinkContext(link_context_.token());
  }

  bool Navigate(const GURL& url) {
    // ABI45 (DEV-795): View Page Source and Open File too.
    if (!AllowedURL(url) && !UserNavigationURL(url) && !IsEnabledExtensionPage(
        Profile::FromBrowserContext(contents_->GetBrowserContext()), url)) return false;
    InvalidateClose();
    error_ = 0;
    content::NavigationController::LoadURLParams params(url);
    params.transition_type = ui::PAGE_TRANSITION_TYPED;
    contents_->GetController().LoadURLWithParams(params);
    return true;
  }

  // DEV-878. A new page takes back saved entries before its first load, as
  // Chrome restores a tab; LoadRestored then loads the selected one.
  void Restore(int selected, std::vector<std::unique_ptr<content::NavigationEntry>> entries) {
    InvalidateClose();
    error_ = 0;
    contents_->GetController().Restore(selected, content::RestoreType::kRestored, &entries);
    restored_ = true;
  }

  bool LoadRestored() {
    if (!restored_) return false;
    restored_ = false;
    contents_->GetController().LoadIfNecessary();
    return true;
  }

  content::JavaScriptDialogManager* GetJavaScriptDialogManager(content::WebContents*) override {
    if (State().unattended) return &UnattendedDialogs();
    return &dialogs_;
  }

  void RequestClose(uint64_t request) {
    if (close_request_ || close_authority_.busy()) { ReplyClose(request, false); return; }
    close_request_ = request;
    contents_->DispatchBeforeUnload(false);
  }

  void InvalidateClose() {
    if (extension_action_host_) extension_action_host_->Invalidate();
    ClearEscape();
    child_sources_.clear();
    blocked_sources_.clear();
    pending_popup_source_.reset();
    if (popup_host_) popup_host_->Refresh();
    close_authority_.Invalidate();
    if (auto* gestures = gestures::Controller::FromWebContents(contents_.get()))
      gestures->InvalidateForHostNavigation();
  }
  uint64_t CloseGeneration() const { return close_authority_.generation(); }

  void RequestAuthorizedClose(uint64_t request, uint64_t generation) {
    auto status = close_request_ ? ARX_CLOSE_BUSY : close_authority_.Start(request, generation);
    if (status != ARX_CLOSE_SUCCESS) { ReplyAuthorizedClose({}, id_, request, status, 0); return; }
    close_document_ = contents_->GetPrimaryMainFrame()->GetWeakDocumentPtr();
    if (!content::DispatchBeforeUnloadForArx(contents_->GetPrimaryMainFrame(), base::BindOnce(
        &Page::AuthorizedBeforeUnloadCompleted, weak_factory_.GetWeakPtr(), request))) {
      close_authority_.Reset(request);
      ReplyAuthorizedClose({}, id_, request, ARX_CLOSE_BUSY, 0);
    }
  }

  void CancelAuthorizedClose(uint64_t request) { close_authority_.Cancel(request); }

  ArxCloseStatus ConsumeAuthorizedClose(uint64_t request, uint64_t token) {
    return close_authority_.Consume(request, token, CloseDocumentIsCurrent());
  }

  static void ReplyAuthorizedClose(base::WeakPtr<Page> page, uint64_t id,
                                   uint64_t request, ArxCloseStatus status, uint64_t token) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<Page> page, uint64_t id, uint64_t request,
                          ArxCloseStatus status, uint64_t token) {
          auto& state = State();
          if (!state.running || !state.callbacks.authorized_close_decided) return;
          if (status == ARX_CLOSE_SUCCESS &&
              (!page || !page->close_authority_.Valid(request, token, page->CloseDocumentIsCurrent()))) {
            status = ARX_CLOSE_STALE;
            token = 0;
          }
          state.callbacks.authorized_close_decided(state.callbacks.context, request, id, status, token);
        }, page, id, request, status, token));
  }

  using content::WebContentsObserver::BeforeUnloadFired;
  void BeforeUnloadFired(content::WebContents*, bool proceed, bool* fire_unload) override {
    // The caller commits destruction only after all involved pages have consented.
    *fire_unload = false;
    if (close_request_) {
      ReplyClose(close_request_, proceed);
      close_request_ = 0;
    }
  }

  // DEV-1009. Chromium reports a renderer that left an input unanswered (15 s) on a
  // visible page; each report is a new hang number, so a Wait the app chose doesn't
  // hide the next one. The restarter asks Chromium to check again.
  void RendererUnresponsive(content::WebContents*, content::RenderWidgetHost* host,
                            base::RepeatingClosure hang_monitor_restarter) override {
    // The renderer that left the input unanswered, perhaps an out-of-process frame's.
    hung_process_ = host && host->GetProcess() ? host->GetProcess()->GetDeprecatedID() : 0;
    hung_renderers_[hung_process_] = std::move(hang_monitor_restarter);
    unresponsive_ = ++hang_count_;
    Notify();
  }

  // The page answers again once every renderer Chromium reported hung does.
  void RendererResponsive(content::WebContents*, content::RenderWidgetHost* host) override {
    const int process = host && host->GetProcess() ? host->GetProcess()->GetDeprecatedID() : 0;
    if (!hung_renderers_.erase(process)) return;
    if (!hung_renderers_.empty()) {
      if (hung_process_ == process) hung_process_ = hung_renderers_.begin()->first;
      return;
    }
    if (!unresponsive_) return;
    unresponsive_ = 0;
    hung_process_ = 0;
    pinged_hang_ = false;
    Notify();
  }

  // A primary main frame in another process starts answered.
  void RenderFrameHostChanged(content::RenderFrameHost* old_host,
                              content::RenderFrameHost* new_host) override {
    if (!new_host || !new_host->IsInPrimaryMainFrame()) return;
    if (old_host && old_host->GetProcess() == new_host->GetProcess()) return;
    ObserveRenderer(new_host);
    ForgetHang();
  }

  // DEV-1016: the exit code of the primary main frame's process, which
  // PrimaryMainFrameRenderProcessGone doesn't carry. Either may come first.
  void RenderProcessExited(content::RenderProcessHost*,
                           const content::ChildProcessTerminationInfo& info) override {
    if (ignoring_exit_code_) {
      ignoring_exit_code_ = false;
      return;
    }
    if (awaiting_exit_code_) {
      awaiting_exit_code_ = false;
      end_exit_code_ = info.exit_code;
      Notify();
      return;
    }
    exit_code_seen_ = true;
    last_exit_code_ = info.exit_code;
  }

  // A new child on the same host: whatever ended the last one doesn't speak for it.
  void RenderProcessReady(content::RenderProcessHost* host) override {
    EndedRenderers().erase(host->GetDeprecatedID());
  }

  void RenderProcessHostDestroyed(content::RenderProcessHost*) override {
    renderer_observation_.Reset();
  }

  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus status) override {
    // DEV-873: unloading ends the page's renderer, reported here before the
    // discard, and the renderer may also exit after it. That's no crash; the
    // page reloads when it's shown.
    const bool unloading = PageIsBeingUnloaded(contents_.get());
    // DEV-1016: why the renderer ended, numbered so the app counts each end once. An
    // unload isn't an end: it's neither shown nor counted.
    if (!unloading) {
      ++renderer_ends_;
      end_status_ = static_cast<int32_t>(status);
      auto* frame = contents_->GetPrimaryMainFrame();
      end_by_engine_ = frame && frame->GetProcess() &&
                       EndedByEngine(frame->GetProcess()->GetDeprecatedID());
      end_exit_code_ = exit_code_seen_ ? last_exit_code_ : 0;
      awaiting_exit_code_ = !exit_code_seen_;
    } else {
      // The unloaded renderer's exit code, if it comes later, belongs to no end.
      ignoring_exit_code_ = !exit_code_seen_;
    }
    exit_code_seen_ = false;
    ForgetHang();
    DismissLinkContext(link_context_.token());
    InvalidateClose();
    if (!unloading) error_ = -10000;
    Notify();
  }

  // DEV-873 (page_unload_bridge): the document is gone, the entries stay.
  void WasDiscarded() override {
    DismissLinkContext(link_context_.token());
    InvalidateClose();
    Notify();
  }

  void DidStartNavigation(content::NavigationHandle* navigation) override {
    ClearEscape();
    child_sources_.clear();
    DismissLinkContext(link_context_.token());
    if (!navigation->IsInPrimaryMainFrame()) {
      std::erase_if(blocked_sources_, [navigation](const auto& item) {
        auto* source = item.second.opener.AsRenderFrameHostIfValid();
        return !source || source->GetFrameTreeNodeId() == navigation->GetFrameTreeNodeId();
      });
      if (popup_host_) popup_host_->Refresh();
      return;
    }
    InvalidateClose();
    ForgetFileChooser(id_);
    Notify();
  }

  // ABI30: held only right after an automation action on this page. DEV-1309:
  // any other chooser shows Chrome's file dialog in an interactive run and is
  // cancelled in an unattended one; see file_chooser_bridge.h.
  void RunFileChooser(content::RenderFrameHost* frame,
                      scoped_refptr<content::FileSelectListener> listener,
                      const blink::mojom::FileChooserParams& params) override {
    HandleFileChooser(id_, !State().unattended, frame, std::move(listener), params);
  }

  void EnumerateDirectory(content::WebContents* contents,
                          scoped_refptr<content::FileSelectListener> listener,
                          const base::FilePath& path) override {
    EnumerateFileChooserDirectory(!State().unattended, contents, std::move(listener), path);
  }

  // DEV-1309. The window the page is shown in. Chrome cancels a file dialog
  // whose window is smaller than 400 by 300 points and, without this, measures
  // the page instead, so a small page (a narrow Split View pane, Little Arx,
  // Page in Picture in Picture) would get no dialog in a window big enough.
  std::optional<gfx::Rect> GetWindowBoundsInScreen() override {
    NSWindow* window = contents_->GetNativeView().GetNativeNSView().window;
    if (!window) return std::nullopt;
    return gfx::ScreenRectFromNSRect(window.frame);
  }

  void DidStartLoading() override { Notify(); }
  void DidStopLoading() override { Notify(); }
  void DidFirstVisuallyNonEmptyPaint() override { MarkFirstPagePainted(); }
  void TitleWasSet(content::NavigationEntry*) override { Notify(); }
  // ABI61 (DEV-1101). The app reads page_colors on page_changed.
  void DidChangeThemeColor() override { Notify(); }
  void OnBackgroundColorChanged() override { Notify(); }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    ClearEscape();
    DismissLinkContext(link_context_.token());
    if (!navigation->IsInPrimaryMainFrame()) return;
    // ABI43: a link the app took ends as ERR_ABORTED. The page never left, so
    // its own state, error included, stays as it was.
    if (taken_link_navigation_ && navigation->GetNavigationId() == taken_link_navigation_) {
      taken_link_navigation_ = 0;
      if (!navigation->HasCommitted()) {
        Notify();
        return;
      }
    }
    if (navigation->HasCommitted()) InvalidateClose();
    if (navigation->HasCommitted() && !navigation->IsSameDocument()) {
      // A document restored from the back/forward cache commits here too, with
      // no new document: its prompt counters come back with it (DocumentPrompts).
      document_id_ = base::Uuid::GenerateRandomV4().AsLowercaseString();
      // ABI59 (DEV-1065): one more main-frame document, a reload or a page's own
      // location.reload() included; a fragment or a frame in the page isn't one.
      ++main_documents_;
      find_matches_ = -1;
      find_active_ = -1;
      hovered_link_ = GURL();
      hovered_link_target_ = HoveredLinkTarget::kUnknown;
      ++hovered_link_request_;
      PostHoveredLinkChange();
      // DEV-907: a Badging API badge belongs to the document that set it, so a
      // new document, a reload included, starts without one. Same-document
      // navigation (pushState, a fragment) keeps it.
      PageBadgeChanged(web_contents(), false, 0, false);
      // ABI22: an unattended run cancelled this document's own challenge, so
      // the server's 401/407 body committed without a prompt.
      if (State().unattended && navigation->GetAuthChallengeInfo())
        DocumentPrompts::GetOrCreateForCurrentDocument(navigation->GetRenderFrameHost())
            ->authentication_cancellations = 1;
    }
    error_ = navigation->GetNetErrorCode();
    Notify();
  }

 private:
  // DEV-936. A page the app creates starts hidden, so its PageNode is born
  // hidden: InfiniteTabsFreezing puts it at the front of the recently-used
  // order (OnTypeChanged) without the five-minute recently-visible protection
  // a visible-then-hidden page gets.
  static std::unique_ptr<content::WebContents> CreateHiddenContents(Profile* profile) {
    content::WebContents::CreateParams params(profile);
    params.initially_hidden = true;
    return content::WebContents::Create(params);
  }

  // DEV-936. A page is hidden to Chromium until its view first joins a window.
  // Chromium trusts the visibility a WebContents was created with until its
  // view first reports VISIBLE (WebContentsImpl::UpdateWebContentsVisibility),
  // and Arx never calls WasShown/WasHidden itself, so a page created visible
  // and never mounted kept full-rate timers, foreground priority and a visible
  // PageNode that is never frozen. WasHidden() leaves did_first_set_visible_
  // unset, so the first mount still calls WasShown().
  //
  // initially_hidden also hides the view itself (WebContentsViewMac::CreateView).
  // Arx shows a page only by putting its view in a window, never by unhiding
  // it, so the view is unhidden here and Chromium's visibility alone says the
  // page is hidden; otherwise the first mount would stay hidden and blank.
  void StartHidden() {
    NSView* view = contents_->GetNativeView().GetNativeNSView();
    if (!view) return;
    if (view.hidden) view.hidden = NO;
    // Renderer-created foreground windows arrive visible; the app mounts them
    // at once if it shows them, which calls WasShown() again.
    if (!view.window && contents_->GetVisibility() != content::Visibility::HIDDEN)
      contents_->WasHidden();
  }

  static int64_t EscapeNow() {
    return base::TimeTicks::Now().since_origin().InMilliseconds();
  }

  static bool IsNativeEscape(const input::NativeWebKeyboardEvent& event) {
    NSEvent* native = event.os_event.Get();
    const NSEventModifierFlags modifiers = NSEventModifierFlagShift |
        NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;
    return !event.skip_if_unhandled && native && native.type == NSEventTypeKeyDown &&
        native.keyCode == 53 && !native.isARepeat && !(native.modifierFlags & modifiers) &&
        event.GetType() == blink::WebInputEvent::Type::kRawKeyDown;
  }

  bool KeyboardHostIsFocused() const {
    NSView* view = contents_->GetNativeView().GetNativeNSView();
    NSWindow* window = view.window;
    NSResponder* responder = window.firstResponder;
    return view && window && window.keyWindow && window.visible && !window.miniaturized &&
        !view.hiddenOrHasHiddenAncestor && !NSIsEmptyRect(view.visibleRect) &&
        [responder isKindOfClass:[NSView class]] &&
        (responder == view || [(NSView*)responder isDescendantOf:view]);
  }

  void ClearEscape() {
    escape_authority_.Clear();
    escape_event_ = {};
    escape_source_ = {};
    escape_primary_ = {};
  }

  struct PopupSource {
    content::WeakDocumentPtr opener, primary;
    uint64_t generation;
  };

  bool PopupSourceIsCurrent(const PopupSource& proof) const {
    auto* opener = proof.opener.AsRenderFrameHostIfValid();
    auto* primary = proof.primary.AsRenderFrameHostIfValid();
    return proof.generation == CloseGeneration() && opener && primary &&
        primary == contents_->GetPrimaryMainFrame() && opener->IsActive() &&
        opener->IsRenderFrameLive() && opener->GetOutermostMainFrame() == primary;
  }

  bool PopupHostIsVisible() const {
    NSView* view = contents_->GetNativeView().GetNativeNSView();
    return view && view.window && view.window.visible && !view.window.miniaturized &&
        !view.hiddenOrHasHiddenAncestor && !NSIsEmptyRect(view.visibleRect);
  }

  void PopupBlocked(int32_t identifier) {
    if (pending_popup_source_ && PopupSourceIsCurrent(*pending_popup_source_))
      blocked_sources_[identifier] = *pending_popup_source_;
    pending_popup_source_.reset();
  }

  PopupHost::Entries BlockedPopupEntries() const {
    PopupHost::Entries result;
    auto* helper = blocked_content::PopupBlockerTabHelper::FromWebContents(contents_.get());
    if (!helper) return result;
    for (const auto& [identifier, url] : helper->GetBlockedPopupRequests()) {
      auto proof = blocked_sources_.find(identifier);
      if (proof == blocked_sources_.end() || !PopupSourceIsCurrent(proof->second) ||
          !AllowedURL(url)) continue;
      GURL::Replacements redact;
      redact.ClearUsername(); redact.ClearPassword(); redact.ClearQuery(); redact.ClearRef();
      std::string label;
      base::TruncateUTF8ToByteSize(url.ReplaceComponents(redact).spec(), 512, &label);
      result.emplace_back(identifier, std::move(label));
    }
    return result;
  }

  void OpenBlockedPopup(int32_t identifier) {
    auto proof = blocked_sources_.find(identifier);
    if (proof == blocked_sources_.end() || !PopupSourceIsCurrent(proof->second) ||
        !PopupHostIsVisible() || opening_popup_) return;
    const auto weak = weak_factory_.GetWeakPtr();
    opening_popup_ = identifier;
    blocked_content::PopupBlockerTabHelper::FromWebContents(contents_.get())->ShowBlockedPopup(
        identifier, WindowOpenDisposition::CURRENT_TAB);
    if (!weak) return;
    opening_popup_.reset();
    blocked_sources_.erase(identifier);
    if (popup_host_) popup_host_->Refresh();
  }

  content::WebContents* CreateContentsForNavigation(NavigateParams* params,
      base::OnceCallback<void(content::NavigationHandle&)> callback) {
    if (!AllowedURL(params->url)) return nullptr;
    content::WebContents::CreateParams creation(contents_->GetBrowserContext(),
        params->opener ? params->opener->GetSiteInstance() : tab_util::GetSiteInstanceForNewTab(
            Profile::FromBrowserContext(contents_->GetBrowserContext()), params->url));
    creation.main_frame_name = params->frame_name;
    if (params->opener) creation.opener_id = params->opener->GetGlobalId();
    creation.opened_by_another_window = params->opened_by_another_window;
    creation.initially_hidden = params->disposition == WindowOpenDisposition::NEW_BACKGROUND_TAB;
    auto child = content::WebContents::Create(creation);
    auto* target = OfferContents(std::move(child), params->url, params->disposition, nullptr);
    if (!target) return nullptr;
    auto weak = target->GetWeakPtr();
    auto navigation = target->GetController().LoadURLWithParams(
        LoadURLParamsFromNavigateParams(target, params));
    if (callback && navigation) std::move(callback).Run(*navigation);
    return weak.get();
  }

  std::optional<PopupSource> pending_popup_source_;
  std::map<int32_t, PopupSource> blocked_sources_;
  std::optional<int32_t> opening_popup_;
  std::unique_ptr<PopupHost> popup_host_;
  std::unique_ptr<ExtensionActionHost> extension_action_host_;
  struct ChildSource {
    base::WeakPtr<content::WebContents> child;
    content::WeakDocumentPtr opener, primary;
    uint64_t generation;
  };
  bool destroying_ = false;
  bool content_hosting_ = false;
  // ABI54 (DEV-949): the page is in (or entering) HTML full screen, what the
  // app last heard, and whether a report is posted.
  bool fullscreen_ = false;
  bool fullscreen_reported_ = false;
  bool fullscreen_post_pending_ = false;
  uint64_t popup_host_epoch_ = 0;
  std::map<content::WebContents*, ChildSource> child_sources_;
  UnhandledEscapeAuthority escape_authority_;
  // ABI62 (DEV-1264, DEV-1073). The ⌘ key followed to its ACK. Its report is
  // posted with the generation the key was pressed in.
  PageCommandKey command_key_{base::BindRepeating(
      [](Page* page, const PageCommandKey::Key& key) {
        base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
            FROM_HERE, base::BindOnce(&ReportConsumedCommandKey, page->id_, key));
      },
      base::Unretained(this))};
  gfx::NativeEvent escape_event_;
  content::WeakDocumentPtr escape_source_, escape_primary_;

  void AuthorizedBeforeUnloadCompleted(uint64_t request, std::optional<bool> proceed) {
    if (!close_authority_.waiting() || close_authority_.request() != request) return;
    if (!proceed.has_value()) {
      close_authority_.Reset(request);
      ReplyAuthorizedClose({}, id_, request, ARX_CLOSE_STALE, 0);
      return;
    }
    auto& next_token = State().next_close_token;
    const auto token = next_token;
    if (next_token) ++next_token;  // Overflow permanently fails closed.
    const auto status = close_authority_.Decide(*proceed, CloseDocumentIsCurrent(), token);
    ReplyAuthorizedClose(weak_factory_.GetWeakPtr(), id_, request, status,
                         status == ARX_CLOSE_SUCCESS ? token : 0);
  }

  bool CloseDocumentIsCurrent() const {
    auto* document = close_document_.AsRenderFrameHostIfValid();
    return document && document == contents_->GetPrimaryMainFrame();
  }

  static void ReplyClose(uint64_t request, bool proceed) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce([](uint64_t request, bool proceed) {
      auto& state = State();
      if (state.running && state.callbacks.close_decided)
        state.callbacks.close_decided(state.callbacks.context, request, proceed);
    }, request, proceed));
  }

  DocumentPrompts& CurrentPrompts() {
    return *DocumentPrompts::GetOrCreateForCurrentDocument(contents_->GetPrimaryMainFrame());
  }

 public:
  // DEV-1009. 0 while the page answers, else the number of its current hang.
  uint32_t Unresponsive() const { return unresponsive_; }

  // Wait: Chromium (or the fallback ping) checks again, and a hang still there comes
  // back with a new number.
  bool WaitForResponse() {
    if (!unresponsive_) return false;
    for (auto& [process, restarter] : hung_renderers_) {
      if (restarter) restarter.Run();
    }
    // The fallback's hang stays until the page answers; another 15 s without an
    // answer reports it again with a new number.
    // The outstanding ping keeps its time, so its late answer still clears the hang.
    if (pinged_hang_) {
      ping_rearmed_ = true;
      waited_ = base::TimeTicks::Now();
    }
    return true;
  }

  // A page that can't answer and isn't hung: blocked on its own alert, confirm or
  // prompt, or frozen in the background by Chromium. Neither is pinged.
  bool Held() {
    ArxPageDialog dialog{};
    if (!State().unattended && dialogs_.Pending(&dialog)) return true;
    if (!performance_manager::PerformanceManager::IsAvailable()) return false;
    const auto node =
        performance_manager::PerformanceManager::GetPrimaryPageNodeForWebContents(contents_.get());
    return node && node->GetLifecycleState() == performance_manager::PageNode::LifecycleState::kFrozen;
  }

  // Held, or DevTools open on it, asked again at a ping's deadline; a page gone counts.
  base::RepeatingCallback<bool()> HeldCheck() {
    return base::BindRepeating([](base::WeakPtr<Page> page) {
      return !page || page->Held() || DevToolsIsOpen(page->contents());
    }, weak_factory_.GetWeakPtr());
  }

  // Ends the page's renderer process, and every page sharing it, as Chrome's Exit Page
  // does, so a reload, a navigation or a close never waits on a renderer that doesn't
  // answer. The page then reports its renderer gone.
  bool EndRenderer() {
    auto* frame = contents_->GetPrimaryMainFrame();
    // Every renderer reported hung, perhaps an out-of-process frame's besides the main
    // frame's, else the main frame's (the fallback ping and the app's own probe ask it).
    std::set<int> targets;
    if (unresponsive_) {
      for (const auto& [process, restarter] : hung_renderers_) targets.insert(process);
      if (hung_process_) targets.insert(hung_process_);
    }
    if (targets.empty() && frame && frame->GetProcess())
      targets.insert(frame->GetProcess()->GetDeprecatedID());
    const int main_process =
        frame && frame->GetProcess() ? frame->GetProcess()->GetDeprecatedID() : 0;
    bool ended = false;
    bool main_ended = false;
    for (const int id : targets) {
      auto* process = content::RenderProcessHost::FromID(id);
      if (!process || !process->IsInitializedAndNotDead()) continue;
      // Every main frame it drew reports itself gone as the engine's end.
      EndedRenderers()[id] = base::TimeTicks::Now();
      if (!process->Shutdown(content::RESULT_CODE_HUNG)) {
        EndedRenderers().erase(id);
        continue;
      }
      ended = true;
      main_ended = main_ended || id == main_process;
    }
    // Out-of-process frames' renderers bring no main-frame end, so their hangs end now.
    if (ended && !main_ended) ForgetHang();
    return ended;
  }

  // A DevTools client attached to the page, such as DEV-924's request capture, makes
  // Chromium ignore its hangs (WebContentsImpl::ShouldIgnoreUnresponsiveRenderer). While
  // one is, a visible page is pinged every 5 s in Chrome's internal world, and 15 s
  // without an answer counts as a hang. DevTools' own frontend isn't watched: a page
  // paused on a breakpoint isn't hung.
  void SetHangWatch(bool enabled) {
    if (!enabled) {
      hang_watch_.Stop();
      pings_.clear();
      if (pinged_hang_) ForgetHang();
      return;
    }
    if (hang_watch_.IsRunning()) return;
    hang_watch_.Start(FROM_HERE, base::Seconds(5),
                      base::BindRepeating(&Page::CheckHang, base::Unretained(this)));
  }

  // DEV-1016: the page's last renderer end, or false before its first.
  bool RendererEnd(ArxRendererEnd* end) const {
    if (!renderer_ends_ || !end) return false;
    end->number = renderer_ends_;
    end->status = end_status_;
    end->exit_code = end_exit_code_;
    end->ended_by_engine = end_by_engine_;
    return true;
  }

 private:

  void Notify() {
    // Deliver after Chromium unwinds its observer stack. Swift may close the page.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&Page::Deliver, weak_factory_.GetWeakPtr()));
  }

  // ABI54 (DEV-949). Posted, never inside Chromium's call, and coalesced: the
  // app hears the state the page is in when the task runs, once per change, so
  // an enter followed by an exit before delivery sends nothing.
  void PostFullscreenChange() {
    if (fullscreen_post_pending_) return;
    fullscreen_post_pending_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<Page> page) {
          if (!page) return;
          page->fullscreen_post_pending_ = false;
          auto& state = State();
          if (page->fullscreen_ == page->fullscreen_reported_ || !state.running ||
              !state.callbacks.page_fullscreen_changed) return;
          page->fullscreen_reported_ = page->fullscreen_;
          const uint64_t id = page->id_, generation = page->CloseGeneration();
          const bool fullscreen = page->fullscreen_;
          // No member access after this callback: the app may close the page.
          state.callbacks.page_fullscreen_changed(state.callbacks.context, id, generation,
                                                  fullscreen);
        }, weak_factory_.GetWeakPtr()));
  }

  void Deliver() {
    auto& state = State();
    if (!state.running || !state.callbacks.page_changed) return;
    const std::string url = contents_->GetVisibleURL().spec();
    const std::string title = base::UTF16ToUTF8(contents_->GetTitle());
    auto& controller = contents_->GetController();
    state.callbacks.page_changed(state.callbacks.context, id_, url.c_str(),
                                 title.c_str(), contents_->IsLoading(),
                                 controller.CanGoBack(), controller.CanGoForward(), error_);
  }

  LinkContextAuthority link_context_;
  content::WeakDocumentPtr link_source_document_, link_primary_document_;
  int link_x_ = 0, link_y_ = 0;
  // DEV-851: what Download Linked File needs from the menu's ContextMenuParams.
  GURL link_url_, link_frame_url_;
  network::mojom::ReferrerPolicy link_referrer_policy_ = network::mojom::ReferrerPolicy::kDefault;
  std::string link_frame_charset_;
  std::u16string link_suggested_filename_;
  std::shared_ptr<ExtensionMenuItems> link_extensions_;  // DEV-890
  uint64_t id_;
  // DEV-878. Restored entries wait for LoadRestored.
  bool restored_ = false;
  std::string document_id_ = base::Uuid::GenerateRandomV4().AsLowercaseString();
  // ABI59 (DEV-1065): main-frame documents committed so far.
  uint64_t main_documents_ = 0;
  uint64_t close_request_ = 0;
  CloseAuthority close_authority_;
  content::WeakDocumentPtr close_document_;
  int error_ = 0;
  // DEV-1009: the current hang's number (0: answering), the count, Chromium's restarter,
  // and the fallback ping's state.
  uint32_t unresponsive_ = 0;
  uint32_t hang_count_ = 0;
  // Chromium's hung renderers, by process, with each one's restarter.
  std::map<int, base::RepeatingClosure> hung_renderers_;
  int hung_process_ = 0;
  base::RepeatingTimer hang_watch_;
  // The fallback's outstanding pings, by renderer process.
  std::map<int, base::TimeTicks> pings_;
  bool pinged_hang_ = false;
  bool ping_rearmed_ = false;
  // Wait on the fallback's hang: 15 s from here before it's reported again.
  base::TimeTicks waited_;
  // DEV-1016: renderer ends, the last one's status and exit code, and whether the
  // engine ended it (EndRenderer).
  uint32_t renderer_ends_ = 0;
  int32_t end_status_ = 0;
  int32_t end_exit_code_ = 0;
  bool end_by_engine_ = false;
  bool exit_code_seen_ = false;
  bool awaiting_exit_code_ = false;
  bool ignoring_exit_code_ = false;
  int32_t last_exit_code_ = 0;
  base::ScopedObservation<content::RenderProcessHost, content::RenderProcessHostObserver>
      renderer_observation_{this};

  void ObserveRenderer(content::RenderFrameHost* frame) {
    auto* process = frame ? frame->GetProcess() : nullptr;
    if (!process || renderer_observation_.IsObservingSource(process)) return;
    renderer_observation_.Reset();
    renderer_observation_.Observe(process);
    exit_code_seen_ = false;
    ignoring_exit_code_ = false;
  }

  void ForgetHang() {
    hung_renderers_.clear();
    hung_process_ = 0;
    pings_.clear();
    pinged_hang_ = false;
    ping_rearmed_ = false;
    waited_ = base::TimeTicks();
    if (!unresponsive_) return;
    unresponsive_ = 0;
    Notify();
  }

  // One ping per renderer the page uses, by one of its frames, so a hung out-of-process
  // frame is noticed too, and the renderer that doesn't answer is the one ended.
  void CheckHang() {
    // DevTools' own frontend can pause the page on a breakpoint, which isn't a hang.
    if (!content::DevToolsAgentHost::IsDebuggerAttached(contents_.get()) ||
        DevToolsIsOpen(contents_.get()) || Held() ||
        contents_->GetVisibility() != content::Visibility::VISIBLE) {
      pings_.clear();
      return;
    }
    std::map<int, content::RenderFrameHost*> frames;
    contents_->GetPrimaryMainFrame()->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
      if (frame->IsRenderFrameLive()) frames.emplace(frame->GetProcess()->GetDeprecatedID(), frame);
    });
    std::erase_if(pings_, [&](const auto& ping) { return !frames.contains(ping.first); });
    // A hung renderer that no longer draws any of the page's frames isn't the page's hang.
    if (pinged_hang_ && !frames.contains(hung_process_)) ForgetHang();
    const auto now = base::TimeTicks::Now();
    for (const auto& [process, frame] : frames) {
      const auto sent = pings_.find(process);
      if (sent != pings_.end()) {
        const auto since = ping_rearmed_ ? std::max(sent->second, waited_) : sent->second;
        if ((!pinged_hang_ || ping_rearmed_) && now - since >= base::Seconds(15)) {
          pinged_hang_ = true;
          ping_rearmed_ = false;
          hung_process_ = process;
          unresponsive_ = ++hang_count_;
          Notify();
        }
        continue;
      }
      pings_[process] = now;
      frame->ExecuteJavaScriptInIsolatedWorld(
          u"0", base::BindOnce(&Page::Pinged, weak_factory_.GetWeakPtr(), process, now),
          ISOLATED_WORLD_ID_CHROME_INTERNAL);
    }
  }

  void Pinged(int process, base::TimeTicks sent, base::Value) {
    const auto ping = pings_.find(process);
    if (ping == pings_.end() || ping->second != sent) return;
    pings_.erase(ping);
    if (!pinged_hang_ || hung_process_ != process) return;
    pinged_hang_ = false;
    ping_rearmed_ = false;
    hung_process_ = 0;
    unresponsive_ = 0;
    Notify();
  }
  int32_t find_matches_ = -1;
  int32_t find_active_ = -1;
  GURL hovered_link_;
  // ABI60 (DEV-1111): the link last reported through page_link_hovered.
  std::string hovered_link_reported_;
  uint32_t hovered_link_flags_reported_ = 0;
  // ABI60 (DEV-1118): where the hovered link navigates, once its frames answered,
  // and the hover that asked last, so an older answer is dropped.
  HoveredLinkTarget hovered_link_target_ = HoveredLinkTarget::kUnknown;
  uint64_t hovered_link_request_ = 0;
  bool hovered_link_post_pending_ = false;
  // ABI43: the navigation of a cross-site link the app took, until it ends.
  int64_t taken_link_navigation_ = 0;
  // ABI50: the source of the external link the app took last.
  struct ExternalLinkSource {
    uint64_t token = 0;
    uint64_t generation = 0;
    base::RepeatingCallback<bool()> guard;
  };
  ExternalLinkSource external_link_;
  uint64_t external_link_tokens_ = 0;

 public:
  bool ExternalLinkIsCurrent(uint64_t token) {
    if (!token || external_link_.token != token || external_link_.generation != CloseGeneration())
      return false;
    return !external_link_.guard || external_link_.guard.Run();
  }

 private:
  PageDialogs dialogs_{javascript_dialogs::AppModalDialogManager::GetInstance()};
  std::unique_ptr<content::WebContents> contents_;
  std::unique_ptr<MediaBridge> media_;
  std::unique_ptr<SiteIconObservation> site_icons_;
  base::WeakPtrFactory<Page> weak_factory_{this};
};

void DevToolsLayoutChanged(content::WebContents* inspected);

Page* Find(uint64_t id) {
  CheckThread();
  auto& state = State();
  if (!state.running) return nullptr;
  auto found = state.pages.find(id);
  return found == state.pages.end() ? nullptr : found->second.get();
}

// ABI21 extension tab lookup. Chrome resolves tabs.sendMessage/get/query
// through its window list, which never holds Arx pages. Expose only the
// current ordinary profile's own live pages, never another profile's. A
// private window's context is owned while its opener is (DEV-956).
bool ExtensionContextIsOwned(content::BrowserContext* context) {
  auto& state = State();
  if (!state.running || !context) return false;
  Profile* profile = Profile::FromBrowserContext(context);
  if (profile->IsOffTheRecord()) profile = PrivateOpener(profile);
  return profile && std::any_of(state.profiles.begin(), state.profiles.end(), [&](const auto& item) {
    return item.second->profile() == profile && ExtensionProfile(item.first.c_str()) == profile;
  });
}

// `include_incognito` is Chrome's answer for the calling extension: it runs in
// the ordinary profile and the person allows it in private windows. It then
// reaches the private pages that profile opened too, as in Chrome (DEV-956).
std::vector<std::pair<uint64_t, Page*>> ExtensionPages(content::BrowserContext* context,
                                                       bool include_incognito = false) {
  std::vector<std::pair<uint64_t, Page*>> pages;
  if (!ExtensionContextIsOwned(context)) return pages;
  auto& state = State();
  for (const auto& [id, page] : state.pages) {
    content::WebContents* contents = page->contents();
    content::BrowserContext* page_context = contents->GetBrowserContext();
    const bool reached = page_context == context ||
        (include_incognito && !context->IsOffTheRecord() && page_context->IsOffTheRecord() &&
         PrivateOpener(Profile::FromBrowserContext(page_context)) == Profile::FromBrowserContext(context));
    if (!reached || contents->IsBeingDestroyed() || state.adoption_scope.DestroyRequested(id)) continue;
    pages.emplace_back(id, page.get());
  }
  return pages;
}

// ABI22 extension windows. An Arx window is an extension window while it is
// open; the app reports which pages it shows and in what order.
NSWindow* ExtensionNSWindow(int64_t number) {
  return number > 0 ? [NSApp windowWithWindowNumber:static_cast<NSInteger>(number)] : nil;
}

struct PlacedPage {
  int window_id = extension_misc::kUnknownWindowId;
  int64_t window_number = 0;
  size_t order = SIZE_MAX;
  int32_t index = -1;
  bool active = false;
  bool highlighted = false;
};

// DEV-956. The app places only ordinary windows. A private page shown in a
// window, whose opener is loaded, is placed there by the engine: its index is
// its order among that window's shown private pages, and the active one hosts
// an extension popup, holds the focus or comes first. The window keeps one ID
// while it is open.
std::optional<PlacedPage> PrivatePlacementOf(uint64_t id) {
  auto& state = State();
  const auto entry = state.pages.find(id);
  if (entry == state.pages.end()) return std::nullopt;
  content::WebContents* contents = entry->second->contents();
  if (!PrivateOpener(Profile::FromBrowserContext(contents->GetBrowserContext()))) return std::nullopt;
  NSView* view = contents->GetNativeView().GetNativeNSView();
  NSWindow* window = view.window;
  // An open window keeps its pages and ID while it is minimized or hidden;
  // its state goes in the window's own fields.
  if (!window || !ExtensionNSWindow(window.windowNumber) || view.hiddenOrHasHiddenAncestor)
    return std::nullopt;
  std::vector<uint64_t> shown;
  uint64_t popup = 0, focused = 0;
  NSView* responder = [window.firstResponder isKindOfClass:NSView.class] ? (NSView*)window.firstResponder : nil;
  for (const auto& [other_id, other] : state.pages) {
    content::WebContents* other_contents = other->contents();
    NSView* other_view = other_contents->GetNativeView().GetNativeNSView();
    if (other_contents->GetBrowserContext() != contents->GetBrowserContext() ||
        other_view.window != window || other_view.hiddenOrHasHiddenAncestor) continue;
    shown.push_back(other_id);
    if (other->HasFocusedExtensionPopup()) popup = other_id;
    if (responder && [responder isDescendantOf:other_view]) focused = other_id;
  }
  if (shown.empty()) return std::nullopt;
  const uint64_t active = popup ? popup : focused ? focused : shown.front();
  auto& ids = state.private_window_ids;
  for (auto it = ids.begin(); it != ids.end();)
    it = ExtensionNSWindow(it->first) ? std::next(it) : ids.erase(it);
  const auto window_id = ids.try_emplace(window.windowNumber, SessionID::NewUnique()).first;
  const auto index = std::find(shown.begin(), shown.end(), id) - shown.begin();
  return PlacedPage{window_id->second.id(), window.windowNumber,
      state.extension_window_order.size() + static_cast<size_t>(std::distance(ids.begin(), window_id)),
      static_cast<int32_t>(index), id == active, id == active};
}

std::optional<PlacedPage> ExtensionPlacementOf(uint64_t id) {
  auto& state = State();
  const auto found = state.extension_placements.find(id);
  if (found == state.extension_placements.end()) return PrivatePlacementOf(id);
  const auto window = state.extension_window_ids.find(found->second.window_number);
  if (window == state.extension_window_ids.end() || !ExtensionNSWindow(window->first))
    return std::nullopt;
  const auto& order = state.extension_window_order;
  return PlacedPage{window->second.id(), window->first,
      static_cast<size_t>(std::find(order.begin(), order.end(), window->first) - order.begin()),
      found->second.index, found->second.active, found->second.highlighted};
}

std::vector<extensions::ExtensionTabUtil::EmbedderTab> ExtensionTabs(
    content::BrowserContext* context, bool include_incognito) {
  CheckThread();
  struct Entry {
    extensions::ExtensionTabUtil::EmbedderTab tab;
    size_t order;
    uint64_t id;
  };
  const auto pages = ExtensionPages(context, include_incognito);
  // A page whose extension popup has the keyboard is its window's active page,
  // as a Chrome popup always belongs to the active tab (DEV-1316: a popup left
  // open beside another pane doesn't count).
  std::map<int, uint64_t> popup_pages;
  for (const auto& [id, page] : pages) {
    if (!page->HasFocusedExtensionPopup()) continue;
    if (auto placed = ExtensionPlacementOf(id)) popup_pages[placed->window_id] = id;
  }
  std::vector<Entry> entries;
  for (const auto& [id, page] : pages) {
    content::WebContents* contents = page->contents();
    extensions::ExtensionTabUtil::EmbedderTab tab{contents};
    if (auto placed = ExtensionPlacementOf(id)) {
      NSWindow* window = ExtensionNSWindow(placed->window_number);
      const auto popup = popup_pages.find(placed->window_id);
      tab.window_id = placed->window_id;
      tab.index = placed->index;
      tab.active = popup == popup_pages.end() ? placed->active : popup->second == id;
      tab.highlighted = placed->highlighted || tab.active;
      tab.focused_window = window.keyWindow || window.mainWindow;
      entries.push_back({tab, placed->order, id});
      continue;
    }
    // Outside every window (ABI21): a visible page counts as active.
    NSView* view = contents->GetNativeView().GetNativeNSView();
    NSWindow* window = view.window;
    const bool shown = window && window.visible && !window.miniaturized &&
        !view.hiddenOrHasHiddenAncestor;
    tab.active = tab.highlighted = shown;
    tab.focused_window = shown && window.keyWindow;
    entries.push_back({tab, SIZE_MAX, id});
  }
  std::sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) {
    return std::tie(a.order, a.tab.index, a.id) < std::tie(b.order, b.tab.index, b.id);
  });
  std::vector<extensions::ExtensionTabUtil::EmbedderTab> tabs;
  for (auto& entry : entries) tabs.push_back(entry.tab);
  return tabs;
}

// ABI56 (DEV-973): `include_incognito` is Chrome's answer for the caller, as
// for tabs: an extension allowed in private windows, from its worker, popup or
// pages, sees the opener's private windows too, each marked incognito.
extensions::ExtensionTabUtil::EmbedderWindows ExtensionWindows(
    content::BrowserContext* context, content::WebContents* sender, bool include_incognito) {
  CheckThread();
  extensions::ExtensionTabUtil::EmbedderWindows result;
  const auto pages = ExtensionPages(context, include_incognito);
  std::map<size_t, extensions::ExtensionTabUtil::EmbedderWindow> windows;
  std::map<int64_t, int> numbers;
  bool sender_found = false;
  const CGFloat screen = NSScreen.screens.firstObject.frame.size.height;
  for (const auto& [id, page] : pages) {
    const auto placed = ExtensionPlacementOf(id);
    if (sender && !sender_found &&
        (page->contents() == sender || page->HostsExtensionPopup(sender))) {
      sender_found = true;
      result.current = placed ? placed->window_id : extension_misc::kUnknownWindowId;
    }
    if (!placed || windows.contains(placed->order)) continue;
    NSWindow* window = ExtensionNSWindow(placed->window_number);
    const NSRect frame = window.frame;
    extensions::ExtensionTabUtil::EmbedderWindow value;
    value.id = placed->window_id;
    value.incognito = page->contents()->GetBrowserContext()->IsOffTheRecord();
    value.focused = window.keyWindow || window.mainWindow;
    value.minimized = window.miniaturized;
    value.fullscreen = (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    value.left = static_cast<int>(NSMinX(frame));
    value.top = static_cast<int>(screen - NSMaxY(frame));
    value.width = static_cast<int>(NSWidth(frame));
    value.height = static_cast<int>(NSHeight(frame));
    windows.emplace(placed->order, value);
    numbers.emplace(placed->window_number, placed->window_id);
  }
  for (auto& [order, window] : windows) result.windows.push_back(window);
  // The frontmost of these windows was focused last.
  for (NSWindow* window in NSApp.orderedWindows) {
    const auto found = numbers.find(window.windowNumber);
    if (found == numbers.end()) continue;
    result.last_focused = found->second;
    break;
  }
  if (result.last_focused < 0 && !result.windows.empty())
    result.last_focused = result.windows.front().id;
  if (!sender_found) result.current = result.last_focused;
  return result;
}

// ABI21 unattended HTTP authentication. Nobody can answer or close a login
// prompt, so every subframe/subresource challenge is cancelled; an Arx page
// records it for its current document.
bool CancelUnattendedAuthentication(content::WebContents* contents) {
  CheckThread();
  auto& state = State();
  if (!state.unattended) return false;
  for (const auto& [id, page] : state.pages) {
    if (page->contents() == contents) {
      page->AuthenticationCancelled();
      break;
    }
  }
  return true;
}

// ABI22 unattended sign-in prompts. Nobody can answer a WebAuthn or FedCM
// dialog, so a modal WebAuthn request is cancelled before its dialog is built
// and a FedCM request fails; an Arx page records either for its document.
void RecordUnattendedUserAction(content::WebContents* contents, uint32_t request) {
  for (const auto& [id, page] : State().pages) {
    if (page->contents() == contents) {
      page->UserActionRequired(request);
      return;
    }
  }
}

bool RefuseUnattendedWebAuthentication(content::WebContents* contents) {
  CheckThread();
  if (!State().unattended) return false;
  RecordUnattendedUserAction(contents, ARX_USER_ACTION_WEB_AUTHENTICATION);
  return true;
}

bool ReportUnattendedFederatedSignIn(content::WebContents* contents) {
  CheckThread();
  if (!State().unattended) return false;
  RecordUnattendedUserAction(contents, ARX_USER_ACTION_FEDERATED_SIGN_IN);
  return true;
}

// ABI22 unattended shutdown. Runs on Chromium's watchdog thread just before it
// force-exits; the embedder's report must not block.
void ReportShutdownExpiry(int exit_code) {
  auto& state = State();
  if (state.shutdown_expired) state.shutdown_expired(state.shutdown_context, exit_code);
}

void PasswordSaveOffered(uint64_t page, uint64_t token, const char* origin, const char* username,
                         bool update);
void SignInCompleted(uint64_t request, uint64_t page, ArxSignInStatus status,
                     const uint8_t* json, size_t size);
void AutofillSuggestionsChanged(uint64_t page, uint64_t session, const uint8_t* json,
                                size_t size);
void AutofillDataCompleted(uint64_t request, ArxAutofillDataStatus status, const uint8_t* json,
                           size_t size);
void SavedPasswordsCompleted(uint64_t request, ArxSavedPasswordsStatus status,
                             const uint8_t* json, size_t size);
void CredentialImportCompleted(uint64_t request, ArxCredentialImportStatus status,
                               const uint8_t* json, size_t size);
void SiteSettingsCompleted(uint64_t request, ArxSiteSettingsStatus status, const uint8_t* json,
                           size_t size);
void SiteSettingsChangedForProfile(const char* profile_key);
void ProfileDataCompleted(uint64_t request, ArxProfileDataStatus status, const uint8_t* json,
                          size_t size);

// A feature flag, read at launch from the environment or else Arx's defaults
// under the same name. Empty when unset.
std::string FeatureFlag(const char* name) {
  if (const char* variable = std::getenv(name)) return variable;
  NSString* preference = [NSUserDefaults.standardUserDefaults
      stringForKey:[NSString stringWithUTF8String:name]];
  return preference ? std::string(preference.UTF8String) : std::string();
}

// Adds features to the engine's --enable-features= or --disable-features=
// argument, or adds that argument. Chromium keeps only the last copy of a
// switch, so a second --disable-features would drop the first one's features.
void AppendFeatures(std::vector<std::string>& arguments, std::string_view prefix,
                    std::string_view features) {
  for (auto& argument : arguments) {
    if (argument.starts_with(prefix)) {
      argument.append(",").append(features);
      return;
    }
  }
  arguments.push_back(std::string(prefix).append(features));
}

// DEV-944: the bootstrap profile starts the engine and parents private
// contexts; it never shows a page. uBlock Origin, a component extension in
// every regular profile, is its only extension with a background page, and
// that page filters nothing: uBlock is "incognito": "split", so a private
// context gets its own instance and never reaches its parent's. Refusing it
// saves one renderer. Only regular profiles are asked.
bool RefuseBootstrapBackgroundPages(Profile* profile) {
  return profile->GetBaseName().value() == erasure::kBootstrapProfile;
}

// DEV-916: a feature flag for an idle PartitionAlloc trim in the browser
// process, after Ardia's. On Chromium 157 it took about 6 MB off the browser
// process at 20 and 50 tabs (under 1% of Arx's memory) with idle CPU unchanged
// (DEV-682, 2026-11-14); on by default for the beta like every feature flag
// (DEV-1143), and ARX_IDLE_TRIM=off turns it off. On: once
// the page count has stayed the same for 5 s and there has been no input for 2 s,
// release all of the browser process's free PartitionAlloc memory on a worker
// thread, at most every 30 s and once per settled count. Chromium's own
// periodic reclaim runs either way; ReclaimAll adds the aggressive purge
// (thread caches too) it otherwise keeps for memory pressure. The 5 s check
// costs one wakeup per 5 s while the switch is on; it ends with the main
// message loop, and a trim still queued at shutdown is skipped.
class IdleTrim {
 public:
  void Start() {
    std::fputs("ARX_IDLE_TRIM on\n", stderr);
    timer_.Start(FROM_HERE, base::Seconds(5),
                 base::BindRepeating(&IdleTrim::Check, base::Unretained(this)));
  }

 private:
  void Check() {
    const base::TimeTicks now = base::TimeTicks::Now();
    if (State().pages.size() != pages_) {
      pages_ = State().pages.size();
      settled_since_ = now;
      pending_ = true;
      return;
    }
    if (!pending_ || now - settled_since_ < base::Seconds(5) ||
        (!last_trim_.is_null() && now - last_trim_ < base::Seconds(30)) ||
        CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState,
                                               kCGAnyInputEventType) < 2) return;
    pending_ = false;
    last_trim_ = now;
    base::ThreadPool::PostTask(
        FROM_HERE, {base::TaskPriority::BEST_EFFORT, base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN},
        base::BindOnce([] { partition_alloc::MemoryReclaimer::Instance()->ReclaimAll(); }));
  }

  base::RepeatingTimer timer_;
  size_t pages_ = std::numeric_limits<size_t>::max();
  base::TimeTicks settled_since_;
  base::TimeTicks last_trim_;
  bool pending_ = false;
};

IdleTrim& IdleTrimmer() {
  static base::NoDestructor<IdleTrim> trim;
  return *trim;
}

class EngineParts final : public ChromeBrowserMainExtraParts {
 public:
  void PreCreateThreads() override {
    erasure::BeforeThreads();
    // DEV-900: before the Keychain key is first read on a worker thread.
    safe_storage::Prepare(State().unattended);
  }
  void PreProfileInit() override {
    erasure::BeforeProfiles();
    // DEV-927: Arx's Cast picker, after Chrome's views parts set their dialog.
    StartCastPicker();
    // DEV-880 (session_cookies_overlay.py).
    g_browser_process->profile_manager()->SetArxSessionKeeper(
        base::BindRepeating(&ProfileReloadKeepsSession));
    // Without erasure the startup profile is Default, which shows pages.
    if (!erasure::Enabled()) return;
    // ARX_BOOTSTRAP_BACKGROUND_PAGES keeps Chrome's behaviour, on by default
    // like every feature flag (DEV-1143); =off refuses the bootstrap profile's
    // background pages, which saves a renderer.
    if (FeatureFlag("ARX_BOOTSTRAP_BACKGROUND_PAGES") == "off") {
      extensions::ChromeProcessManagerDelegate::SetEmbedderBackgroundPageRefusal(
          &RefuseBootstrapBackgroundPages);
      return;
    }
    std::fputs("ARX_BOOTSTRAP_BACKGROUND_PAGES on\n", stderr);
  }
  void PreBrowserStart() override {
    State().keep_alive = std::make_unique<ScopedKeepAlive>(
        KeepAliveOrigin::APP_CONTROLLER, KeepAliveRestartOption::DISABLED);
    // On by default (DEV-1143); ARX_IDLE_TRIM=off turns it off.
    if (FeatureFlag("ARX_IDLE_TRIM") == "off") return;
    IdleTrimmer().Start();
  }

  void PostBrowserStart() override {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce([] {
          auto& state = State();
          state.running = true;
          if (ExtensionViewsAvailable()) {
            extensions::ExtensionTabUtil::SetEmbedderTabs(base::BindRepeating(&ExtensionTabs));
            extensions::ExtensionTabUtil::SetEmbedderWindows(
                base::BindRepeating(&ExtensionWindows));
          }
          if (state.unattended) {
            HttpAuthCoordinator::SetEmbedderPromptCancellation(
                base::BindRepeating(&CancelUnattendedAuthentication));
            SetUnattendedWebAuthentication(&RefuseUnattendedWebAuthentication);
            SetUnattendedFederatedSignIn(&ReportUnattendedFederatedSignIn);
            // Stays installed through teardown, which the watchdog bounds.
            if (state.shutdown_deadline)
              shutdown_watchdog::SetEmbedderPolicy(
                  static_cast<int>(state.shutdown_deadline), &ReportShutdownExpiry);
          }
          StartPasswords(&PasswordSaveOffered, &SignInCompleted);
          StartAutofill(&AutofillSuggestionsChanged);
          StartAutofillSettings(&AutofillDataCompleted);
          StartPasswordSettings(&SavedPasswordsCompleted);
          StartCredentialImport(&CredentialImportCompleted, &ExtensionProfile);
          StartSiteSettings(&SiteSettingsCompleted, &SiteSettingsChangedForProfile);
          StartProfileData(&ProfileDataCompleted);
          // One runtime-owned hook; per-page observers never replace or clear it.
          PictureInPictureWindowManager::GetInstance()->SetInitiatorActivationCallback(
              base::BindRepeating([](content::WebContents* contents) {
                if (!State().running) return false;
                for (const auto& [id, page] : State().pages)
                  if (page->contents() == contents && page->media()) {
                    // Ownership consumes the hook even when stale identity rejects
                    // activation. Falling back would bypass the app's focus guards.
                    page->media()->Activate();
                    return true;
                  }
                return false;
              }));
          state.callbacks.ready(state.callbacks.context);
        }));
  }

  void PostMainMessageLoopRun() override {
    erasure::BeforeShutdown();
    auto& state = State();
    state.running = false;
    extensions::ExtensionTabUtil::SetEmbedderTabs({});
    extensions::ExtensionTabUtil::SetEmbedderWindows({});
    HttpAuthCoordinator::SetEmbedderPromptCancellation({});
    SetUnattendedWebAuthentication(nullptr);
    SetUnattendedFederatedSignIn(nullptr);
    state.extension_placements.clear();
    state.extension_window_order.clear();
    state.extension_window_ids.clear();
    state.private_window_ids.clear();
    state.callbacks.stopping(state.callbacks.context);
    state.document_fixture.reset();
    StopAllCaptures();
    StopPdfs();
    StopDevelopers();
    StopAutofill();
    StopAutofillSettings();
    StopNetworkCaptures();
    StopPasswords();
    StopPasswordSettings();
    StopCredentialImport();
    StopSiteSettings();
    StopProfileData();
    StopSiteIcons();
    StopInspections();
    StopFileChoosers();
    StopPageExternalTargets();
    CloseAllDevTools();
    state.pages.clear();
    StopAllDownloads();
    ShutdownExtensions();
    state.retired_private_profiles.clear();
    state.preparing_profiles.clear();
    state.ordinary_profile_keys.clear();
    state.private_profile_keys.clear();
    state.private_profiles.clear();
    state.profiles.clear();
    state.keep_alive.reset();
  }
};

// DEV-942: Blink's MemoryPurgeOnFreeze (off on desktop) makes a backgrounded
// renderer drop its caches when one of its pages freezes. Off: on Chromium 157
// with 50 fixture tabs it saved nothing measurable after the freeze wait, since
// Blink already purges a renderer once soon after it goes to the background,
// and =on cost about 1% of a core in renderers (DEV-682, 2026-11-14).
// A feature flag read at launch from the environment or else Arx's defaults,
// like ARX_SCROLL_EDGE: ARX_MEMORY_PURGE_ON_FREEZE=on purges at every freeze,
// including each periodic refreeze; =limit only at the first freeze while the
// renderer stays in the background. Unset or anything else changes nothing.
std::string MemoryPurgeOnFreezeFeatures() {
  const std::string value = FeatureFlag("ARX_MEMORY_PURGE_ON_FREEZE");
  if (value == "on" || value == "1") return "MemoryPurgeOnFreeze";
  if (value == "limit") return "MemoryPurgeOnFreeze,MemoryPurgeOnFreezeLimit";
  return "";
}

// The most Settings › Advanced can choose, Chrome's own per-tab count.
constexpr size_t kMaximumBackForwardCacheEntries = 6;

// DEV-943: Settings › Advanced › Back and forward cache, read once at launch
// like the feature flags: ARX_BACK_FORWARD_CACHE_SIZE from the environment, or
// else from Arx's defaults, where Settings writes it. 0 turns the cache off; up
// to kMaximumBackForwardCacheEntries pages per tab. Unset or anything else keeps
// the default.
size_t BackForwardCacheEntries() {
  const std::string value = FeatureFlag("ARX_BACK_FORWARD_CACHE_SIZE");
  size_t entries = 0;
  if (value.empty() || !base::StringToSizeT(value, &entries) ||
      entries > kMaximumBackForwardCacheEntries) return kDefaultBackForwardCacheEntries;
  if (entries != kDefaultBackForwardCacheEntries)
    std::fprintf(stderr, "ARX_BACK_FORWARD_CACHE_SIZE %zu\n", entries);
  return entries;
}

int RunWithOptions(const char* executable, const char* profile,
                   const ArxEngineCallbacks* callbacks,
                   const ArxEngineRunOptions* options) {
  CheckThread();
  auto& state = State();
  if (state.started || !executable || !profile || profile[0] != '/' ||
      !callbacks || !callbacks->ready || !callbacks->stopping || !options) return 1;
  const bool signed_fixture = options->extension_install_fixture_for_testing;
  const bool extension_fixture = options->extension_fixture_for_testing || signed_fixture;
  const int fixture_count = static_cast<int>(signed_fixture) + static_cast<int>(options->extension_fixture_for_testing) +
      static_cast<int>(options->document_capture_fixture_for_testing) +
      static_cast<int>(options->gesture_fixture_for_testing);
  if (fixture_count > 1 || (fixture_count &&
      (!options->use_mock_keychain_for_testing || erasure::Enabled()))) return 1;
  if ((options->document_capture_fixture_for_testing || options->gesture_fixture_for_testing) &&
      options->enable_extensions) return 1;
  // ABI44: a loopback stand-in for the Chrome Web Store, only in the owned
  // signed-install fixture. Exactly http://127.0.0.1:<port>.
  std::string webstore_fixture_origin;
  if (options->webstore_fixture_origin_for_testing) {
    const char* origin = options->webstore_fixture_origin_for_testing;
    const size_t length = strnlen(origin, 33);
    constexpr std::string_view prefix = "http://127.0.0.1:";
    const std::string_view value(origin, length);
    if (!signed_fixture || length > 32 || !value.starts_with(prefix) ||
        value.size() == prefix.size() || value.size() > prefix.size() + 5) return 1;
    for (char character : value.substr(prefix.size()))
      if (character < '0' || character > '9') return 1;
    webstore_fixture_origin = std::string(value);
  }
  base::ScopedTempDir fixture_directory;
  std::string profile_path(profile);
  if (fixture_count) {
    if (!fixture_directory.CreateUniqueTempDir()) return 1;
    profile_path = fixture_directory.GetPath().AppendASCII("Browser").value();
    if (options->extension_fixture_for_testing)
      std::fputs("ARX_EXTENSION_FIXTURE_OWNED_STORAGE\n", stderr);
    if (options->document_capture_fixture_for_testing)
      std::fputs("ARX_DOCUMENT_CAPTURE_FIXTURE_OWNED_STORAGE\n", stderr);
    if (options->gesture_fixture_for_testing)
      std::fputs("ARX_GESTURE_FIXTURE_OWNED_STORAGE\n", stderr);
    if (signed_fixture)
      std::fputs("ARX_EXTENSION_INSTALL_FIXTURE_OWNED_STORAGE\n", stderr);
  }
  if (!consent_testing::Initialize(base::FilePath(profile_path), options->use_mock_keychain_for_testing)) return 1;
  state.gesture_fixture = options->gesture_fixture_for_testing;
  state.back_forward_cache_entries = BackForwardCacheEntries();
  state.started = true;
  const base::FilePath fixture_path = extension_fixture
      ? fixture_directory.GetPath() : base::FilePath();
  if (!InitializeExtensions(*callbacks, options->enable_extensions || extension_fixture,
                            fixture_path, signed_fixture, webstore_fixture_origin)) return 1;
  state.callbacks = *callbacks;
  SetDevToolsLayoutObserver(DevToolsLayoutChanged);
  state.document_fixture_enabled = options->document_capture_fixture_for_testing;
  std::vector<std::string> arguments = {
      executable, std::string("--user-data-dir=") + profile_path,
      "--no-startup-window", "--no-first-run", "--no-default-browser-check",
      // Lets Arx open video PiP automatically for sites that don't ask for it
      // (YouTube); Arx still decides when, per site, through the media bridge.
      "--enable-features=BrowserInitiatedAutomaticPictureInPicture,"
      // ABI35: a saved password fills only when asked, never on page load.
      "fill-on-account-select"};
  // DEV-894: a code-signing self-check that only records histograms Arx never
  // uploads, and Google Wallet passes in Autofill AI, whose autofill client
  // asked LocalAuthentication about device re-auth for every page it created.
  AppendFeatures(arguments, "--disable-features=",
                 "AutofillAiWalletPrivatePasses,GatherProcessRequirementMetrics");
  if (const std::string purge = MemoryPurgeOnFreezeFeatures(); !purge.empty()) {
    AppendFeatures(arguments, "--enable-features=", purge);
    std::fprintf(stderr, "ARX_MEMORY_PURGE_ON_FREEZE %s\n", purge.c_str());
  }
  // DEV-873: WebContents::Discard(), which Arx's tab unloading calls in
  // place. Off on desktop, where Chrome swaps in a new WebContents through
  // its tab strip instead; see page_unload_bridge.h.
  AppendFeatures(arguments, "--enable-features=", "WebContentsDiscard");
  if (erasure::Enabled()) {
    arguments.push_back(std::string("--profile-directory=") + erasure::kBootstrapProfile);
    if (erasure::RequiresStrictAcquisition())
      arguments.push_back(std::string("--") + erasure::kStrictStartupSwitch);
  }
  // DEV-944: under memory pressure Chromium stops making spare renderers but
  // keeps the one it has. This drops it too (memory limit 50% or lower scales
  // the one spare to none); one is made again once pressure ends and the
  // browser is idle.
  AppendFeatures(arguments, "--enable-features=", "KillSpareRenderOnMemoryPressure");
  // DEV-916: a feature flag, read like ARX_IDLE_TRIM. ARX_SPARE_RENDERER=off
  // keeps no spare renderer at all, to weigh its memory against the time it
  // saves a new page or a cross-site navigation. Unset keeps Chromium's one: on
  // Chromium 157 =off saved one 10 to 14 MB renderer but made the first launch
  // about 40 ms and opening ten tabs about 70 ms slower (DEV-682, 2026-11-14).
  if (FeatureFlag("ARX_SPARE_RENDERER") == "off") {
    AppendFeatures(arguments, "--disable-features=", "SpareRendererForSitePerProcess");
    std::fputs("ARX_SPARE_RENDERER off\n", stderr);
  }
  // DEV-1144: Widevine is answered without a CDM (media::kArxWidevineAnswer,
  // widevine_answer_overlay.py), on by default. A feature flag read like
  // ARX_SPARE_RENDERER: ARX_WIDEVINE_ANSWER=off lists no Widevine at all, as
  // before, and the protected media handler hears of a page's first question.
  if (FeatureFlag("ARX_WIDEVINE_ANSWER") == "off") {
    AppendFeatures(arguments, "--disable-features=", "ArxWidevineAnswer");
    std::fputs("ARX_WIDEVINE_ANSWER off\n", stderr);
  }
  // DEV-879: pages holding a WebSocket or WebTransport connection are neither
  // frozen nor unloaded (content/public/browser/arx_live_connection.h). A feature
  // flag read like ARX_SPARE_RENDERER: ARX_SPARE_LIVE_CONNECTIONS=off freezes
  // and unloads them as Chromium would, to weigh the CPU the exemption costs.
  if (FeatureFlag("ARX_SPARE_LIVE_CONNECTIONS") == "off") {
    AppendFeatures(arguments, "--disable-features=", "ArxSpareLiveConnections");
    std::fputs("ARX_SPARE_LIVE_CONNECTIONS off\n", stderr);
  }
  if (state.unattended) {
    // Nobody looks at an unattended run's transparent host; occlusion by other
    // windows must not hide or throttle its pages. Sandboxing is unchanged.
    arguments.push_back("--disable-backgrounding-occluded-windows");
    arguments.push_back("--disable-renderer-backgrounding");
    // DEV-865: the device scale the headless run chose at startup, the main
    // screen's or a fixed 2 without any screen. Without it Chromium would build
    // its display from a nil NSScreen (scale 0, clamped to 0.5), and capture
    // sizes would follow a Screen Sharing display as it comes and goes.
    if (const char* scale = std::getenv("ARX_UNATTENDED_DEVICE_SCALE")) {
      char* end = nullptr;
      const double value = std::strtod(scale, &end);
      if (end != scale && *end == '\0' && std::isfinite(value) && value >= 1 && value <= 4) {
        arguments.push_back(std::string("--force-device-scale-factor=") + scale);
        std::fprintf(stderr, "ARX_UNATTENDED_DEVICE_SCALE %s\n", scale);
      }
    }
    // DEV-927: nobody picks a Cast device. Without the Media Router nothing is
    // discovered on the network (no Local Network prompt), and a site's
    // PresentationRequest.start() fails at once with "No screens found".
    AppendFeatures(arguments, "--disable-features=", "MediaRouter");
  }
  if (const char* hosts = std::getenv("ARX_BENCHMARK_FIXTURE_HOSTS");
      hosts && std::string_view(hosts) == "1") {
    // DEV-939: `make benchmark --fixture-hosts same-site` serves its tabs from one
    // site. Only that reserved `.test` name, which never resolves on the internet,
    // is mapped to loopback; every other host resolves as usual.
    arguments.push_back("--host-resolver-rules=MAP *.arx-bench.test 127.0.0.1");
  }
  if (!webstore_fixture_origin.empty()) {
    // Chromium's own store test switch: exposes webstorePrivate to this origin
    // and accepts the store's test publisher key besides the real one.
    arguments.push_back("--apps-gallery-url=" + webstore_fixture_origin + "/");
    std::fputs("ARX_WEBSTORE_FIXTURE_ORIGIN\n", stderr);
  }
  if (options->use_mock_keychain_for_testing) {
    arguments.push_back("--use-mock-keychain");
    std::fputs("ARX_ENGINE_SMOKE_MOCK_KEYCHAIN\n", stderr);
  }
  std::vector<const char*> argv;
  for (const auto& argument : arguments) argv.push_back(argument.c_str());
  argv.push_back(nullptr);
  int result = ChromeMain(static_cast<int>(arguments.size()), argv.data());
  consent_testing::Reset();
  StopSiteIcons();
  StopInspections();
  ShutdownExtensions();
  state.running = false;
  state.callbacks = {};
  erasure::AfterNativeRun(result);
  return result;
}

int Run(const char* executable, const char* profile,
        const ArxEngineCallbacks* callbacks) {
  const ArxEngineRunOptions options = {};
  return RunWithOptions(executable, profile, callbacks, &options);
}

int RunWithProfileRetirement(const char* executable, const char* profile,
                            const ArxEngineCallbacks* callbacks,
                            const ArxEngineRunOptions* options,
                            const char* installation, const char* legacy) {
  CheckThread();
  if (State().started || !executable || !profile || profile[0] != '/' ||
      !callbacks || !callbacks->ready || !callbacks->stopping ||
      !callbacks->profile_retirement_completed || !options ||
      options->extension_fixture_for_testing || options->document_capture_fixture_for_testing ||
      options->gesture_fixture_for_testing || options->extension_install_fixture_for_testing ||
      !installation || !legacy ||
      !erasure::Configure(base::FilePath(profile), installation, legacy, true)) return 1;
  return RunWithOptions(executable, profile, callbacks, options);
}

bool ProfileRetirementAvailable() {
  CheckThread();
  return State().running && erasure::Enabled() && erasure::CurrentSnapshot().durable &&
      erasure::CurrentSnapshot().revision != 0;
}

ArxProfileRetirementStatus PublicRetirementStatus(erasure::Status status) {
  switch (status) {
    case erasure::Status::kOK: return ARX_RETIREMENT_OK;
    case erasure::Status::kBusy: return ARX_RETIREMENT_BUSY;
    case erasure::Status::kInvalid: return ARX_RETIREMENT_INVALID;
    case erasure::Status::kCorrupt: return ARX_RETIREMENT_CORRUPT;
    case erasure::Status::kOwnershipChanged: return ARX_RETIREMENT_OWNERSHIP_CHANGED;
    case erasure::Status::kNotRegistered: return ARX_RETIREMENT_NOT_REGISTERED;
    case erasure::Status::kRetired: return ARX_RETIREMENT_RETIRED;
    case erasure::Status::kStale: return ARX_RETIREMENT_STALE;
    case erasure::Status::kLimit: return ARX_RETIREMENT_LIMIT;
    case erasure::Status::kIO: return ARX_RETIREMENT_IO;
    case erasure::Status::kPending: return ARX_RETIREMENT_PENDING;
    case erasure::Status::kVerified: return ARX_RETIREMENT_VERIFIED;
  }
  return ARX_RETIREMENT_UNAVAILABLE;
}

ArxProfileRetirementProgress PublicRetirementProgress(erasure::Progress progress) {
  switch (progress) {
    case erasure::Progress::kActive: return ARX_RETIREMENT_ACTIVE;
    case erasure::Progress::kAwaitingStartup: return ARX_RETIREMENT_AWAITING_STARTUP;
    case erasure::Progress::kQuarantinePending: return ARX_RETIREMENT_QUARANTINE_PENDING;
    case erasure::Progress::kRestartRequired: return ARX_RETIREMENT_RESTART_REQUIRED;
    case erasure::Progress::kVerificationPending: return ARX_RETIREMENT_VERIFICATION_PENDING;
    case erasure::Progress::kErased: return ARX_RETIREMENT_ERASED;
    case erasure::Progress::kBlocked: return ARX_RETIREMENT_BLOCKED;
  }
  return ARX_RETIREMENT_BLOCKED;
}

void ReplyProfileRetirement(uint64_t request, erasure::Status status,
                            erasure::Snapshot snapshot) {
  auto& state = State();
  if (!state.running || !state.callbacks.profile_retirement_completed) return;
  std::vector<ArxProfileRetirementRecord> records;
  records.reserve(snapshot.records.size());
  for (const auto& record : snapshot.records) {
    records.push_back({record.profile_id.c_str(), record.request_id.c_str(),
        record.storage == erasure::Storage::kLegacyDefault,
        PublicRetirementProgress(record.progress)});
  }
  const ArxProfileRetirementSnapshot result = {
      snapshot.revision, snapshot.durable, records.data(), records.size()};
  state.callbacks.profile_retirement_completed(state.callbacks.context, request,
      PublicRetirementStatus(status), &result);
}

void InspectProfileRetirement(uint64_t request) {
  CheckThread();
  if (!State().running || !State().callbacks.profile_retirement_completed) return;
  if (!erasure::Enabled()) {
    State().callbacks.profile_retirement_completed(State().callbacks.context, request,
        ARX_RETIREMENT_UNAVAILABLE, nullptr);
    return;
  }
  const auto snapshot = erasure::CurrentSnapshot();
  ReplyProfileRetirement(request, snapshot.revision ? erasure::Status::kOK
                                                  : erasure::CurrentStatus(), snapshot);
}

void QueueProfileRetirement(const char* key, bool legacy_storage, const char* request_id,
                            uint64_t revision, uint64_t request) {
  CheckThread();
  if (!State().running || !State().callbacks.profile_retirement_completed) return;
  if (!ProfileRetirementAvailable() || !key || !request_id) {
    State().callbacks.profile_retirement_completed(State().callbacks.context, request,
        ARX_RETIREMENT_UNAVAILABLE, nullptr);
    return;
  }
  erasure::QueueProfile(key, legacy_storage ? erasure::Storage::kLegacyDefault
                                           : erasure::Storage::kOrdinary,
      request_id, revision, base::BindOnce(&ReplyProfileRetirement, request));
}

void Quit() {
  CheckThread();
  if (!State().running) return;
  State().keep_alive.reset();
  chrome::AttemptExit();
}

bool ConfigureContentHosting(uint64_t id, bool enabled) {
  CheckThread();
  auto found = State().pages.find(id);
  return State().running && found != State().pages.end() &&
      found->second->ConfigureContentHosting(enabled);
}

// The prepared profile a new page for this key opens in, or null.
Profile* PageProfile(const char* key) {
  auto& state = State();
  if (!key) return nullptr;
  if (!state.private_profiles.contains(key) && !erasure::ProfileKeyAllowed(key)) return nullptr;
  auto found = state.profiles.find(key);
  Profile* profile = found == state.profiles.end() ? nullptr : found->second->profile();
  if (state.private_profiles.contains(key)) profile = state.private_profiles.at(key);
  // The legacy profile is already loaded during startup; never use "last used".
  if (!profile && !key[0]) profile = g_browser_process->profile_manager()->GetProfileByPath(
      g_browser_process->profile_manager()->user_data_dir().AppendASCII("Default"));
  return profile;
}

Page* AddPage(Profile* profile, const char* key) {
  auto& state = State();
  ObserveDownloads(profile, key, state.callbacks);
  uint64_t id = state.next_page++;
  auto page = std::make_unique<Page>(id, profile);
  auto* pointer = page.get();
  state.pages.emplace(id, std::move(page));
  return pointer;
}

uint64_t CreatePage(const char* url, const char* key) {
  CheckThread();
  auto& state = State();
  if (!state.running || !url || !(AllowedURL(GURL(url)) || UserNavigationURL(GURL(url)))) return 0;
  Profile* profile = PageProfile(key);
  if (!profile) return 0;
  auto* page = AddPage(profile, key);
  page->Navigate(GURL(url));
  return page->identifier();
}

// DEV-878 navigation state: a page's back/forward entries around the current
// one, as Chrome's session service saves a tab. Pickled: magic, version, the
// selected index, the count, then each SerializedNavigationEntry.
constexpr int kNavigationStateMagic = 0x4E585241;  // "ARXN"
constexpr int kNavigationStateVersion = 1;
// Chrome's tab restore keeps six entries on each side of the current one.
constexpr int kNavigationsEachSide = 6;
constexpr int kMaxNavigationEntryBytes = 256 * 1024;
constexpr size_t kMaxNavigationStateBytes = 4 * 1024 * 1024;

bool RestorableNavigationURL(const GURL& url) {
  return AllowedURL(url) || UserNavigationURL(url);
}

size_t CopyNavigationState(uint64_t id, const uint8_t** bytes) {
  if (!bytes) return 0;
  *bytes = nullptr;
  auto* page = Find(id);
  // Private pages never hand out their history.
  if (!page || page->contents()->GetBrowserContext()->IsOffTheRecord()) return 0;
  auto& controller = page->contents()->GetController();
  int current = controller.GetLastCommittedEntryIndex();
  int count = controller.GetEntryCount();
  if (current < 0 || current >= count) return 0;
  auto* committed = controller.GetEntryAtIndex(current);
  if (committed->IsInitialEntry() || !RestorableNavigationURL(committed->GetVirtualURL())) return 0;

  std::vector<sessions::SerializedNavigationEntry> navigations;
  int selected = 0;
  int first = std::max(0, current - kNavigationsEachSide);
  int last = std::min(count - 1, current + kNavigationsEachSide);
  for (int index = first; index <= last; ++index) {
    auto* entry = controller.GetEntryAtIndex(index);
    bool restorable = !entry->IsInitialEntry() && RestorableNavigationURL(entry->GetVirtualURL());
    // An entry that can't come back drops what's behind it, or what's ahead.
    if (!restorable) {
      if (index < current) {
        navigations.clear();
        continue;
      }
      break;
    }
    if (index == current) selected = static_cast<int>(navigations.size());
    navigations.push_back(sessions::ContentSerializedNavigationBuilder::FromNavigationEntry(
        static_cast<int>(navigations.size()), entry));
  }

  base::Pickle pickle;
  pickle.WriteInt(kNavigationStateMagic);
  pickle.WriteInt(kNavigationStateVersion);
  pickle.WriteInt(selected);
  pickle.WriteInt(static_cast<int>(navigations.size()));
  for (const auto& navigation : navigations) navigation.WriteToPickle(kMaxNavigationEntryBytes, &pickle);
  if (pickle.size() > kMaxNavigationStateBytes) return 0;

  auto& buffer = State().navigation_state;
  auto pickled = pickle.AsBytes();
  buffer.assign(pickled.begin(), pickled.end());
  *bytes = buffer.data();
  return buffer.size();
}

bool ReadNavigationState(const uint8_t* bytes, size_t size,
                         std::vector<sessions::SerializedNavigationEntry>* navigations,
                         int* selected) {
  if (!bytes || size == 0 || size > kMaxNavigationStateBytes) return false;
  base::Pickle pickle = base::Pickle::WithData(UNSAFE_BUFFERS(base::span(bytes, size)));
  base::PickleIterator iterator(pickle);
  int magic = 0, version = 0, count = 0;
  if (!iterator.ReadInt(&magic) || magic != kNavigationStateMagic) return false;
  if (!iterator.ReadInt(&version) || version != kNavigationStateVersion) return false;
  if (!iterator.ReadInt(selected) || !iterator.ReadInt(&count)) return false;
  if (count <= 0 || count > 2 * kNavigationsEachSide + 1 || *selected < 0 || *selected >= count)
    return false;
  for (int index = 0; index < count; ++index) {
    sessions::SerializedNavigationEntry navigation;
    if (!navigation.ReadFromPickle(&iterator) || !RestorableNavigationURL(navigation.virtual_url()))
      return false;
    navigations->push_back(std::move(navigation));
  }
  return true;
}

uint64_t CreateRestoredPage(const char* key, const char* expected_url,
                            const uint8_t* bytes, size_t size) {
  CheckThread();
  auto& state = State();
  if (!state.running || !expected_url) return 0;
  Profile* profile = PageProfile(key);
  // Private pages keep no history to restore.
  if (!profile || profile->IsOffTheRecord()) return 0;
  std::vector<sessions::SerializedNavigationEntry> navigations;
  int selected = 0;
  if (!ReadNavigationState(bytes, size, &navigations, &selected)) return 0;
  // Only the page the tab expects to show comes back, never older history.
  if (navigations[selected].virtual_url() != GURL(expected_url)) return 0;
  auto* page = AddPage(profile, key);
  page->Restore(selected, sessions::ContentSerializedNavigationBuilder::ToNavigationEntries(
      navigations, profile));
  return page->identifier();
}

bool LoadRestoredPage(uint64_t id) {
  auto* page = Find(id);
  return page && page->LoadRestored();
}

void PrepareProfile(const char* raw_key, uint64_t request) {
  CheckThread();
  auto& state = State();
  if (!state.running || !raw_key) return;
  std::string key(raw_key);
  if ((!key.empty() && !base::Uuid::ParseLowercase(key).is_valid()) ||
      state.private_profile_keys.contains(key)) {
    state.callbacks.profile_ready(state.callbacks.context, request, false);
    return;
  }
  state.ordinary_profile_keys.insert(key);
  ++state.preparing_profiles[key];
  erasure::RegisterProfile(key, base::BindOnce([](std::string key, uint64_t request, bool registered) {
    auto& state = State();
    if (!state.running) return;
    if (!registered) {
      --state.preparing_profiles[key];
      state.callbacks.profile_ready(state.callbacks.context, request, false);
      return;
    }
    auto* manager = g_browser_process->profile_manager();
    auto path = manager->user_data_dir().AppendASCII(key.empty() ? "Default" : "Arx-" + key);
    manager->CreateProfileAsync(path, base::BindOnce([](std::string key, uint64_t request, Profile* profile) {
      auto& state = State();
      if (!state.running) return;
      --state.preparing_profiles[key];
      if (profile && erasure::ProfileKeyAllowed(key) && !state.profiles.contains(key)) {
        auto keep_alive = ScopedProfileKeepAlive::TryAcquire(profile, ProfileKeepAliveOrigin::kAppWindow);
        if (keep_alive) state.profiles.emplace(key, std::move(keep_alive));
      }
      bool ready = erasure::ProfileKeyAllowed(key) && state.profiles.contains(key);
      if (ready) ObserveDownloads(state.profiles.at(key)->profile(), key, state.callbacks);
      state.callbacks.profile_ready(state.callbacks.context, request, ready);
    }, key, request));
  }, key, request));
}

bool PreparePrivateProfileFor(const char* raw_key, const char* raw_opener_key);

bool PreparePrivateProfile(const char* raw_key) {
  return PreparePrivateProfileFor(raw_key, nullptr);
}

// ABI45 (DEV-729). opener_key names the ordinary profile that opened the private
// window. DEV-889: the private context is that profile's own off-the-record
// child, as a Chrome incognito window is its profile's, so the extensions the
// person allows in private windows (Chrome's incognito switch) run there and
// nothing else of the profile's does. It has its own cookies and storage in
// memory, no history, and goes with the window (ReleasePrivateProfile). The
// opener stays loaded while it has one (OrdinaryProfileInUse). Its download
// folder and "Ask where to save" follow the opener's (private_download_prefs).
// NULL, or an opener that isn't prepared, makes it the bootstrap or Default
// profile's child, as before DEV-889: no extension but Helium's uBlock Origin.
bool PreparePrivateProfileFor(const char* raw_key, const char* raw_opener_key) {
  CheckThread();
  auto& state = State();
  if (!state.running || !raw_key) return false;
  std::string key(raw_key);
  if (!base::Uuid::ParseLowercase(key).is_valid() || !erasure::PrivateKeyAllowed(key) ||
      state.ordinary_profile_keys.contains(key) || state.profiles.contains(key)) return false;
  Profile* opener = nullptr;
  if (raw_opener_key) {
    std::string opener_key(raw_opener_key);
    if (opener_key == key || state.private_profile_keys.contains(opener_key)) return false;
    if (state.profiles.contains(opener_key)) opener = state.profiles.at(opener_key)->profile();
  }
  if (state.private_profiles.contains(key)) {
    if (opener) FollowOpenerDownloadPreferences(state.private_profiles.at(key), opener);
    return true;
  }
  Profile* original = opener;
  if (!original) {
    auto* manager = g_browser_process->profile_manager();
    const char* parent = erasure::Enabled() ? erasure::kBootstrapProfile : "Default";
    original = manager->GetProfileByPath(manager->user_data_dir().AppendASCII(parent));
  }
  if (!original || original->IsOffTheRecord()) return false;
  auto* profile = original->GetOffTheRecordProfile(Profile::OTRProfileID::CreateUnique("Arx"), true);
  if (!profile || !profile->IsOffTheRecord()) return false;
  InitializePrivateDownloadPreferences(profile);
  if (opener) FollowOpenerDownloadPreferences(profile, opener);
  state.private_profile_keys.insert(key);
  state.private_profiles.emplace(key, profile);
  ObserveDownloads(profile, key, state.callbacks);
  PreparePrivateExtensions(profile);  // DEV-889
  return true;
}

void SchedulePrivateProfileRetirement(Profile* profile) {
  auto& state = State();
  auto found = state.retired_private_profiles.find(profile);
  if (!state.running || found == state.retired_private_profiles.end() ||
      found->second.cleanup_posted || DownloadsRetainProfile(profile) ||
      HasPageConsentWork(profile)) return;
  found->second.cleanup_posted = true;
  // Keep destruction off DownloadItem/Swift callback stacks. A terminal snapshot
  // posted after this task was queued also retains the observer until delivery.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
      base::BindOnce([](Profile* profile, uint64_t generation) {
        auto& state = State();
        auto found = state.retired_private_profiles.find(profile);
        if (!state.running || found == state.retired_private_profiles.end() ||
            found->second.generation != generation) return;
        found->second.cleanup_posted = false;
        if (DownloadsRetainProfile(profile) || HasPageConsentWork(profile)) return;
        for (const auto& [id, page] : state.pages)
          if (page->contents()->GetBrowserContext() == profile) return;
        // Detach before invoking Chromium teardown. A replacement browsing
        // context, including one with the same logical key, is independent.
        state.retired_private_profiles.erase(found);
        StopDownloads(profile);
        ProfileDestroyer::DestroyOTRProfileWhenAppropriate(profile);
      }, profile, found->second.generation));
}

void ReleasePrivateProfile(const char* key) {
  CheckThread();
  auto& state = State();
  if (!state.running || !key || !state.private_profiles.contains(key)) return;
  auto* profile = state.private_profiles.at(key);
  // A caller must close every page before releasing its browsing context.
  for (const auto& [id, page] : state.pages) {
    if (page->contents()->GetBrowserContext() == profile) return;
  }
  state.private_profiles.erase(key);
  StopFollowingOpenerDownloadPreferences(profile);
  state.retired_private_profiles.emplace(
      profile, RetiredPrivateProfile{state.next_private_retirement++});
  SchedulePrivateProfileRetirement(profile);
}

bool StartDownloadObservation(const char* key) {
  CheckThread();
  auto& state = State();
  if (!state.running || !key ||
      (!state.private_profiles.contains(key) && !erasure::ProfileKeyAllowed(key))) return false;
  Profile* profile = nullptr;
  if (state.profiles.contains(key)) profile = state.profiles.at(key)->profile();
  if (state.private_profiles.contains(key)) profile = state.private_profiles.at(key);
  if (!profile) return false;
  ObserveDownloads(profile, key, state.callbacks);
  return true;
}

// ABI33. Ordinary profiles only; private browsing never takes automation downloads.
bool RequestStartDownload(uint64_t request, const char* key, const char* url) {
  CheckThread();
  auto& state = State();
  if (!state.running || !key || !url || state.private_profiles.contains(key) ||
      state.private_profile_keys.contains(key) || !erasure::ProfileKeyAllowed(key) ||
      !state.profiles.contains(key)) return false;
  GURL target(url);
  if (!target.SchemeIsHTTPOrHTTPS()) return false;
  auto* profile = state.profiles.at(key)->profile();
  ObserveDownloads(profile, key, state.callbacks);
  return StartDownload(profile, key, request, target, state.callbacks);
}

bool RequestCancelDownload(const char* key, const char* guid) {
  CheckThread();
  return State().running && key && guid && CancelDownload(key, guid);
}

Profile* ExtensionProfile(const char* key) {
  CheckThread();
  auto& state = State();
  if (!state.running || !key || state.private_profiles.contains(key) ||
      !erasure::ProfileKeyAllowed(key)) return nullptr;
  auto found = state.profiles.find(key);
  return found == state.profiles.end() ? nullptr : found->second->profile();
}

// DEV-956. The ordinary profile a private window belongs to: the opener whose
// off-the-record child Arx made its context. Null for anything else, including
// a private context parented by the bootstrap or Default profile for want of one.
Profile* PrivateOpener(Profile* profile) {
  auto& state = State();
  if (!state.running || !profile || !profile->IsOffTheRecord()) return nullptr;
  const bool prepared = std::any_of(state.private_profiles.begin(), state.private_profiles.end(),
      [&](const auto& item) { return item.second == profile; });
  Profile* opener = prepared ? profile->GetOriginalProfile() : nullptr;
  if (!opener || opener->IsOffTheRecord()) return nullptr;
  for (const auto& [key, keep_alive] : state.profiles)
    if (keep_alive->profile() == opener) return opener;
  return nullptr;
}

bool ExtensionActionsProfileIsCurrent(Profile* profile) {
  // DEV-956: a private page shows its opener's extensions allowed in private windows.
  if (profile && profile->IsOffTheRecord()) profile = PrivateOpener(profile);
  if (!State().running || !profile || profile->IsOffTheRecord()) return false;
  for (const auto& [key, keep_alive] : State().profiles)
    if (keep_alive->profile() == profile && !HasExtensionInstallWork(key.c_str()) &&
        ExtensionProfile(key.c_str()) == profile) return true;
  return false;
}

bool ExtensionViewCapability() { return State().running && ExtensionViewsAvailable(); }
void RequestExtensionView(const char* key, uint64_t request, uint64_t revision,
    const char* id, ArxExtensionViewKind kind, uint64_t source_page,
    uint64_t source_generation) {
  OpenExtensionView(ExtensionProfile(key), key ? key : "", request, revision,
      id ? id : "", kind, source_page, source_generation);
}

// ABI50 (DEV-796). Whether a lookup that misses the profile's favicon database
// may fetch the site's icon; site_icons_bridge rechecks it at each stage.
void SetSiteIconFetch(bool enabled) {
  SetSiteIconFetchEnabled(enabled);
  // Lookups already fetching stop too; before the runtime starts there are none.
  if (!enabled && State().running) StopSiteIconFetches();
}

void LookupSiteIconWith(const char* key, const char* url, uint64_t request, bool may_fetch);

void RequestSiteIcon(const char* key, const char* url, uint64_t request) {
  LookupSiteIconWith(key, url, request, /*may_fetch=*/true);
}

// ABI51 (DEV-940): database only, for the app's bookkeeping reads.
void RequestCachedSiteIcon(const char* key, const char* url, uint64_t request) {
  LookupSiteIconWith(key, url, request, /*may_fetch=*/false);
}

void LookupSiteIconWith(const char* key, const char* url, uint64_t request, bool may_fetch) {
  CheckThread();
  auto& state = State();
  Profile* profile = ExtensionProfile(key);
  // The legacy empty key is also a concrete ordinary profile, never last-used.
  if (!profile && state.running && key && !key[0] && erasure::ProfileKeyAllowed(key))
    profile = g_browser_process->profile_manager()->GetProfileByPath(
        g_browser_process->profile_manager()->user_data_dir().AppendASCII("Default"));
  const GURL page_url(url ? url : "");
  // A page showing this URL in the profile loads its own icon; fetching too
  // would only duplicate the request.
  bool shown = false;
  for (const auto& [id, page] : state.pages) {
    content::WebContents* contents = page->contents();
    if (profile && contents && contents->GetBrowserContext() == profile &&
        (contents->GetVisibleURL() == page_url || contents->GetLastCommittedURL() == page_url)) {
      shown = true;
      break;
    }
  }
  LookupSiteIcon(profile, page_url, /*may_fetch=*/may_fetch && !shown && SiteIconFetchEnabled(),
      request,
      [](uint64_t request, ArxSiteIconStatus status, const uint8_t* png,
          size_t size, uint32_t width, uint32_t height, const char* icon_url) {
        auto& state = State();
        if (state.running && state.callbacks.site_icon_completed)
          state.callbacks.site_icon_completed(state.callbacks.context, request,
              status, png, size, width, height, icon_url);
      });
}

void ReplyInspection(uint64_t request, uint64_t page, ArxInspectionStatus status,
                      const uint8_t* json, size_t size) {
  auto& state = State();
  if (state.running && state.callbacks.inspection_completed)
    state.callbacks.inspection_completed(state.callbacks.context, request, page, status, json, size);
}

void RequestInspection(uint64_t id, uint64_t request, const char* scope, ArxInspectionLimits limits) {
  auto* page = Find(id);
  InspectPage(page ? page->contents() : nullptr, id, request, scope, limits, ReplyInspection);
}

void RequestFrameInspection(uint64_t id, uint64_t request, const char* scope, const char* frame,
                            ArxInspectionWindow window) {
  auto* page = Find(id);
  InspectFrame(page ? page->contents() : nullptr, id, request, scope, frame, window, ReplyInspection);
}

void RequestInspectionValidation(uint64_t page, uint64_t request, const char* scope,
                                  const char* snapshot, const char* reference) {
  CheckThread();
  ValidateInspectionReference(page, request, scope, snapshot, reference, ReplyInspection);
}

void RequestReferenceClick(uint64_t page, uint64_t request, const char* scope,
                           const char* snapshot, const char* reference,
                           const char* operation, uint32_t timeout_ms) {
  CheckThread();
  ClickInspectionReference(page, request, scope, snapshot, reference, operation, timeout_ms,
      [](uint64_t request, uint64_t page, int32_t disposition, int32_t status) {
        auto& state = State();
        if (state.running && state.callbacks.reference_click_completed)
          state.callbacks.reference_click_completed(state.callbacks.context, request, page,
                                                     static_cast<ArxClickDisposition>(disposition),
                                                     static_cast<ArxClickStatus>(status));
      });
}

void RequestReferenceFormAction(uint64_t page, uint64_t request, const char* scope,
                                const char* snapshot, const char* reference,
                                const char* operation, ArxFormActionKind kind,
                                const uint8_t* bytes, size_t length, uint32_t timeout_ms) {
  CheckThread();
  PerformInspectionFormAction(page, request, scope, snapshot, reference, operation,
      kind, bytes, length, timeout_ms,
      [](uint64_t request, uint64_t page, int32_t disposition, int32_t status) {
        auto& state = State();
        if (state.running && state.callbacks.form_action_completed)
          state.callbacks.form_action_completed(state.callbacks.context, request, page,
              static_cast<ArxFormDisposition>(disposition), static_cast<ArxFormStatus>(status));
      });
}

void RequestReferenceScroll(uint64_t page, uint64_t request, const char* scope,
                            const char* snapshot, const char* reference, const char* operation,
                            ArxScrollAxis axis, double delta_css_pixels, uint32_t timeout_ms) {
  CheckThread();
  ScrollInspectionReference(page, request, scope, snapshot, reference, operation,
      axis, delta_css_pixels, timeout_ms,
      [](uint64_t request, uint64_t page, int32_t disposition, int32_t status) {
        auto& state = State();
        if (state.running && state.callbacks.reference_scroll_completed)
          state.callbacks.reference_scroll_completed(state.callbacks.context, request, page,
              static_cast<ArxScrollDisposition>(disposition), static_cast<ArxScrollStatus>(status));
      });
}

bool ExtensionInstallAvailable() { return State().running && ExtensionViewsAvailable(); }

void RequestExtensionInstall(const char* key, uint64_t request, uint64_t revision,
                             const char* expected_id, const char* source_basename,
                             const uint8_t* bytes, size_t size) {
  CheckThread();
  // Bound C strings and bytes before constructing owned values. The bytes are
  // copied synchronously; no caller memory survives this call.
  const bool valid_key = key && strnlen(key, 129) < 129;
  const bool valid = valid_key && expected_id && source_basename && bytes && size &&
      size <= 32 * 1024 * 1024 && strnlen(expected_id, 34) < 34 && strnlen(source_basename, 257) < 257;
  InstallExtensionCRX(valid && ExtensionInstallAvailable() ? ExtensionProfile(key) : nullptr,
      valid_key ? key : "", request,
      revision, valid ? expected_id : "", valid ? source_basename : "",
      valid ? UNSAFE_BUFFERS(base::span(bytes, size)) : base::span<const uint8_t>());
}

void RequestSignedExtensionFixture(const char* key, uint64_t request, uint64_t revision,
                                   const char* expected_id, uint32_t variant) {
  CheckThread();
  const bool valid_key = key && strnlen(key, 129) < 129;
  const bool valid = valid_key && expected_id && strnlen(expected_id, 34) < 34 && variant < 4;
  InstallExtensionFixture(valid ? ExtensionProfile(key) : nullptr, valid_key ? key : "", request,
                          revision, valid ? expected_id : "", variant);
}

void RequestWebstoreInstall(const char* key, uint64_t request, uint64_t revision, uint64_t token) {
  CheckThread();
  const bool valid_key = key && strnlen(key, 129) < 129;
  InstallWebstoreExtension(valid_key && ExtensionInstallAvailable() ? ExtensionProfile(key) : nullptr,
                           valid_key ? key : "", request, revision, token);
}

// ABI45 (DEV-776).
void RequestWebstoreUpdate(const char* key, uint64_t request, uint64_t revision,
                           const char* extension_id) {
  CheckThread();
  const bool valid_key = key && strnlen(key, 129) < 129;
  const bool valid = valid_key && extension_id && strnlen(extension_id, 34) < 34;
  UpdateWebstoreExtension(valid_key && ExtensionInstallAvailable() ? ExtensionProfile(key) : nullptr,
                          valid_key ? key : "", request, revision, valid ? extension_id : "");
}

// ABI47 (DEV-845).
void RequestWebstoreInstallByID(const char* key, uint64_t request, uint64_t revision,
                                const char* extension_id) {
  CheckThread();
  const bool valid_key = key && strnlen(key, 129) < 129;
  const bool valid = valid_key && extension_id && strnlen(extension_id, 34) < 34;
  InstallWebstoreExtensionByID(
      valid_key && ExtensionInstallAvailable() ? ExtensionProfile(key) : nullptr,
      valid_key ? key : "", request, revision, valid ? extension_id : "");
}

void DeclineWebstoreInstallRequest(uint64_t token) {
  CheckThread();
  DeclineWebstoreInstall(token);
}

bool ResolveExtensionInstallRequest(const char* key, uint64_t request, uint64_t token, bool accept) {
  CheckThread();
  return key && strnlen(key, 129) < 129 &&
      ResolveExtensionInstall(ExtensionProfile(key), key, request, token, accept);
}

void RequestExtensionInventory(const char* key, uint64_t request) {
  InspectExtensions(ExtensionProfile(key), key ? key : "", request);
}

void RequestExtensionManagement(const char* key, uint64_t request, uint64_t revision,
                                const char* id, ArxExtensionAction action) {
  ManageExtension(ExtensionProfile(key), key ? key : "", request, revision, id ? id : "", action);
}

bool UnpackedExtensionsAvailable() { return ExtensionInstallAvailable(); }

void RequestUnpackedExtension(const char* key, uint64_t request, uint64_t revision,
                              const char* directory) {
  CheckThread();
  // Bound the borrowed C strings before copying; an oversized or absent path
  // reaches native validation as empty and is refused there.
  const bool valid_key = key && strnlen(key, 129) < 129;
  const bool valid_directory = directory && strnlen(directory, 4097) < 4097;
  LoadUnpackedExtension(valid_key && UnpackedExtensionsAvailable() ? ExtensionProfile(key) : nullptr,
      valid_key ? key : "", request, revision, valid_directory ? directory : "");
}

void RequestExtensionFixture(const char* key, uint64_t request) {
  LoadExtensionFixture(ExtensionProfile(key), key ? key : "", request);
}

uint64_t ReadActiveDownloadCount() {
  CheckThread();
  return State().running ? ActiveDownloadCount() : 0;
}

void RequestCancelAllDownloads() {
  CheckThread();
  if (State().running) CancelAllDownloads();
}

void RequestClose(uint64_t id, uint64_t request) {
  auto* page = Find(id);
  if (page) page->RequestClose(request);
  else if (State().callbacks.close_decided)
    State().callbacks.close_decided(State().callbacks.context, request, true);
}

int HistoryCount(uint64_t id) {
  auto* page = Find(id);
  return page ? page->contents()->GetController().GetEntryCount() : 0;
}

int HistoryEntry(uint64_t id, int index, const char** url, const char** title, bool* current) {
  auto* page = Find(id);
  if (!page) return -1;
  auto& controller = page->contents()->GetController();
  if (index < 0 || index >= controller.GetEntryCount()) return -1;
  auto* entry = controller.GetEntryAtIndex(index);
  auto& entry_url = State().history_url;
  auto& entry_title = State().history_title;
  entry_url = entry->GetURL().spec();
  entry_title = base::UTF16ToUTF8(entry->GetTitle());
  *url = entry_url.c_str();
  *title = entry_title.c_str();
  *current = index == controller.GetCurrentEntryIndex();
  return entry->GetUniqueID();
}

void GoToEntry(uint64_t id, int entry_id) {
  auto* page = Find(id);
  if (!page) return;
  auto& controller = page->contents()->GetController();
  for (int index = 0; index < controller.GetEntryCount(); ++index) {
    if (controller.GetEntryAtIndex(index)->GetUniqueID() == entry_id) { page->InvalidateClose(); controller.GoToIndex(index); return; }
  }
}

void DestroyPage(uint64_t id) {
  CheckThread();
  if (!State().adoption_scope.DeferDestroy(id)) State().pages.erase(id);
}

// ABI62 (DEV-1264, DEV-1073). Posted: the page used a ⌘ key. The app drops a
// report whose page closed or whose document generation moved on.
void ReportConsumedCommandKey(uint64_t id, PageCommandKey::Key key) {
  auto& state = State();
  if (!state.running || !state.callbacks.page_command_key || !Find(id)) return;
  state.callbacks.page_command_key(state.callbacks.context, id, key.generation, key.key_code,
                                   key.modifier_flags, key.timestamp, true);
}

uint64_t PageCloseGeneration(uint64_t id) {
  auto* page = Find(id);
  return page ? page->CloseGeneration() : 0;
}

void RequestAuthorizedClose(uint64_t id, uint64_t request, uint64_t generation) {
  auto* page = Find(id);
  if (page) page->RequestAuthorizedClose(request, generation);
  else Page::ReplyAuthorizedClose({}, id, request, ARX_CLOSE_STALE, 0);
}

ArxCloseStatus ConsumeAuthorizedClose(uint64_t id, uint64_t request, uint64_t token) {
  if (State().adoption_scope.Busy(id)) return ARX_CLOSE_BUSY;
  auto* page = Find(id);
  if (!page) return ARX_CLOSE_STALE;
  const auto status = page->ConsumeAuthorizedClose(request, token);
  // No posted work, Swift callback, or actor suspension between validation and destruction.
  if (status == ARX_CLOSE_SUCCESS) DestroyPage(id);
  return status;
}

void CancelAuthorizedClose(uint64_t id, uint64_t request) {
  auto* page = Find(id);
  if (page) page->CancelAuthorizedClose(request);
}

bool LinkContextIsCurrent(uint64_t id, uint64_t token) {
  CheckThread();
  auto* page = Find(id);
  return State().running && page && page->LinkContextIsCurrent(token);
}

// DEV-890, exported below as ArxEngineAppendLinkExtensionItems.
bool AppendLinkExtensionItems(uint64_t id, uint64_t token, NSMenu* menu) {
  CheckThread();
  auto* page = Find(id);
  return State().running && page && page->AppendLinkExtensionItems(token, menu);
}

void DismissLinkContext(uint64_t id, uint64_t token) {
  CheckThread();
  if (auto* page = Find(id)) page->DismissLinkContext(token);
}

void* PageView(uint64_t id) {
  auto* page = Find(id);
  return page ? (__bridge void*)page->contents()->GetNativeView().GetNativeNSView() : nullptr;
}

bool Navigate(uint64_t id, const char* url) {
  auto* page = Find(id);
  return page && url && page->Navigate(GURL(url));
}

void Back(uint64_t id) {
  auto* page = Find(id);
  if (page && page->contents()->GetController().CanGoBack()) {
    page->InvalidateClose();
    page->contents()->GetController().GoBack();
  }
}

void Forward(uint64_t id) {
  auto* page = Find(id);
  if (page && page->contents()->GetController().CanGoForward()) {
    page->InvalidateClose();
    page->contents()->GetController().GoForward();
  }
}

void Reload(uint64_t id) {
  auto* page = Find(id);
  if (page) {
    page->InvalidateClose();
    page->contents()->GetController().Reload(content::ReloadType::NORMAL, false);
  }
}

void ClearCacheAndReload(uint64_t id) {
  auto* page = Find(id);
  if (!page) return;
  page->InvalidateClose();
  auto* partition = page->contents()->GetBrowserContext()->GetDefaultStoragePartition();
  partition->GetNetworkContext()->ClearHttpCache(base::Time(), base::Time::Max(), nullptr,
      base::BindOnce([](uint64_t id) {
        auto* page = Find(id);
        if (page) page->contents()->GetController().Reload(content::ReloadType::BYPASSING_CACHE, false);
      }, id));
}

void ReloadBypassingCache(uint64_t id) {
  auto* page = Find(id);
  if (!page) return;
  page->InvalidateClose();
  page->contents()->GetController().Reload(content::ReloadType::BYPASSING_CACHE, true);
}

bool DevToolsAvailable() { return true; }

void ConfigurePageMenuTitles(const char* const* titles, size_t count) {
  CheckThread();
  ConfigurePageMenu(titles, count);
}

// ABI48 (DEV-814).
void ConfigureContextMenuTitles(const char* const* titles, size_t count) {
  CheckThread();
  ConfigureContextMenus(titles, count);
}

bool SavePage(uint64_t id, const char* path, ArxSavePageKind kind) {
  CheckThread();
  auto* page = Find(id);
  if (!page || !path || strnlen(path, 4097) > 4096) return false;
  return SavePageAs(page->contents(), base::FilePath(path), kind);
}

// ABI48 (DEV-828).
ArxExtensionActionRunStatus RunPageExtensionAction(uint64_t id, const char* extension_id,
                                                   double screen_x, double screen_y) {
  CheckThread();
  // DEV-956: a private page has an action host only while its opener shows extensions.
  auto* page = State().running ? Find(id) : nullptr;
  if (!page) return ARX_EXTENSION_ACTION_RUN_UNAVAILABLE;
  if (!extension_id || strnlen(extension_id, 33) != 32) return ARX_EXTENSION_ACTION_RUN_INVALID;
  return page->RunExtensionAction(extension_id, screen_x, screen_y);
}

// DEV-824 follow-up, exported as ArxEngineCopyExtensionActionIcon outside the
// ABI table: the PNG of the icon setIcon chose for an extension's action on
// this page, empty when it shows its default.
std::vector<uint8_t> PageExtensionActionIcon(uint64_t id, const char* extension_id, float scale) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  if (!page || !extension_id || strnlen(extension_id, 33) != 32) return {};
  return page->ExtensionActionIcon(extension_id, scale);
}

// ABI50 (DEV-857). Whether the page's last taken external link still has a
// current source; see Page::ExternalLinkIsCurrent.
bool ExternalLinkIsCurrent(uint64_t id, uint64_t token) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page && page->ExternalLinkIsCurrent(token);
}

// ABI48 (DEV-819). The committed main document's type; a PDF's MIME type is
// known from its response, before the viewer has loaded it.
// ABI54 (DEV-949).
bool ExitPageFullscreen(uint64_t id) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page && page->LeaveFullscreen();
}

ArxPageDocumentType PageDocumentType(uint64_t id) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  if (!page) return ARX_PAGE_DOCUMENT_NONE;
  auto* entry = page->contents()->GetController().GetLastCommittedEntry();
  if (!entry || entry->IsInitialEntry()) return ARX_PAGE_DOCUMENT_NONE;
  return page->contents()->GetContentsMimeType() == "application/pdf" ? ARX_PAGE_DOCUMENT_PDF
                                                                      : ARX_PAGE_DOCUMENT_WEB;
}

// ABI61 (DEV-1101). Chromium's colors for the primary page, which follow its
// document: a new document reports its own, or none.
bool ReadPageColors(uint64_t id, ArxPageColors* colors) {
  CheckThread();
  if (!colors) return false;
  *colors = {};
  auto* page = State().running ? Find(id) : nullptr;
  if (!page) return false;
  auto* contents = page->contents();
  if (const std::optional<SkColor> theme = contents->GetThemeColor()) {
    colors->theme_color = *theme;
    colors->has_theme_color = true;
  }
  if (const std::optional<SkColor> background = contents->GetBackgroundColor()) {
    colors->background_color = *background;
    colors->has_background_color = true;
  }
  return true;
}

void ConfigurePageDevTools(const char* window_title, const char* inspect_title, bool inspect_context) {
  CheckThread();
  const auto bounded = [](const char* text) {
    return text && strnlen(text, 257) <= 256 ? std::string(text) : std::string();
  };
  ConfigureDevTools(bounded(window_title), bounded(inspect_title), inspect_context);
}

ArxDevToolsStatus OpenPageDevTools(uint64_t id) {
  auto* page = Find(id);
  return page ? OpenDevTools(page->contents()) : ARX_DEVTOOLS_INVALID;
}

// ABI60 (DEV-1118), staged: the app shows the link status.
void ConfigureLinkHoverReports(bool enabled) {
  CheckThread();
  State().link_hover_reports = enabled;
}

// ABI56 (DEV-963) hosted site permission prompts.
void ConfigurePagePromptsHosted(bool hosted) {
  CheckThread();
  SetPagePromptsHosted(hosted);
}

bool CopyPagePermissionPrompt(uint64_t id, uint64_t token, const char** json, size_t* size) {
  CheckThread();
  static base::NoDestructor<std::string> borrowed;
  auto* page = State().running ? Find(id) : nullptr;
  if (!page || !json || !size ||
      !CopyHostedPagePermissionPrompt(page->contents(), token, borrowed.get())) return false;
  *json = borrowed->data();
  *size = borrowed->size();
  return true;
}

ArxPageDialogStatus AnswerPagePermissionPromptDecision(uint64_t id, uint64_t token,
                                                       ArxPagePermissionDecision decision,
                                                       ArxPagePermissionAccuracy accuracy) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  if (!page) return ARX_PAGE_DIALOG_STALE;
  return AnswerHostedPagePermissionPrompt(page->contents(), token, decision, accuracy);
}

bool DownloadPageLinkContext(uint64_t id, uint64_t token, uint64_t request) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page && page->DownloadLinkContext(token, request);
}

ArxDevToolsStatus InspectPageLinkContext(uint64_t id, uint64_t token) {
  auto* page = Find(id);
  return page ? page->InspectLinkContext(token) : ARX_DEVTOOLS_INVALID;
}

bool ClosePageDevTools(uint64_t id) {
  auto* page = Find(id);
  return page && CloseDevTools(page->contents());
}

bool PageDevToolsIsOpen(uint64_t id) {
  auto* page = Find(id);
  return page && DevToolsIsOpen(page->contents());
}

// ABI42 docked DevTools (DEV-733).
void DevToolsLayoutChanged(content::WebContents* inspected) {
  auto& state = State();
  if (!state.running || !state.callbacks.devtools_layout_changed) return;
  for (const auto& [id, page] : state.pages) {
    if (page->contents() != inspected) continue;
    state.callbacks.devtools_layout_changed(state.callbacks.context, id);
    return;
  }
}

bool PageDevToolsLayout(uint64_t id, ArxDevToolsLayout* layout) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page && ReadDevToolsLayout(page->contents(), layout);
}

ArxDevToolsStatus ShowPageDevToolsPanel(uint64_t id, const char* panel) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  if (!page || !panel) return ARX_DEVTOOLS_INVALID;
  return ShowDevToolsPanel(page->contents(), std::string(panel));
}

ArxDevToolsStatus StartPageDevToolsInspect(uint64_t id) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page ? StartDevToolsInspectMode(page->contents()) : ARX_DEVTOOLS_INVALID;
}

bool PageDevToolsLoaded(uint64_t id) {
  auto* page = Find(id);
  return page && DevToolsFrontendLoaded(page->contents());
}

void SetUnattended(bool unattended) {
  CheckThread();
  auto& state = State();
  if (state.started) return;  // Fixed for the runtime's lifetime.
  state.unattended = unattended;
}

uint64_t UnattendedDialogCount() {
  CheckThread();
  return State().unattended_dialogs;
}

uint64_t PageAuthenticationCancellations(uint64_t id) {
  auto* page = Find(id);
  return page ? page->authentication_cancellations() : 0;
}

uint32_t PageUserActionRequests(uint64_t id) {
  auto* page = Find(id);
  return page ? page->user_action_requests() : 0;
}

void PageFind(uint64_t id, const char* text, bool forward, bool new_session) {
  auto* page = Find(id);
  if (page && text) page->FindInPage(text, forward, new_session);
}

void PageStopFind(uint64_t id) {
  if (auto* page = Find(id)) page->StopFinding();
}

void PageFindStatus(uint64_t id, int32_t* matches, int32_t* active) {
  auto* page = Find(id);
  if (matches) *matches = page ? page->find_matches() : -1;
  if (active) *active = page ? page->find_active() : -1;
}

void SetUnattendedShutdown(uint32_t deadline_seconds, void (*expired)(void*, int), void* context) {
  CheckThread();
  auto& state = State();
  if (state.started || !deadline_seconds) return;  // Fixed for the runtime's lifetime.
  state.shutdown_deadline = std::min<uint32_t>(deadline_seconds, 600);
  state.shutdown_expired = expired;
  state.shutdown_context = context;
}

void SetExtensionTabPlacements(const ArxExtensionTabPlacement* placements, size_t count) {
  CheckThread();
  auto& state = State();
  if (!state.running || (count && !placements) || count > 4096) return;
  state.extension_placements.clear();
  state.extension_window_order.clear();
  for (size_t index = 0; index < count; ++index) {
    const auto& placement = placements[index];
    if (!placement.page || placement.window_number <= 0 || placement.index < 0 ||
        state.extension_placements.contains(placement.page)) continue;
    state.extension_placements.emplace(placement.page, ExtensionPlacement{
        placement.window_number, placement.index, placement.active, placement.highlighted});
    auto& order = state.extension_window_order;
    if (std::find(order.begin(), order.end(), placement.window_number) == order.end())
      order.push_back(placement.window_number);
  }
  // A window keeps its ID while it is open, even with no page for a while.
  auto& ids = state.extension_window_ids;
  for (auto it = ids.begin(); it != ids.end();)
    it = ExtensionNSWindow(it->first) ? std::next(it) : ids.erase(it);
  for (int64_t number : state.extension_window_order)
    if (!ids.contains(number) && ExtensionNSWindow(number))
      ids.emplace(number, SessionID::NewUnique());
}

void Stop(uint64_t id) {
  auto* page = Find(id);
  if (page) page->contents()->Stop();
}

void CapturePage(uint64_t id, uint64_t request, ArxCaptureLimits limits) {
  auto* page = Find(id);
  CaptureViewport(page ? page->contents() : nullptr, page ? page->document_id() : "",
      id, request, limits,
      [](uint64_t request, uint64_t page, ArxCaptureStatus status, const ArxCaptureSnapshot* snapshot) {
        auto& state = State();
        if (state.running && state.callbacks.capture_completed)
          state.callbacks.capture_completed(state.callbacks.context, request, page, status, snapshot);
      });
}

int PrivateMediaMetadataStatus(uint64_t id) {
  auto* page = Find(id);
  if (!page || !page->contents()->GetBrowserContext()->IsOffTheRecord()) return -1;
  auto* session = content::MediaSession::GetIfExists(page->contents());
  if (!session) return -1;
  auto info = session->GetMediaSessionInfoSync();
  return info ? (info->hide_metadata ? 1 : 0) : -1;
}

bool ObservePageMedia(uint64_t id) {
  auto* page = Find(id);
  return page && page->ObserveMedia();
}
void PerformPageMedia(uint64_t id, uint64_t request, uint64_t generation,
                      uint64_t revision, ArxMediaAction action) {
  auto* page = Find(id);
  if (page && page->media()) { page->media()->Perform(request, generation, revision, action); return; }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
      base::BindOnce([](uint64_t request, uint64_t id) {
        auto& state = State();
        if (state.running && state.callbacks.media_completed)
          state.callbacks.media_completed(state.callbacks.context, request, id, ARX_MEDIA_UNAVAILABLE);
      }, request, id));
}
bool MediaSourceIsCurrent(uint64_t id, uint64_t generation) {
  auto* page = Find(id);  // UI thread, running runtime, and live page registry.
  return page && !page->contents()->GetBrowserContext()->IsOffTheRecord() &&
      page->media() && page->media()->IsCurrent(generation);
}
void SeekPageMedia(uint64_t id, uint64_t request, uint64_t generation,
                   uint64_t revision, double seconds) {
  auto* page = Find(id);
  if (page && page->media()) { page->media()->Seek(request, generation, revision, seconds); return; }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
      base::BindOnce([](uint64_t request, uint64_t id) {
        auto& state = State();
        if (state.running && state.callbacks.media_completed)
          state.callbacks.media_completed(state.callbacks.context, request, id, ARX_MEDIA_UNAVAILABLE);
      }, request, id));
}
// Only ordinary pages with an enabled media observer; private pages never have one.
bool ReadPageMediaPosition(uint64_t id, ArxMediaPosition* position) {
  auto* page = Find(id);
  if (!position || !page || !page->media() ||
      page->contents()->GetBrowserContext()->IsOffTheRecord())
    return false;
  page->media()->Position(position);
  return true;
}
bool SetPageAudioMuted(uint64_t id, bool muted) {
  auto* page = Find(id);
  if (!page || !page->media() || page->contents()->GetBrowserContext()->IsOffTheRecord())
    return false;
  page->contents()->SetAudioMuted(muted);
  return page->contents()->IsAudioMuted() == muted;
}
// DEV-800 per-tab volume, exported as ArxEngineSetPageAudioVolume outside the
// ABI table so the app still runs on engines built before it. Main thread,
// ordinary observed pages only; the volume scales local playout in the audio
// service on top of each player's own, and lasts while the page lives.
bool SetPageAudioVolume(uint64_t id, double volume) {
  CheckThread();
  auto* page = Find(id);
  if (!page || !page->media() || page->contents()->GetBrowserContext()->IsOffTheRecord() ||
      !std::isfinite(volume) || volume < 0 || volume > 1)
    return false;
  page->contents()->SetAudioVolume(volume);
  return page->contents()->GetAudioVolume() == volume;
}
// DEV-1293, exported as ArxEngineSetPageSharedHistory outside the ABI table.
bool SetPageSharedHistory(uint64_t id, bool back, bool forward) {
  CheckThread();
  auto* page = Find(id);
  if (!page) return false;
  auto* gestures = gestures::Controller::FromWebContents(page->contents());
  if (!gestures) return false;
  gestures->SetSharedHistory(back, forward);
  return true;
}
// DEV-1020 dark pages, exported as ArxEngineSetPageDarkPages outside the ABI
// table. Page 0 is the default for later pages; any other id an Arx page,
// ordinary or private.
bool SetPageDarkPagesForApp(uint64_t id,
                            bool enabled,
                            const char* const* off_sites,
                            size_t count) {
  CheckThread();
  if (count > 4096 || (count > 0 && !off_sites)) return false;
  if (id == 0) {
    SetDefaultDarkPages(enabled);
    return true;
  }
  auto* page = Find(id);
  if (!page) return false;
  std::vector<std::string> sites;
  sites.reserve(count);
  for (size_t index = 0; index < count; ++index) {
    if (off_sites[index] && *off_sites[index]) sites.emplace_back(off_sites[index]);
  }
  SetDarkPages(page->contents(), enabled, std::move(sites));
  return true;
}
// DEV-873 tab unloading, exported as ArxEngineUnloadPage, ArxEnginePageIsUnloaded
// and ArxEngineRestoreUnloadedPage outside the ABI table, so the app still runs
// on engines built before it. Main thread; see page_unload_bridge.h.
int32_t UnloadPageForApp(uint64_t id, uint32_t reason, uint32_t* blockers) {
  CheckThread();
  if (blockers) *blockers = 0;
  auto* page = State().running ? Find(id) : nullptr;
  if (!page || State().adoption_scope.DestroyRequested(id) ||
      (reason != kPageUnloadInactive && reason != kPageUnloadMemoryPressure &&
       reason != kPageUnloadWindowClosed))
    return kPageUnloadUnavailable;
  return UnloadPage(page->contents(), static_cast<PageUnloadReason>(reason), blockers);
}
bool PageIsUnloadedForApp(uint64_t id) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page && PageIsUnloaded(page->contents());
}
bool RestoreUnloadedPageForApp(uint64_t id) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page && RestoreUnloadedPage(page->contents());
}
// DEV-1128, exported as ArxEngineEndPictureInPicture outside the ABI table.
bool EndPictureInPictureForApp(uint64_t id) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page && !State().adoption_scope.DestroyRequested(id) &&
      EndPagePictureInPicture(page->contents());
}
// DEV-898 Task Manager, exported outside the ABI table. Live renderer
// processes only; the app samples their memory and CPU itself and finds the
// browser, GPU and utility processes among its own children.
size_t CopyProcesses(ArxEngineProcess* entries, size_t capacity) {
  CheckThread();
  if (!State().running) return 0;
  size_t count = 0;
  auto add = [&](const ArxEngineProcess& entry) {
    if (entries && count < capacity) entries[count] = entry;
    ++count;
  };
  for (const auto& [id, page] : State().pages) {
    content::WebContents* contents = page ? page->contents() : nullptr;
    if (!contents) continue;
    // Site-isolated iframes run in their own renderers: each of the page's
    // processes is listed once for it.
    std::set<int32_t> pids;
    contents->ForEachRenderFrameHost([&](content::RenderFrameHost* frame) {
      content::RenderProcessHost* host = frame ? frame->GetProcess() : nullptr;
      if (!host || !host->IsInitializedAndNotDead() || !host->GetProcess().IsValid()) return;
      const int32_t pid = host->GetProcess().Pid();
      if (!pids.insert(pid).second) return;
      ArxEngineProcess entry{};
      entry.pid = pid;
      entry.kind = ARX_ENGINE_PROCESS_PAGE;
      entry.page = id;
      entry.is_private = contents->GetBrowserContext()->IsOffTheRecord();
      add(entry);
    });
  }
  for (auto it = content::RenderProcessHost::AllHostsIterator(); !it.IsAtEnd(); it.Advance()) {
    content::RenderProcessHost* host = it.GetCurrentValue();
    if (!host || !host->IsInitializedAndNotDead() || !host->GetProcess().IsValid()) continue;
    auto* map = extensions::ProcessMap::Get(host->GetBrowserContext());
    const std::optional<extensions::ExtensionId> extension =
        map ? map->GetExtensionIdForProcess(host->GetID()) : std::nullopt;
    if (!extension || extension->size() >= sizeof(ArxEngineProcess::extension_id)) continue;
    ArxEngineProcess entry{};
    entry.pid = host->GetProcess().Pid();
    entry.kind = ARX_ENGINE_PROCESS_EXTENSION;
    entry.is_private = host->GetBrowserContext()->IsOffTheRecord();
    std::memcpy(entry.extension_id, extension->data(), extension->size());
    add(entry);
  }
  return count;
}
bool EndProcess(int32_t pid) {
  CheckThread();
  if (!State().running || pid <= 0) return false;
  for (auto it = content::RenderProcessHost::AllHostsIterator(); !it.IsAtEnd(); it.Advance()) {
    content::RenderProcessHost* host = it.GetCurrentValue();
    if (!host || !host->IsInitializedAndNotDead() || !host->GetProcess().IsValid() ||
        host->GetProcess().Pid() != pid)
      continue;
    return host->Shutdown(content::RESULT_CODE_KILLED);
  }
  return false;
}
// ABI41 page zoom (DEV-726). Ordinary and private pages alike.
double ReadPageZoom(uint64_t id, double* default_factor) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return PageZoomFactor(page ? page->contents() : nullptr, default_factor);
}
bool ChangePageZoom(uint64_t id, double factor) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return SetPageZoomFactor(page ? page->contents() : nullptr, factor);
}
void CancelPageMedia(uint64_t request) {
  CheckThread();
  for (const auto& [id, page] : State().pages)
    if (page->media()) page->media()->Cancel(request);
}

bool DocumentCaptureAvailable() { return true; }
void CapturePageDocument(uint64_t id, uint64_t request, ArxCaptureLimits limits) {
  CheckThread();
  auto* page = Find(id);
  if (!DocumentCaptureAvailable()) {
    auto& state = State();
    if (state.running && state.callbacks.document_capture_completed)
      state.callbacks.document_capture_completed(state.callbacks.context, request, id,
          ARX_CAPTURE_UNAVAILABLE, nullptr);
    return;
  }
  CaptureDocument(page ? page->contents() : nullptr, page ? page->document_id() : "", id, request, limits,
      [](uint64_t request, uint64_t page, ArxCaptureStatus status, const ArxDocumentCaptureSnapshot* snapshot) {
        auto& state = State();
        if (state.running && state.callbacks.document_capture_completed)
          state.callbacks.document_capture_completed(state.callbacks.context, request, page, status, snapshot);
      });
}
void CancelPageDocumentCapture(uint64_t request) {
  CheckThread();
  if (State().running) CancelDocumentCapture(request);
}

void RunDocumentCaptureFixture(uint64_t id, uint64_t request, const char* origin) {
  CheckThread();
  auto& state = State();
  auto* page = Find(id);
  const bool bounded_origin = origin && strnlen(origin, 129) <= 128;
  const GURL url(bounded_origin ? origin : "");
  if (!state.running || !state.document_fixture_enabled || state.document_fixture_started || !page ||
      !bounded_origin || !url.is_valid() || !url.SchemeIs("http") ||
      url.host() != "127.0.0.1" || !url.has_port() || url.EffectiveIntPort() <= 0 ||
      url.has_username() || url.has_password() ||
      url.has_query() || url.has_ref() || url.path() != "/") {
    if (state.running && state.callbacks.document_capture_fixture_completed)
      state.callbacks.document_capture_fixture_completed(state.callbacks.context, request, false);
    return;
  }
  state.document_fixture_started = true;
  state.document_fixture = std::make_unique<document::testing::OwnedCaptureFixture>(page->contents(), url,
      base::BindOnce([](uint64_t request, bool success) {
        auto& state = State();
        if (state.running && state.callbacks.document_capture_fixture_completed)
          state.callbacks.document_capture_fixture_completed(state.callbacks.context, request, success);
        // The completion runs within the controller's Finish stack.
        base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
            base::BindOnce([] { State().document_fixture.reset(); }));
      }, request));
  state.document_fixture->Start();
}

void CapturePageOffscreen(uint64_t id, uint64_t request, ArxCaptureLimits limits) {
  CheckThread();
  auto* page = Find(id);
  CaptureOffscreen(page ? page->contents() : nullptr, page ? page->document_id() : "",
      id, request, limits,
      [](uint64_t request, uint64_t page, ArxCaptureStatus status, const ArxCaptureSnapshot* snapshot) {
        auto& state = State();
        if (state.running && state.callbacks.capture_completed)
          state.callbacks.capture_completed(state.callbacks.context, request, page, status, snapshot);
      });
}

void RequestPagePdf(uint64_t id, uint64_t request, ArxPdfKind kind, ArxPdfOptions options,
                    uint32_t maximum_bytes, uint32_t timeout_ms) {
  CheckThread();
  auto* page = Find(id);
  RequestPdf(page ? page->contents() : nullptr, page ? page->document_id() : "", id, request,
      kind, options, maximum_bytes, timeout_ms,
      [](uint64_t request, uint64_t page, ArxPdfStatus status, const char* document,
         const uint8_t* bytes, size_t size) {
        auto& state = State();
        if (state.running && state.callbacks.pdf_completed)
          state.callbacks.pdf_completed(state.callbacks.context, request, page, status,
                                        document, bytes, size);
      });
}

bool PageDialogInfo(uint64_t id, ArxPageDialog* dialog) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page && dialog && page->Dialog(dialog);
}

ArxPageDialogStatus AnswerPageDialog(uint64_t id, uint64_t token, bool accept,
                                     const char* prompt_text) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  if (!page) return ARX_PAGE_DIALOG_STALE;
  return page->AnswerDialog(token, accept, prompt_text);
}

bool PageFileChooserInfo(uint64_t page, ArxFileChooserInfo* info) {
  CheckThread();
  return State().running && Find(page) && PageFileChooser(page, info);
}

ArxFileChooserStatus AnswerPageFileChooser(uint64_t page, uint64_t token,
                                           const char* const* paths, size_t count) {
  CheckThread();
  if (!State().running || !Find(page)) return ARX_FILE_CHOOSER_STALE;
  return AnswerFileChooser(page, token, paths, count);
}

void CancelPagePdf(uint64_t request) {
  CheckThread();
  if (State().running) CancelPdf(request);
}

// ABI34 developer tier (DEV-668). Replies go through developer_completed.
void DeveloperCompleted(uint64_t request, uint64_t page, ArxDeveloperStatus status,
                        const uint8_t* json, size_t size) {
  auto& state = State();
  if (state.running && state.callbacks.developer_completed)
    state.callbacks.developer_completed(state.callbacks.context, request, page, status, json, size);
}

void FocusedLinkCompleted(uint64_t request, uint64_t page, uint64_t generation, const char* url,
                          size_t url_size) {
  auto& state = State();
  if (state.running && state.callbacks.focused_link_completed)
    state.callbacks.focused_link_completed(state.callbacks.context, request, page, generation, url,
                                           url_size);
}

// ABI37. Replies once through focused_link_completed, never synchronously.
void RequestPageFocusedLink(uint64_t id, uint64_t request) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  RequestFocusedLink(page ? page->contents() : nullptr, id, request,
                     page ? page->CloseGeneration() : 0, FocusedLinkCompleted);
}

void EvaluatePageScript(uint64_t id, uint64_t request, const char* source,
                        uint32_t maximum_bytes, uint32_t timeout_ms) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  EvaluateDeveloperScript(page ? page->contents() : nullptr, id, request, source, maximum_bytes,
                          timeout_ms, DeveloperCompleted);
}

// ABI57 (DEV-996). The app's translation scripts; replies through developer_completed.
void EvaluatePageTranslationScript(uint64_t id, uint64_t request, const char* source,
                                   uint32_t maximum_bytes, uint32_t timeout_ms) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  EvaluateTranslationScript(page ? page->contents() : nullptr, id, request, source,
                            maximum_bytes, timeout_ms, DeveloperCompleted);
}

// DEV-924 request details, exported outside the ABI table.
bool SetPageNetworkCapture(uint64_t id, bool enabled) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  if (!page) {
    if (!enabled) ForgetNetworkCapture(id);
    return !enabled;
  }
  const bool done = SetNetworkCapture(page->contents(), id, enabled);
  // DEV-1009: the capture's DevTools client hides hangs from Chromium.
  if (done) page->SetHangWatch(enabled);
  return done;
}

// ABI58 (DEV-1009).
uint32_t PageUnresponsive(uint64_t id) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page ? page->Unresponsive() : 0;
}

bool WaitForPage(uint64_t id) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page && page->WaitForResponse();
}

bool EndPageRenderer(uint64_t id) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page && page->EndRenderer();
}

// Replies through developer_completed, never synchronously.
// ABI59 (DEV-1065).
uint64_t PageMainDocument(uint64_t id) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page ? page->MainDocuments() : 0;
}

void PingPageRenderer(uint64_t id, uint64_t request, uint32_t timeout_ms) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  // A held page is reported unavailable: it isn't hung.
  PingPage(page && !page->Held() ? page->contents() : nullptr, id, request, timeout_ms,
           page ? page->HeldCheck() : base::RepeatingCallback<bool()>(), DeveloperCompleted);
}

// ABI58 (DEV-1016).
bool CopyPageRendererEnd(uint64_t id, ArxRendererEnd* end) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  return page && page->RendererEnd(end);
}

static_assert(ARX_RENDERER_END_NORMAL == base::TERMINATION_STATUS_NORMAL_TERMINATION &&
                  ARX_RENDERER_END_ABNORMAL == base::TERMINATION_STATUS_ABNORMAL_TERMINATION &&
                  ARX_RENDERER_END_KILLED == base::TERMINATION_STATUS_PROCESS_WAS_KILLED &&
                  ARX_RENDERER_END_CRASHED == base::TERMINATION_STATUS_PROCESS_CRASHED &&
                  ARX_RENDERER_END_LAUNCH_FAILED == base::TERMINATION_STATUS_LAUNCH_FAILED &&
                  ARX_RENDERER_END_OUT_OF_MEMORY == base::TERMINATION_STATUS_OOM,
              "ArxRendererEnd statuses are base::TerminationStatus");

bool SetPageDeveloperLog(uint64_t id, bool enabled) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  if (!page) {
    if (!enabled) ForgetDeveloperPage(id);
    return !enabled;
  }
  return SetDeveloperLog(page->contents(), id, enabled);
}

void ReadPageDeveloperLog(uint64_t id, uint64_t request, ArxDeveloperLogKind kind,
                          uint64_t after, uint32_t limit) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  ReadDeveloperLog(page ? page->contents() : nullptr, id, request, kind, after, limit,
                   DeveloperCompleted);
}

void CancelPageDeveloper(uint64_t request) {
  CheckThread();
  if (State().running) CancelDeveloperRequest(request);
}

// ABI35 saved passwords (DEV-708).
void PasswordSaveOffered(uint64_t page, uint64_t token, const char* origin, const char* username,
                         bool update) {
  auto& state = State();
  if (state.running && state.callbacks.password_save_offered)
    state.callbacks.password_save_offered(state.callbacks.context, page, token, origin, username,
                                          update);
}

void SignInCompleted(uint64_t request, uint64_t page, ArxSignInStatus status,
                     const uint8_t* json, size_t size) {
  auto& state = State();
  if (state.running && state.callbacks.sign_in_completed)
    state.callbacks.sign_in_completed(state.callbacks.context, request, page, status, json, size);
}

bool AnswerPagePasswordSave(uint64_t id, uint64_t token, ArxPasswordSaveAnswer answer) {
  CheckThread();
  return State().running && AnswerPasswordSave(id, token, answer);
}

void RequestPageSignInCredentials(uint64_t id, uint64_t request) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  RequestSignInCredentials(page ? page->contents() : nullptr, id, request);
}

// ABI36 saved passwords in Settings (DEV-721). Ordinary profiles only.
void SavedPasswordsCompleted(uint64_t request, ArxSavedPasswordsStatus status,
                             const uint8_t* json, size_t size) {
  auto& state = State();
  if (state.running && state.callbacks.saved_passwords_completed)
    state.callbacks.saved_passwords_completed(state.callbacks.context, request, status, json, size);
}

void RequestSavedPasswords(uint64_t request, const char* key) {
  CheckThread();
  ListSavedPasswords(ExtensionProfile(key), request);
}

void RequestSaveSavedPassword(uint64_t request, const char* key, const char* listing,
                              uint32_t credential, const char* url, const char* username,
                              void* password_field) {
  CheckThread();
  SaveSavedPassword(ExtensionProfile(key), request, listing, credential, url, username,
                    password_field);
}

void RequestRemoveSavedPassword(uint64_t request, const char* key, const char* listing,
                                uint32_t credential) {
  CheckThread();
  RemoveSavedPassword(ExtensionProfile(key), request, listing, credential);
}

void RequestRevealSavedPassword(uint64_t request, const char* key, const char* listing,
                                uint32_t credential, ArxPasswordReveal mode, const char* reason,
                                void* field) {
  CheckThread();
  RevealSavedPassword(ExtensionProfile(key), request, listing, credential, mode, reason, field);
}

void RequestImportSavedPasswords(uint64_t request, const char* key, const char* path) {
  CheckThread();
  ImportSavedPasswords(ExtensionProfile(key), request, path);
}

void CancelSavedPasswordRequest(uint64_t request) {
  CheckThread();
  CancelSavedPasswords(request);
}

// ABI46 credential migration (DEV-830). Ordinary profiles only.
void CredentialImportCompleted(uint64_t request, ArxCredentialImportStatus status,
                               const uint8_t* json, size_t size) {
  auto& state = State();
  if (state.running && state.callbacks.credential_import_completed)
    state.callbacks.credential_import_completed(state.callbacks.context, request, status, json,
                                                size);
}

void RequestImportPasswordRecords(uint64_t request, const char* key,
                                  const ArxImportedPassword* records, size_t count) {
  CheckThread();
  ImportPasswordRecords(request, key, records, count);
}

void RequestImportCookies(uint64_t request, const char* key, const ArxImportedCookie* cookies,
                          size_t count) {
  CheckThread();
  ImportCookies(request, key, cookies, count);
}

void RequestCheckCookies(uint64_t request, const char* key, const char* keys) {
  CheckThread();
  CheckCookies(request, key, keys);
}

void RequestUndoCredentialImport(uint64_t request, const char* key, const char* keys) {
  CheckThread();
  UndoCredentialImport(request, key, keys);
}

// ABI38 site permissions and zoom in Settings (DEV-716). Ordinary profiles only.
void SiteSettingsCompleted(uint64_t request, ArxSiteSettingsStatus status, const uint8_t* json,
                           size_t size) {
  auto& state = State();
  if (state.running && state.callbacks.site_settings_completed)
    state.callbacks.site_settings_completed(state.callbacks.context, request, status, json, size);
}

void SiteSettingsChangedForProfile(const char* profile_key) {
  auto& state = State();
  if (state.running && state.callbacks.site_settings_changed)
    state.callbacks.site_settings_changed(state.callbacks.context, profile_key);
}

void RequestSiteSettings(uint64_t request, const char* key) {
  CheckThread();
  ListSiteSettings(ExtensionProfile(key), key, request);
}

void RequestSetSitePermission(uint64_t request, const char* key, const char* origin,
                              ArxSitePermission permission, ArxSitePermissionSetting setting) {
  CheckThread();
  SetSitePermission(ExtensionProfile(key), key, request, origin, permission, setting);
}

// ABI39 clear browsing data and the downloads location (DEV-647). Ordinary profiles only.
void ProfileDataCompleted(uint64_t request, ArxProfileDataStatus status, const uint8_t* json,
                          size_t size) {
  auto& state = State();
  if (state.running && state.callbacks.profile_data_completed)
    state.callbacks.profile_data_completed(state.callbacks.context, request, status, json, size);
}

void RequestCountBrowsingData(uint64_t request, const char* key, uint32_t kinds, double since) {
  CheckThread();
  CountBrowsingData(ExtensionProfile(key), request, kinds, since);
}

void RequestClearBrowsingData(uint64_t request, const char* key, uint32_t kinds, double since) {
  CheckThread();
  ClearBrowsingData(ExtensionProfile(key), request, kinds, since);
}

void RequestDownloadSettings(uint64_t request, const char* key) {
  CheckThread();
  ReadDownloadSettings(ExtensionProfile(key), request);
}

void RequestSetDownloadSettings(uint64_t request, const char* key, const char* directory,
                                bool ask) {
  CheckThread();
  SetDownloadSettings(ExtensionProfile(key), request, directory, ask);
}

// ABI40 the site menu's Clear Cache and Clear Cookies (DEV-633).
void RequestSiteDataScope(uint64_t request, const char* key, const char* url) {
  CheckThread();
  SiteDataScope(ExtensionProfile(key), request, url);
}

void RequestClearSiteData(uint64_t request, const char* key, const char* url, uint32_t kinds) {
  CheckThread();
  ClearSiteData(ExtensionProfile(key), request, url, kinds);
}

void RequestSetSiteZoom(uint64_t request, const char* key, const char* host, double factor) {
  CheckThread();
  SetSiteZoom(ExtensionProfile(key), key, request, host, factor);
}

void RequestPageSignIn(uint64_t id, uint64_t request, const char* document, const char* frame,
                       uint32_t credential, uint32_t timeout_ms) {
  CheckThread();
  auto* page = State().running ? Find(id) : nullptr;
  AttemptSignIn(page ? page->contents() : nullptr, id, request, document, frame, credential,
                timeout_ms);
}

void CancelPageSignIn(uint64_t request) {
  CheckThread();
  if (State().running) CancelSignIn(request);
}

// ABI52 autofill (DEV-875, DEV-893).
void AutofillSuggestionsChanged(uint64_t page, uint64_t session, const uint8_t* json,
                                size_t size) {
  auto& state = State();
  if (state.running && state.callbacks.autofill_suggestions_changed)
    state.callbacks.autofill_suggestions_changed(state.callbacks.context, page, session, json,
                                                 size);
}

bool AcceptPageAutofillSuggestion(uint64_t page, uint64_t session, uint32_t index) {
  CheckThread();
  return State().running && AcceptAutofillSuggestion(page, session, index);
}

void SelectPageAutofillSuggestion(uint64_t page, uint64_t session, int32_t index) {
  CheckThread();
  if (State().running) SelectAutofillSuggestion(page, session, index);
}

void DismissPageAutofillSuggestions(uint64_t page, uint64_t session) {
  CheckThread();
  if (State().running) DismissAutofillSuggestions(page, session);
}

void AutofillDataCompleted(uint64_t request, ArxAutofillDataStatus status, const uint8_t* json,
                           size_t size) {
  auto& state = State();
  if (state.running && state.callbacks.autofill_data_completed)
    state.callbacks.autofill_data_completed(state.callbacks.context, request, status, json, size);
}

// May be set before run; applied to ordinary profiles as their pages open.
void ConfigureAutofillProducts(bool addresses, bool cards) {
  CheckThread();
  SetAutofillProducts(addresses, cards);
}

void RequestAutofillData(const char* key, uint64_t request) {
  CheckThread();
  ListAutofillData(ExtensionProfile(key), request);
}

void RequestSaveAutofillAddress(const char* key, uint64_t request, const char* json) {
  CheckThread();
  SaveAutofillAddress(ExtensionProfile(key), request, json);
}

void RequestSaveAutofillCard(const char* key, uint64_t request, const char* json,
                             void* number_field) {
  CheckThread();
  SaveAutofillCard(ExtensionProfile(key), request, json, number_field);
}

void RequestRemoveAutofillData(const char* key, uint64_t request, const char* id) {
  CheckThread();
  RemoveAutofillData(ExtensionProfile(key), request, id);
}

void CancelAutofillDataRequest(uint64_t request) {
  CheckThread();
  CancelAutofillData(request);
}

// May be set before run; the setting lives in the bridge, not the runtime.
void ConfigureAutofillAuthentication(ArxAutofillAuthentication mode, const char* password_reason,
                                     const char* card_reason) {
  CheckThread();
  SetAutofillAuthentication(mode, password_reason, card_reason);
}

void CancelPageCapture(uint64_t request) {
  CheckThread();
  if (State().running) CancelCapture(request);
}

void RunGestureFixture(uint64_t id, uint64_t request, const char* loopback_origin) {
  auto* page = Find(id);
  auto completed = base::BindOnce([](uint64_t request, bool success) {
    auto& state = State();
    if (state.running && state.callbacks.gesture_fixture_completed)
      state.callbacks.gesture_fixture_completed(state.callbacks.context, request, success);
  }, request);
  if (!State().gesture_fixture || !request || !page ||
      page->contents()->GetBrowserContext()->IsOffTheRecord()) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(std::move(completed), false));
    return;
  }
  gestures::RunFixture(page->contents(), GURL(loopback_origin ? loopback_origin : ""),
                       std::move(completed));
}

}  // namespace

bool PrivateExtensionContextIsCurrent(content::BrowserContext* context) {
  return context && context->IsOffTheRecord() &&
      ExtensionActionsProfileIsCurrent(Profile::FromBrowserContext(context));
}

// DEV-907. The app's handler for Badging API reports, set through the
// additive export below. Outside the anonymous namespace: engine_bridge.h
// declares PageBadgeChanged for badge_manager.cc.
struct PageBadgeObserver {
  void (*handler)(void* context, uint64_t page, int32_t kind, uint64_t count) = nullptr;
  void* context = nullptr;
};

PageBadgeObserver& BadgeObserver() {
  // Trivially destructible, so a plain function-local static (NoDestructor refuses it).
  static PageBadgeObserver observer;
  return observer;
}

void PageBadgeChanged(content::WebContents* contents, bool set, uint64_t count, bool flag) {
  CheckThread();
  auto& observer = BadgeObserver();
  if (!observer.handler || !contents) return;
  uint64_t page = PageIdentifier(contents);
  if (!page) return;
  // 0 clears, 1 is a badge without a number, 2 a count.
  int32_t kind = !set ? 0 : flag ? 1 : 2;
  observer.handler(observer.context, page, kind, kind == 2 ? count : 0);
}

void CapturePopupSource(content::RenderFrameHost* opener) {
  if (!opener) return;
  auto* contents = content::WebContents::FromRenderFrameHost(opener);
  for (const auto& [id, page] : State().pages)
    if (page->contents() == contents) { page->CapturePopupSource(opener); return; }
}

bool NavigateBlockedPopup(NavigateParams* params) {
  for (const auto& [id, page] : State().pages)
    if (page->contents() == params->source_contents) return page->OwnsBlockedPopupNavigation(params);
  return false;
}

bool HandleLinkForceClick(content::WebContents* contents) {
  CheckThread();
  if (!contents) return false;
  for (const auto& [id, page] : State().pages)
    if (page->contents() == contents) return page->ForceClickHoveredLink();
  return false;
}

bool AsksForCrossSiteLinks(content::WebContents* contents) {
  CheckThread();
  auto& state = State();
  if (!contents || !state.running || !state.callbacks.cross_site_link_requested ||
      contents->GetBrowserContext()->IsOffTheRecord()) return false;
  for (const auto& [id, page] : state.pages)
    if (page->contents() == contents) return true;
  return false;
}

bool OfferCrossSiteLink(content::WebContents* contents, const GURL& url, int64_t navigation_id) {
  CheckThread();
  if (!contents) return false;
  for (const auto& [id, page] : State().pages)
    if (page->contents() == contents) return page->OfferCrossSiteLink(url, navigation_id);
  return false;
}

bool OffersExternalLinks(content::WebContents* contents) {
  CheckThread();
  auto& state = State();
  if (!contents || !state.running || !state.callbacks.external_link_requested) return false;
  for (const auto& [id, page] : state.pages)
    if (page->contents() == contents) return true;
  return false;
}

void OfferExternalLink(content::WebContents* contents, const GURL& url,
                       const std::optional<url::Origin>& source_origin,
                       ui::PageTransition transition, bool has_user_gesture,
                       base::RepeatingCallback<bool()> source_guard,
                       base::OnceClosure chrome_path) {
  CheckThread();
  if (contents) {
    for (const auto& [id, page] : State().pages) {
      if (page->contents() == contents) {
        page->OfferExternalLink(url, source_origin, transition, has_user_gesture,
                                std::move(source_guard), std::move(chrome_path));
        return;
      }
    }
  }
  std::move(chrome_path).Run();
}

// ---- ABI55 (DEV-885) web notifications; see notification_bridge.h ----
bool RefusesWebNotifications() {
  CheckThread();
  return State().started && State().unattended;
}

base::OnceClosure WrapNotificationClick(Profile* profile, bool persistent,
                                        const GURL& origin,
                                        base::OnceClosure completed) {
  CheckThread();
  auto& state = State();
  const auto key = OrdinaryProfileKey(profile);
  if (!state.running || !state.callbacks.notification_clicked || !key ||
      !origin.SchemeIsHTTPOrHTTPS()) return completed;
  auto& clicks = NotificationClicks();
  // A click whose completion never ran (a worker that never settled) stops
  // counting; the newest clicks are kept.
  const auto now = base::TimeTicks::Now();
  std::erase_if(clicks, [now](const NotificationClick& click) {
    return now - click.started > 3 * kNotificationClickWindow;
  });
  if (clicks.size() >= kNotificationClicksLimit) clicks.erase(clicks.begin());
  static uint64_t next_click = 0;
  const uint64_t id = ++next_click;
  NotificationClick click;
  click.id = id;
  click.profile_key = *key;
  click.origin = url::Origin::Create(origin);
  click.persistent = persistent;
  click.started = now;
  clicks.push_back(std::move(click));
  return base::BindOnce([](uint64_t id, base::OnceClosure completed) {
    if (completed) std::move(completed).Run();
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
        base::BindOnce(&ReportNotificationClick, id), kNotificationClickSettle);
  }, id, std::move(completed));
}

bool TakeNotificationOrigin(Profile* profile, const GURL& origin) {
  CheckThread();
  if (!State().started) return false;
  if (const auto key = OrdinaryProfileKey(profile)) {
    if (auto* click = ActiveNotificationClick(*key, url::Origin::Create(origin)))
      click->page_gone = true;
  }
  // Embedded, Chrome's Navigate() would open a Chrome browser window.
  return true;
}

bool OpenServiceWorkerWindow(
    content::BrowserContext* context,
    const content::OpenURLParams& params,
    base::OnceCallback<void(content::WebContents*)>& callback) {
  CheckThread();
  auto& state = State();
  if (!state.started) return false;
  Profile* profile = context ? Profile::FromBrowserContext(context) : nullptr;
  const auto key = OrdinaryProfileKey(profile);
  NotificationClick* click = key && params.initiator_origin
      ? ActiveNotificationClick(*key, *params.initiator_origin) : nullptr;
  const std::string target = params.url.spec();
  // A released profile (DEV-880) isn't held for a new page; the app opens the
  // site in it when the click ends instead.
  const bool held = key && (key->empty() || state.profiles.contains(*key));
  if (!state.running || !state.callbacks.notification_window_requested || !click || !held ||
      !params.is_service_worker_open_window || !AllowedURL(params.url) ||
      target.size() > 32768 || !state.next_page) {
    std::move(callback).Run(nullptr);
    return true;
  }
  const uint64_t click_id = click->id;
  const uint64_t id = state.next_page++;
  auto owned = std::make_unique<Page>(id, profile);
  // A tab like any other: its links and window.open() open new tabs.
  if (!owned->ConfigureContentHosting(true) || !owned->Navigate(params.url)) {
    std::move(callback).Run(nullptr);
    return true;
  }
  auto* exact = owned.get();
  state.pages.emplace(id, std::move(owned));
  const bool accepted = state.callbacks.notification_window_requested(
      state.callbacks.context, key->c_str(), id, target.c_str(), target.size());
  auto found = state.pages.find(id);
  if (!accepted || !state.running || found == state.pages.end() || found->second.get() != exact) {
    if (found != state.pages.end() && found->second.get() == exact) state.pages.erase(found);
    std::move(callback).Run(nullptr);
    return true;
  }
  for (auto& item : NotificationClicks())
    if (item.id == click_id) item.handled = true;
  exact->PublishNavigation();
  // Content activates the page next, which asks the app to show it.
  std::move(callback).Run(exact->contents());
  return true;
}
// ---- ABI55 (DEV-885) end ----

uint64_t PageIdentifier(content::WebContents* contents) {
  for (const auto& [id, page] : State().pages)
    if (page->contents() == contents) return id;
  return 0;
}

// ABI56 (DEV-963). Posted, so the app never reenters a prompt mid-change.
void PagePermissionPromptChanged(uint64_t page, uint64_t token) {
  if (!page) return;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
      base::BindOnce([](uint64_t page, uint64_t token) {
        auto& state = State();
        if (state.running && state.callbacks.page_permission_prompt_changed)
          state.callbacks.page_permission_prompt_changed(state.callbacks.context, page, token);
      }, page, token));
}

// DEV-877, DEV-927. The Arx page `page`'s contents, or null.
content::WebContents* PageContents(uint64_t page) {
  auto found = State().pages.find(page);
  return found == State().pages.end() ? nullptr : found->second->contents();
}

// DEV-1172. The identity of page `page`'s current document, or "".
std::string PageDocumentID(uint64_t page) {
  if (!State().running) return {};
  auto found = State().pages.find(page);
  return found == State().pages.end() ? std::string() : found->second->document_id();
}

// DEV-877. An ordinary profile Arx loaded ("" for the legacy one), or null.
Profile* LoadedOrdinaryProfile(const char* key) {
  return ExtensionProfile(key);
}

void ConsentActivityChanged(Profile* profile) {
  SchedulePrivateProfileRetirement(profile);
}

void DownloadActivityChanged(Profile* profile) {
  SchedulePrivateProfileRetirement(profile);
}

bool PageConsentRetainsProfile(const std::string& key) {
  auto* manager = g_browser_process->profile_manager();
  if (!manager) return true;
  const auto path = manager->user_data_dir().AppendASCII(key.empty() ? "Default" : "Arx-" + key);
  return HasPageConsentWorkForPath(path);
}

// DEV-880. Whether anything of Arx's still uses the ordinary profile `key`:
// its preparation, a page, a download, extension work or a request, a page's
// consent prompt, or a private window it opened (DEV-889). Retirement (ProfileErasureMayQueue) and idle release
// (ReleaseProfile) both require that nothing does.
bool OrdinaryProfileInUse(const std::string& key) {
  auto& state = State();
  const auto preparing = state.preparing_profiles.find(key);
  if (preparing != state.preparing_profiles.end() && preparing->second != 0) return true;
  if (HasExtensionInstallWork(key) || HasExtensionLoadWork(key) || HasExtensionViewWork(key) ||
      HasExtensionRequestWork(key) || PageConsentRetainsProfile(key)) return true;
  auto found = state.profiles.find(key);
  if (found == state.profiles.end()) return false;
  Profile* profile = found->second->profile();
  if (DownloadsRetainProfile(profile)) return true;
  // DEV-889: a private window's context is its opener's off-the-record child,
  // which Chromium destroys with the opener; a retired one may still be on
  // its way out (SchedulePrivateProfileRetirement).
  for (const auto& [private_key, private_profile] : state.private_profiles)
    if (private_profile->GetOriginalProfile() == profile) return true;
  for (const auto& [private_profile, retired] : state.retired_private_profiles)
    if (private_profile->GetOriginalProfile() == profile) return true;
  for (const auto& [id, page] : state.pages)
    if (page->contents()->GetBrowserContext() == profile) return true;
  return false;
}

bool ProfileErasureMayQueue(const std::string& key) {
  CheckThread();
  auto& state = State();
  if (!state.running || state.private_profiles.contains(key)) return false;
  return !OrdinaryProfileInUse(key);
}

// DEV-880. A profile Arx released, until Chromium destroys it.
class ReleasedProfile final : public ProfileObserver {
 public:
  ReleasedProfile(Profile* profile, std::string key) : profile_(profile), key_(std::move(key)) {
    observation_.Observe(profile);
  }

  const std::string& key() const { return key_; }
  Profile* profile() const { return profile_; }
  bool destroyed() const { return !profile_; }

  void OnProfileWillBeDestroyed(Profile*) override {
    observation_.Reset();
    profile_ = nullptr;
  }

 private:
  raw_ptr<Profile> profile_;
  std::string key_;
  base::ScopedObservation<Profile, ProfileObserver> observation_{this};
};

std::vector<std::unique_ptr<ReleasedProfile>>& ReleasedProfiles() {
  static base::NoDestructor<std::vector<std::unique_ptr<ReleasedProfile>>> value;
  std::erase_if(*value, [](const auto& item) { return item->destroyed(); });
  return *value;
}

// Chromium gives every new profile a kWaitingForFirstBrowserWindow keep-alive
// that only a Browser window's keep-alive clears (ProfileManager::AddKeepAlive).
// Arx never opens one, so a profile it loaded would never unload. Cleared while
// Arx's own keep-alive still holds the profile, so this alone unloads nothing.
void ClearInitialKeepAlive(Profile* profile) {
  if (auto* manager = g_browser_process->profile_manager())
    manager->ClearFirstBrowserWindowKeepAlive(profile);
}

std::set<base::FilePath>& SessionKeepingPaths() {
  static base::NoDestructor<std::set<base::FilePath>> value;
  return *value;
}

// An idle release doesn't end the profile's browsing session: when it loads
// again in this run, Chromium keeps its session cookies
// (ProfileImpl::ShouldRestoreOldSessionCookies, session_cookies_overlay.py).
void KeepSessionOnReload(Profile* profile) {
  SessionKeepingPaths().insert(profile->GetPath());
}

bool ProfileReloadKeepsSession(const base::FilePath& path) {
  return SessionKeepingPaths().contains(path);
}

// Watches the released profile until Chromium destroys it (ProfileIsLoaded).
void WatchReleasedProfile(Profile* profile, const std::string& key) {
  auto& released = ReleasedProfiles();
  for (const auto& item : released)
    if (item->profile() == profile) return;
  released.push_back(std::make_unique<ReleasedProfile>(profile, key));
}

// DEV-880, exported as ArxEngineReleaseProfile outside the ABI table. Lets an
// idle ordinary profile go: Arx forgets what it keeps for the profile and drops
// its keep-alive, and Chromium unloads the profile once nothing of its own
// holds it either (ProfileManager::RemoveKeepAlive, posted). A later
// PrepareProfile loads it again; CreateProfileAsync waits for a destruction
// still pending. False, changing nothing, while OrdinaryProfileInUse (a
// private window it opened included), for a profile that isn't loaded, and
// for Default when it's Chromium's startup profile and the fallback parent of
// private profiles (no erasure).
bool ReleaseProfile(const char* raw_key) {
  CheckThread();
  auto& state = State();
  if (!state.running || !raw_key) return false;
  const std::string key(raw_key);
  auto found = state.profiles.find(key);
  if (found == state.profiles.end() || state.private_profile_keys.contains(key) ||
      (key.empty() && !erasure::Enabled()) || OrdinaryProfileInUse(key)) return false;
  Profile* profile = found->second->profile();
  // Nothing may keep a raw pointer into a profile Chromium is about to unload.
  // Site settings, browsing data, site icons and private download links observe
  // the profile's destruction themselves.
  StopDownloads(profile);
  ForgetPasswordSettingsProfile(profile);
  ForgetExtensionProfile(key);
  ClearInitialKeepAlive(profile);
  KeepSessionOnReload(profile);
  WatchReleasedProfile(profile, key);
  // ~ScopedProfileKeepAlive posts the removal. The key stays ordinary.
  state.profiles.erase(found);
  return true;
}

// DEV-880, exported as ArxEngineProfileIsLoaded. Whether Chromium still has a
// live Profile for the ordinary key: Arx holds it, a released one isn't
// destroyed yet (OnProfileWillBeDestroyed), or ProfileManager has it loaded.
bool ProfileIsLoaded(const char* raw_key) {
  CheckThread();
  auto& state = State();
  if (!state.running || !raw_key) return false;
  const std::string key(raw_key);
  if (state.private_profile_keys.contains(key)) return false;
  if (state.profiles.contains(key)) return true;
  for (const auto& item : ReleasedProfiles())
    if (item->key() == key) return true;
  auto* manager = g_browser_process->profile_manager();
  return manager && manager->GetProfileByPath(
      manager->user_data_dir().AppendASCII(key.empty() ? "Default" : "Arx-" + key));
}

bool ExtensionProfileIsCurrent(Profile* profile, const std::string& key) {
  return profile && ExtensionProfile(key.c_str()) == profile;
}


bool AdoptExtensionOptionsImpl(Profile* profile, const std::string& key,
    const std::string& extension_id, const GURL& url, std::optional<uint64_t> request,
    const extensions::Extension* exact_extension = nullptr) {
  CheckThread();
  auto& state = State();
  if (!state.running || !state.next_page || (request ? !state.callbacks.extension_view_created :
          (!state.callbacks.extension_options_requested || !state.callbacks.extension_options_revoked)) ||
      profile != ExtensionProfile(key.c_str()) || !IsEnabledExtensionPage(profile, url) ||
      url.host() != extension_id) return false;
  const std::string target = url.spec();
  if (target.empty() || target.size() > 32768) return false;
  const uint64_t id = state.next_page++;
  auto owned = std::make_unique<Page>(id, profile);
  if (!owned->ConfigureContentHosting(true) || !owned->Navigate(url)) return false;
  auto* exact = owned.get();
  const uint64_t offered_generation = exact->CloseGeneration();
  state.pages.emplace(id, std::move(owned));
  // The native extension API caller remains the exact enabled object through
  // publication. A manifest/registry replacement cannot borrow the old call.
  const bool caller_current = !exact_extension ||
      extensions::ExtensionRegistry::Get(profile)->enabled_extensions().GetByID(extension_id) == exact_extension;
  const bool accepted = caller_current && (request
      ? state.callbacks.extension_view_created(state.callbacks.context,
          *request, key.c_str(), extension_id.c_str(), id, target.c_str(), target.size(), ARX_EXTENSION_VIEW_OPTIONS)
      : state.callbacks.extension_options_requested(state.callbacks.context,
          key.c_str(), extension_id.c_str(), id, target.c_str(), target.size()));
  auto found = state.pages.find(id);
  if (!accepted) {
    if (found != state.pages.end() && found->second.get() == exact) state.pages.erase(found);
    return false;
  }
  if (!state.running || found == state.pages.end() || found->second.get() != exact) return false;
  if (!request && (profile != ExtensionProfile(key.c_str()) ||
      !IsEnabledExtensionPage(profile, url) ||
      extensions::ExtensionRegistry::Get(profile)->enabled_extensions().GetByID(extension_id) != exact_extension)) {
    // Native/Swift/model publication is one transaction. Revoke before erasing
    // the native page so the host can release exactly the ownership it accepted.
    // A consumer's explicit close or navigation replacement is never borrowed.
    if (found->second->CloseGeneration() == offered_generation) {
      state.callbacks.extension_options_revoked(state.callbacks.context,
          key.c_str(), extension_id.c_str(), id, offered_generation);
      found = state.pages.find(id);
      if (found != state.pages.end() && found->second.get() == exact &&
          found->second->CloseGeneration() == offered_generation) state.pages.erase(found);
    }
    return false;
  }
  found->second->PublishNavigation();
  return true;
}

bool AdoptExtensionOptions(Profile* profile, const std::string& key,
    const std::string& extension_id, const GURL& url, uint64_t request) {
  return request && AdoptExtensionOptionsImpl(profile, key, extension_id, url, request);
}

std::optional<std::string> CurrentExtensionProfileKey(Profile* profile) {
  CheckThread();
  if (!State().running || !profile || profile->IsOffTheRecord()) return std::nullopt;
  for (const auto& [key, owner] : State().profiles) {
    if (owner->profile() == profile && ExtensionProfile(key.c_str()) == profile &&
        !HasExtensionInstallWork(key)) return key;
  }
  return std::nullopt;
}

bool AdoptRuntimeExtensionOptions(Profile* profile, const std::string& key,
    const extensions::Extension* exact_extension, const GURL& url) {
  return exact_extension && AdoptExtensionOptionsImpl(profile, key, exact_extension->id(),
      url, std::nullopt, exact_extension);
}

bool IsEmbedded() { return State().started; }

void AttachEngine(ChromeBrowserMainParts* parts) {
  if (State().started) parts->AddParts(std::make_unique<EngineParts>());
}

}  // namespace arx

extern "C" __attribute__((visibility("default")))
bool ArxEngineSetPageAudioVolume(uint64_t page, double volume) {
  return arx::SetPageAudioVolume(page, volume);
}

// DEV-1020, declared in dark_pages_bridge.h.
extern "C" __attribute__((visibility("default")))
bool ArxEngineSetPageDarkPages(uint64_t page,
                               bool enabled,
                               const char* const* off_sites,
                               size_t count) {
  return arx::SetPageDarkPagesForApp(page, enabled, off_sites, count);
}

// DEV-824 follow-up: outside the ABI table, so the app looks it up and runs on
// engines built before it, drawing the manifest's icons. Copies the PNG into
// `buffer` when `capacity` holds it and returns its length either way, 0 when
// the action shows its default icon. Main thread.
extern "C" __attribute__((visibility("default")))
size_t ArxEngineCopyExtensionActionIcon(uint64_t page, const char* extension_id, float scale,
                                        uint8_t* buffer, size_t capacity) {
  CHECK([NSThread isMainThread]);
  const std::vector<uint8_t> png = arx::PageExtensionActionIcon(page, extension_id, scale);
  if (buffer && capacity >= png.size() && !png.empty())
    std::memcpy(buffer, png.data(), png.size());
  return png.size();
}

// DEV-880: like the volume export, outside the ABI table, so the app looks it
// up and runs on engines built before it, keeping every profile until quit.
extern "C" __attribute__((visibility("default")))
bool ArxEngineReleaseProfile(const char* key) {
  return arx::ReleaseProfile(key);
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineProfileIsLoaded(const char* key) {
  return arx::ProfileIsLoaded(key);
}

// DEV-1293: outside the ABI table, so the app looks them up and runs on engines
// built before them, where a page's swipe only reaches its own history. Main
// thread. `back` and `forward` say the tab's other engine has a page right
// behind or ahead of this page's current entry; a swipe released that way calls
// the handler with the page and -1 or 1 instead of navigating. False for an
// unknown page.
extern "C" __attribute__((visibility("default")))
bool ArxEngineSetPageSharedHistory(uint64_t page, bool back, bool forward) {
  return arx::SetPageSharedHistory(page, back, forward);
}

extern "C" __attribute__((visibility("default")))
void ArxEngineSetSharedHistoryHandler(void (*handler)(void* context, uint64_t page,
                                                      int32_t direction),
                                      void* context) {
  arx::gestures::Controller::SetSharedHistoryHandler(handler, context);
}

// DEV-873. int32_t ArxEngineUnloadPage(page, reason, blockers): a
// PageUnloadStatus; reason is a PageUnloadReason, blockers (may be NULL) gets a
// PageUnloadBlocker mask.
extern "C" __attribute__((visibility("default")))
int32_t ArxEngineUnloadPage(uint64_t page, uint32_t reason, uint32_t* blockers) {
  return arx::UnloadPageForApp(page, reason, blockers);
}

extern "C" __attribute__((visibility("default")))
bool ArxEnginePageIsUnloaded(uint64_t page) {
  return arx::PageIsUnloadedForApp(page);
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineRestoreUnloadedPage(uint64_t page) {
  return arx::RestoreUnloadedPageForApp(page);
}

// DEV-1128. bool ArxEngineEndPictureInPicture(page): ends the page's video or
// document picture in picture without unloading it. True when there was one.
extern "C" __attribute__((visibility("default")))
bool ArxEngineEndPictureInPicture(uint64_t page) {
  return arx::EndPictureInPictureForApp(page);
}

extern "C" __attribute__((visibility("default")))
size_t ArxEngineCopyProcesses(ArxEngineProcess* entries, size_t capacity) {
  return arx::CopyProcesses(entries, capacity);
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineEndProcess(int32_t pid) {
  return arx::EndProcess(pid);
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineSetNetworkCapture(uint64_t page, bool enabled) {
  return arx::SetPageNetworkCapture(page, enabled);
}

extern "C" __attribute__((visibility("default")))
size_t ArxEngineReadNetworkCapture(uint64_t page, uint64_t after, uint32_t limit,
                                   uint32_t body_bytes, char* buffer, size_t capacity) {
  CHECK([NSThread isMainThread]);
  const std::string json = arx::ReadNetworkCapture(page, after, limit, body_bytes);
  if (buffer && capacity > json.size()) {
    std::memcpy(buffer, json.data(), json.size());
    buffer[json.size()] = '\0';
  }
  return json.size();
}

extern "C" __attribute__((visibility("default")))
uint32_t ArxEngineDownloadControl(const char* key, const char* guid) {
  CHECK([NSThread isMainThread]);
  if (!key || !guid) return 0;
  return arx::DownloadControl(key, guid);
}

extern "C" __attribute__((visibility("default")))
uint64_t ArxEngineLostOnQuitDownloadCount() {
  CHECK([NSThread isMainThread]);
  return arx::LostOnQuitDownloadCount();
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineRemoveDownload(const char* key, const char* guid) {
  CHECK([NSThread isMainThread]);
  if (!key || !guid) return false;
  return arx::RemoveDownload(key, guid);
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineSetDownloadPaused(const char* key, const char* guid, bool paused) {
  CHECK([NSThread isMainThread]);
  if (!key || !guid) return false;
  return arx::SetDownloadPaused(key, guid, paused);
}

// DEV-890, outside the ABI table so the app still runs on engines built
// before it. Main thread, while the app shows its menu for the link token
// (link_context_requested): appends the extensions' chrome.contextMenus items
// for that link to `menu`, a borrowed NSMenu. False when there are none or
// the link's menu isn't current.
extern "C" __attribute__((visibility("default")))
bool ArxEngineAppendLinkExtensionItems(uint64_t page, uint64_t token, void* menu) {
  return arx::AppendLinkExtensionItems(page, token, (__bridge NSMenu*)menu);
}

// DEV-878. Additive exports outside the ABI table, so engines built before them
// still load and only keep no back/forward history.
// Main thread. The page's back/forward entries, borrowed until the next call,
// or 0 for a private, unknown or empty page.
extern "C" __attribute__((visibility("default")))
size_t ArxEngineCopyNavigationState(uint64_t page, const uint8_t** bytes) {
  return arx::CopyNavigationState(page, bytes);
}

// Main thread. A new ordinary page holding these entries, or 0 when the state
// is unreadable or its selected page isn't expected_url. Nothing loads until
// ArxEngineLoadRestoredPage, so the page can be configured first.
extern "C" __attribute__((visibility("default")))
uint64_t ArxEngineCreateRestoredPage(const char* profile_key, const char* expected_url,
                                     const uint8_t* bytes, size_t size) {
  return arx::CreateRestoredPage(profile_key, expected_url, bytes, size);
}

// Main thread. Loads a restored page's selected entry, once. False for any
// other page.
extern "C" __attribute__((visibility("default")))
bool ArxEngineLoadRestoredPage(uint64_t page) {
  return arx::LoadRestoredPage(page);
}

// DEV-907. Main thread. Sets the handler for pages' Badging API reports
// (navigator.setAppBadge and clearAppBadge from a tab's main document), or
// clears it with NULL. kind 0 clears the page's badge, 1 is a badge without a
// number, 2 a count. Outside the ABI table: older engines report nothing.
extern "C" __attribute__((visibility("default")))
void ArxEngineSetPageBadgeHandler(void (*handler)(void*, uint64_t, int32_t, uint64_t),
                                  void* context) {
  auto& observer = arx::BadgeObserver();
  observer.handler = handler;
  observer.context = context;
}

extern "C" __attribute__((visibility("default")))
const ArxEngineAPI* ArxEngineGetAPI(uint32_t version, size_t table_size) {
  if (version != ARX_ENGINE_ABI_VERSION || table_size != sizeof(ArxEngineAPI))
    return nullptr;
  static const ArxEngineAPI api = {
      arx::Run, arx::Quit, arx::CreatePage, arx::DestroyPage, arx::PageView,
      arx::Navigate, arx::Back, arx::Forward, arx::Reload, arx::Stop, arx::PrepareProfile, arx::RequestClose, arx::HistoryCount, arx::HistoryEntry, arx::GoToEntry, arx::PreparePrivateProfile, arx::ReleasePrivateProfile, arx::ClearCacheAndReload, arx::StartDownloadObservation, arx::RequestCancelDownload, arx::ReadActiveDownloadCount, arx::RequestCancelAllDownloads, arx::CapturePage, arx::CancelPageCapture, arx::RunWithOptions, arx::ObservePageMedia, arx::PerformPageMedia, arx::CancelPageMedia, arx::PrivateMediaMetadataStatus, arx::RequestExtensionInventory, arx::RequestExtensionManagement, arx::CancelExtensionRequest, arx::RequestExtensionFixture, arx::MediaSourceIsCurrent, arx::PageCloseGeneration, arx::RequestAuthorizedClose, arx::ConsumeAuthorizedClose, arx::CancelAuthorizedClose, arx::RequestSiteIcon, arx::CancelSiteIcon,
      arx::RequestInspection, arx::RequestInspectionValidation, arx::CancelInspection,
      arx::RevokeInspectionScope, arx::InspectionDocumentIsCurrent, arx::RequestReferenceClick, arx::CancelReferenceClick,
      arx::RequestReferenceFormAction, arx::CancelReferenceClick, arx::RequestReferenceScroll,
      arx::LinkContextIsCurrent, arx::DismissLinkContext,
      arx::RunWithProfileRetirement, arx::ProfileRetirementAvailable,
      arx::InspectProfileRetirement, arx::QueueProfileRetirement,
      arx::DocumentCaptureAvailable, arx::CapturePageDocument, arx::CancelPageDocumentCapture,
      arx::RunDocumentCaptureFixture, arx::RunGestureFixture, [] { return true; }, arx::ConfigureContentHosting,
      arx::ExtensionInstallAvailable, arx::RequestExtensionInstall, arx::ResolveExtensionInstallRequest,
      arx::RequestSignedExtensionFixture, arx::ExtensionViewCapability, arx::RequestExtensionView,
      arx::DevToolsAvailable, arx::ConfigurePageDevTools, arx::OpenPageDevTools,
      arx::InspectPageLinkContext, arx::ClosePageDevTools, arx::PageDevToolsIsOpen,
      arx::ReloadBypassingCache, arx::PageDevToolsLoaded,
      arx::SetUnattended, arx::UnattendedDialogCount,
      arx::UnpackedExtensionsAvailable, arx::RequestUnpackedExtension,
      arx::PageAuthenticationCancellations,
      arx::SetExtensionTabPlacements, arx::PageUserActionRequests,
      arx::SetUnattendedShutdown,
      arx::PageFind, arx::PageStopFind, arx::PageFindStatus,
      arx::RequestFrameInspection,
      arx::CapturePageOffscreen, arx::RequestPagePdf, arx::CancelPagePdf,
      arx::PageFileChooserInfo, arx::AnswerPageFileChooser,
      arx::PageDialogInfo, arx::AnswerPageDialog,
      arx::ReadPageMediaPosition, arx::SeekPageMedia, arx::SetPageAudioMuted,
      arx::RequestStartDownload,
      arx::EvaluatePageScript, arx::SetPageDeveloperLog, arx::ReadPageDeveloperLog,
      arx::CancelPageDeveloper,
      arx::AnswerPagePasswordSave, arx::RequestPageSignInCredentials, arx::RequestPageSignIn,
      arx::CancelPageSignIn,
      arx::RequestSavedPasswords, arx::RequestSaveSavedPassword, arx::RequestRemoveSavedPassword,
      arx::RequestRevealSavedPassword, arx::RequestImportSavedPasswords,
      arx::CancelSavedPasswordRequest,
      arx::RequestPageFocusedLink,
      arx::RequestSiteSettings, arx::RequestSetSitePermission, arx::RequestSetSiteZoom,
      arx::RequestCountBrowsingData, arx::RequestClearBrowsingData, arx::RequestDownloadSettings,
      arx::RequestSetDownloadSettings,
      arx::RequestSiteDataScope, arx::RequestClearSiteData,
      arx::ReadPageZoom, arx::ChangePageZoom,
      arx::PageDevToolsLayout, arx::ShowPageDevToolsPanel, arx::StartPageDevToolsInspect,
      arx::RequestWebstoreInstall, arx::DeclineWebstoreInstallRequest,
      // ABI45 (DEV-729, DEV-776).
      arx::PreparePrivateProfileFor, arx::RequestWebstoreUpdate,
      // ABI45 (DEV-795).
      arx::ConfigurePageMenuTitles, arx::SavePage,
      // ABI46 (DEV-830).
      arx::RequestImportPasswordRecords, arx::RequestImportCookies, arx::RequestCheckCookies,
      arx::RequestUndoCredentialImport,
      // ABI47 (DEV-845).
      arx::RequestWebstoreInstallByID,
      // ABI48 (DEV-814).
      arx::ConfigureContextMenuTitles,
      // ABI48 (DEV-828).
      arx::RunPageExtensionAction,
      // ABI48 (DEV-819).
      arx::PageDocumentType,
      // ABI50 (DEV-857).
      arx::ExternalLinkIsCurrent,
      // ABI50 (DEV-796).
      arx::SetSiteIconFetch,
      // ABI51 (DEV-940).
      arx::RequestCachedSiteIcon,
      // ABI52 (DEV-875, DEV-893).
      arx::AcceptPageAutofillSuggestion, arx::SelectPageAutofillSuggestion,
      arx::DismissPageAutofillSuggestions, arx::ConfigureAutofillAuthentication,
      // ABI52 (DEV-893).
      arx::ConfigureAutofillProducts, arx::RequestAutofillData, arx::RequestSaveAutofillAddress,
      arx::RequestSaveAutofillCard, arx::RequestRemoveAutofillData, arx::CancelAutofillDataRequest,
      // ABI54 (DEV-949).
      arx::ExitPageFullscreen,
      // ABI56 (DEV-851).
      arx::DownloadPageLinkContext,
      // ABI56 (DEV-963).
      arx::ConfigurePagePromptsHosted, arx::CopyPagePermissionPrompt,
      arx::AnswerPagePermissionPromptDecision,
      // ABI57 (DEV-996).
      arx::EvaluatePageTranslationScript,
      // ABI58 (DEV-1009).
      arx::PageUnresponsive, arx::WaitForPage, arx::EndPageRenderer, arx::PingPageRenderer,
      // ABI58 (DEV-1016).
      arx::CopyPageRendererEnd,
      // ABI59 (DEV-1065).
      arx::PageMainDocument,
      // ABI60 (DEV-1111, DEV-1118).
      arx::ConfigureLinkHoverReports,
      // ABI61 (DEV-1101).
      arx::ReadPageColors};
  return &api;
}
