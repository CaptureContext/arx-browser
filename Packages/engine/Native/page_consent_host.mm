#import <AppKit/AppKit.h>

#include "chrome/browser/arx/page_consent_host.h"
#include "chrome/browser/arx/consent_authority.h"
#include "chrome/browser/external_protocol/external_protocol_observer.h"
#include "chrome/browser/arx/external_handoff_authority.h"
#include "chrome/browser/arx/external_consent_fixture.h"

#include <algorithm>
#include <map>
#include <memory>
#include <vector>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/files/file_path.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/observer_list.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/timer/timer.h"
#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/permissions/system/system_permission_settings.h"
#include "chrome/browser/permissions/system/system_media_capture_permissions_mac.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "components/permissions/permission_prompt.h"
#include "components/permissions/embedded_permission_prompt_flow_model.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/permission_request_manager.h"
#include "components/content_settings/core/browser/website_settings_info.h"
#include "components/content_settings/core/browser/website_settings_registry.h"
#include "components/permissions/permission_util.h"
#include "components/url_formatter/elide_url.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents_delegate.h"
#include "chrome/browser/profiles/profile_io_data.h"
#include "chrome/browser/custom_handlers/protocol_handler_registry_factory.h"
#include "components/custom_handlers/protocol_handler_registry.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "base/rand_util.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/arx/dialog_bridge.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "content/public/browser/web_contents_user_data.h"
#include "content/public/browser/weak_document_ptr.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/common/constants.h"
#include "extensions/common/extension.h"
#include "third_party/blink/public/mojom/mediastream/media_stream.mojom.h"
#include "ui/gfx/geometry/point.h"
#include "url/origin.h"
#include "ui/gfx/geometry/size.h"

@interface ArxConsentAction : NSObject
@property(copy) dispatch_block_t action;
- (void)perform:(id)sender;
@end
@implementation ArxConsentAction
@synthesize action = _action;
- (void)perform:(id)sender { if (self.action) self.action(); }
@end

// A zero-size native child observes ancestor window moves synchronously. Polling
// alone cannot reject move-away/move-back ABA between timer ticks. Unhiding is
// reported too, so the host's last-seen visibility never goes stale (DEV-935).
@interface ArxConsentAttachmentView : NSView
@property(copy) dispatch_block_t willChange;
@property(copy) dispatch_block_t didChange;
@end
@implementation ArxConsentAttachmentView
@synthesize willChange = _willChange;
@synthesize didChange = _didChange;
- (void)viewWillMoveToWindow:(NSWindow*)window {
  if (self.willChange) self.willChange();
  [super viewWillMoveToWindow:window];
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.didChange) self.didChange();
}
- (void)viewDidHide {
  [super viewDidHide];
  if (self.willChange) self.willChange();
}
- (void)viewDidUnhide {
  [super viewDidUnhide];
  if (self.didChange) self.didChange();
}
- (NSView*)hitTest:(NSPoint)point { return nil; }
@end

namespace arx {
// Implemented by the engine's exact-profile retirement scheduler.
void ConsentActivityChanged(Profile*);
namespace {

using Guard = base::RepeatingCallback<bool()>;
using permissions::PermissionPrompt;
using PromptVariant = permissions::EmbeddedPermissionPromptFlowModel::Variant;

struct SourceHost {
  __weak NSView* view;
  __weak NSWindow* window;
  explicit SourceHost(NSView* value) : view(value), window(value.window) {}
  bool SameAttachment(content::WebContents* contents) const {
    return view && view == contents->GetNativeView().GetNativeNSView() && view.window == window;
  }
  bool Visible(content::WebContents* contents) const {
    return SameAttachment(contents) && window && window.visible && !window.miniaturized &&
        !view.hiddenOrHasHiddenAncestor &&
        contents->GetVisibility() == content::Visibility::VISIBLE;
  }
};

bool LiveSource(content::WebContents* contents, const content::WeakDocumentPtr& document) {
  auto* frame = document.AsRenderFrameHostIfValid();
  return frame && frame->IsActive() && frame->IsRenderFrameLive() &&
      content::WebContents::FromRenderFrameHost(frame) == contents &&
      frame->GetOutermostMainFrame() == contents->GetPrimaryMainFrame();
}

const extensions::Extension* ExtensionForOrigin(Profile* profile, const GURL& origin) {
  return origin.SchemeIs(extensions::kExtensionScheme)
      ? extensions::ExtensionRegistry::Get(profile)->enabled_extensions().GetByID(origin.GetHost())
      : nullptr;
}

bool ExistingDeviceGrants(content::RenderFrameHost* frame, const url::Origin& origin,
                          blink::mojom::MediaStreamType audio,
                          blink::mojom::MediaStreamType video) {
  using Type = blink::mojom::MediaStreamType;
  if (!frame || (audio == Type::NO_SERVICE && video == Type::NO_SERVICE)) return false;
  if (audio != Type::NO_SERVICE &&
      (audio != Type::DEVICE_AUDIO_CAPTURE ||
       !CheckPageMediaAccess(frame, origin, audio) ||
       system_permission_settings::CheckSystemAudioCapturePermission() !=
           system_permission_settings::SystemPermission::kAllowed)) return false;
  if (video != Type::NO_SERVICE &&
      (video != Type::DEVICE_VIDEO_CAPTURE ||
       !CheckPageMediaAccess(frame, origin, video) ||
       system_permission_settings::CheckSystemVideoCapturePermission() !=
           system_permission_settings::SystemPermission::kAllowed)) return false;
  return true;
}

std::map<Profile*, size_t>& Work() {
  static base::NoDestructor<std::map<Profile*, size_t>> work;
  return *work;
}

std::map<Profile*, base::FilePath>& WorkPaths() {
  static base::NoDestructor<std::map<Profile*, base::FilePath>> paths;
  return *paths;
}

struct MediaWork {
  Profile* profile;
  std::unique_ptr<ScopedProfileKeepAlive> keep_alive;
  explicit MediaWork(Profile* value) : profile(value) {
    // OTR destruction is held by Work(), while its ordinary parent is retained.
    keep_alive = ScopedProfileKeepAlive::TryAcquire(
        value->GetOriginalProfile(), ProfileKeepAliveOrigin::kWebAppPermissionDialogWindow);
    if (keep_alive && !Work()[profile]++) WorkPaths().emplace(profile, value->GetPath());
  }
  ~MediaWork() {
    if (!keep_alive) return;
    auto found = Work().find(profile);
    CHECK(found != Work().end() && found->second);
    if (!--found->second) {
      Work().erase(found);
      WorkPaths().erase(profile);
    }
    // Never destroy an OTR profile on the dispatcher callback stack.
    ConsentActivityChanged(profile);
  }
};

// Attribution for one initially blank, already published Page. This
// owns no WebContents and never closes a tab. The shared state is also retained
// by Chrome's actual worker/dialog guards and completion closures, so the exact
// profile/path hold outlives logical cancellation and even Page destruction.
class PublishedBlankAttribution final
    : public std::enable_shared_from_this<PublishedBlankAttribution> {
 public:
  static size_t& Count() { static size_t count = 0; return count; }
  PublishedBlankAttribution(content::WebContents* child, content::WebContents* source,
      content::WeakDocumentPtr opener, content::WeakDocumentPtr primary, Guard epoch)
      : child_(child->GetWeakPtr()), source_(source->GetWeakPtr()),
        initial_(child->GetPrimaryMainFrame()->GetWeakDocumentPtr()),
        opener_(std::move(opener)), primary_(std::move(primary)), epoch_(std::move(epoch)),
        deadline_(base::TimeTicks::Now() + base::Seconds(30)) {
    ++Count();
    CaptureHost();
  }
  ~PublishedBlankAttribution() {
    CHECK(Count());
    --Count();
    work_.reset();
    consent_testing::PublishedAttributionDrained(target_);
  }
  bool Current() const {
    if (!authority_.live() || base::TimeTicks::Now() >= deadline_ ||
        !child_ || !source_ || !epoch_ || !epoch_.Run() ||
        child_->GetBrowserContext() != source_->GetBrowserContext() ||
        !LiveSource(source_.get(), opener_) || !LiveSource(source_.get(), primary_) ||
        primary_.AsRenderFrameHostIfValid() != source_->GetPrimaryMainFrame() ||
        !LiveSource(child_.get(), initial_) ||
        initial_.AsRenderFrameHostIfValid() != child_->GetPrimaryMainFrame()) return false;
    return !host_ || host_->SameAttachment(child_.get());
  }
  bool live() const { return authority_.live(); }
  bool has_host() const { return !!host_; }
  bool deciding() const { return authority_.deciding(); }
  void CaptureHost() {
    if (!host_ && child_) {
      NSView* view = child_->GetNativeView().GetNativeNSView();
      if (view.window) host_ = std::make_unique<SourceHost>(view);
    }
  }
  void Finish() { authority_.Finish(); }
  void NavigationStarted(content::NavigationHandle* navigation) {
    // AddNewContents publishes before renderer WebView construction. Chromium
    // then synchronously commits the initial about:blank with the SAME document
    // token (RenderFrameImpl::SynchronouslyCommitAboutBlankForBug778318).
    // Permit that one browser-confirmed bootstrap, never a later blank load.
    // The original expiry, cap, documents, profile and host remain unchanged.
    if (bootstrap_navigation_) { Finish(); return; }
    if (!bootstrap_seen_ && Current() &&
        navigation->IsInitialSynchronousAboutBlankForEmbedding()) {
      bootstrap_seen_ = true;
      bootstrap_navigation_ = navigation->GetNavigationId();
      if (!bootstrap_navigation_) Finish();
      consent_testing::PublishedAttributionDiagnostic(source_.get(), 4,
          bootstrap_navigation_ ? 1 : 0);
      return;
    }
    bootstrap_seen_ = true;
    const auto& token = navigation->GetInitiatorFrameToken();
    auto* initiator = token ? content::RenderFrameHost::FromFrameToken(
        content::GlobalRenderFrameHostToken(navigation->GetInitiatorProcessId(), *token)) : nullptr;
    const int evidence = (Current() ? 1 : 0) | (navigation->IsRendererInitiated() ? 2 : 0) |
        (initiator && initiator == opener_.AsRenderFrameHostIfValid() ? 4 : 0) |
        (child_ && IsPageExternalTarget(child_.get(), navigation->GetURL()) ? 8 : 0) |
        (navigation->IsInPrimaryMainFrame() ? 16 : 0) | (navigation->IsSameDocument() ? 32 : 0);
    consent_testing::PublishedAttributionDiagnostic(source_.get(), 2, evidence);
    const bool exact = Current() && navigation->IsRendererInitiated() &&
        initiator && initiator == opener_.AsRenderFrameHostIfValid() &&
        IsPageExternalTarget(child_.get(), navigation->GetURL());
    // HTTP(S), fragment, browser-initiated, unrelated-frame, replacement and
    // second requests all spend the latch; normal navigation remains untouched.
    if (!authority_.BeginNavigation(navigation->GetNavigationId(),
        navigation->IsInPrimaryMainFrame(), navigation->IsSameDocument(), exact)) return;
    target_ = navigation->GetURL();
  }
  void NavigationFinished(content::NavigationHandle* navigation) {
    if (bootstrap_navigation_ && bootstrap_navigation_ == navigation->GetNavigationId()) {
      bootstrap_navigation_ = 0;
      // The bootstrap must really commit without changing the initial document
      // or RFH. Failure/replacement cannot re-arm the first-resolution latch.
      if (!Current() || !navigation->HasCommitted() || navigation->IsErrorPage() ||
          !navigation->IsInitialSynchronousAboutBlankForEmbedding() ||
          navigation->GetRenderFrameHost() != initial_.AsRenderFrameHostIfValid()) Finish();
      return;
    }
    authority_.NavigationFinished(navigation->GetNavigationId(), navigation->HasCommitted());
  }
  bool Matches(content::WeakDocumentPtr initiator) const {
    return initiator.AsRenderFrameHostIfValid() &&
        initiator.AsRenderFrameHostIfValid() == opener_.AsRenderFrameHostIfValid();
  }
  Guard Decision(content::WeakDocumentPtr initiator) {
    if (!Matches(initiator)) { Finish(); return base::BindRepeating([] { return false; }); }
    return base::BindRepeating([](std::shared_ptr<PublishedBlankAttribution> proof) {
      return proof->authority_.deciding() && proof->work_ && proof->Current() &&
          proof->host_ && proof->host_->Visible(proof->child_.get());
    }, shared_from_this());
  }
  base::OnceClosure Completion() {
    CaptureHost();
    const int evidence = (Current() ? 1 : 0) | (host_ && child_ && host_->Visible(child_.get()) ? 2 : 0) |
        (authority_.deciding() ? 4 : 0);
    consent_testing::PublishedAttributionDiagnostic(source_.get(), 3, evidence);
    if (!Current() || !host_ || !host_->Visible(child_.get()) ||
        !authority_.ProtocolStarted()) {
      Finish();
      return {};
    }
    if (!work_) {
      work_ = std::make_unique<MediaWork>(Profile::FromBrowserContext(child_->GetBrowserContext()));
      if (!work_->keep_alive) { Finish(); return {}; }
    }
    return base::BindOnce([](std::shared_ptr<PublishedBlankAttribution> proof) {
      proof->Finish();
    }, shared_from_this());
  }
  const GURL& target() const { return target_; }
  content::WeakDocumentPtr opener() const { return opener_; }
  content::WebContents* source() const { return source_.get(); }
 private:
  base::WeakPtr<content::WebContents> child_, source_;
  content::WeakDocumentPtr initial_, opener_, primary_;
  Guard epoch_;
  base::TimeTicks deadline_;
  ExternalHandoffAuthority authority_;
  bool bootstrap_seen_ = false;
  int64_t bootstrap_navigation_ = 0;
  GURL target_;
  std::unique_ptr<SourceHost> host_;
  std::unique_ptr<MediaWork> work_;
};

// Real platform sheet; the manager continues to own all policy, embargo,
// permission status changes, one-time expiry, and request source validation.
class PermissionSheet;
// ABI56 (DEV-963): the app draws ordinary site permission prompts. Off keeps
// the engine's sheet and quiet button exactly as before.
bool& PagePromptsHostedFlag() {
  static bool hosted = false;
  return hosted;
}

// The name the app gets for each request: the common ones by name, the rest
// by Chromium's content setting name.
std::string PermissionName(ContentSettingsType type) {
  switch (type) {
    case ContentSettingsType::NOTIFICATIONS: return "notifications";
    case ContentSettingsType::MEDIASTREAM_CAMERA: return "camera";
    case ContentSettingsType::MEDIASTREAM_MIC: return "microphone";
    case ContentSettingsType::GEOLOCATION:
    case ContentSettingsType::GEOLOCATION_WITH_OPTIONS: return "geolocation";
    case ContentSettingsType::CLIPBOARD_READ_WRITE: return "clipboard";
    default: {
      const auto* info = content_settings::WebsiteSettingsRegistry::GetInstance()->Get(type);
      return info ? info->name() : "unknown";
    }
  }
}

// ABI31: the sheet showing for each page, so automation can read and answer it.
std::map<content::WebContents*, PermissionSheet*>& PermissionSheets() {
  static base::NoDestructor<std::map<content::WebContents*, PermissionSheet*>> sheets;
  return *sheets;
}

class PermissionSheet final : public PermissionPrompt {
 public:
  PermissionSheet(Delegate* delegate, Guard guard, NSView* source)
      : delegate_(delegate->GetWeakPtr()), guard_(std::move(guard)), host_(source),
        contents_(delegate->GetAssociatedWebContents()), token_(base::RandUint64() | 1) {
    if (contents_) PermissionSheets()[contents_] = this;
    for (const auto& request : delegate->Requests()) {
      if (!message_.empty()) message_ += u"\n";
      message_ += request->GetMessageTextFragment();
      types_.push_back(request->GetContentSettingsType());
      temporary_ = temporary_ && permissions::PermissionUtil::DoesSupportTemporaryGrants(
          request->GetContentSettingsType());
    }
    origin_ = url_formatter::FormatOriginForSecurityDisplay(
        url::Origin::Create(delegate->GetRequestingOrigin()));
    if (delegate->GetEmbeddingOrigin() != delegate->GetRequestingOrigin()) {
      origin_ += u"\nEmbedded in " + url_formatter::FormatOriginForSecurityDisplay(
          url::Origin::Create(delegate->GetEmbeddingOrigin()));
    }
    if (types_.size() == 1 && types_[0] == ContentSettingsType::GEOLOCATION_WITH_OPTIONS) {
      geo_ = delegate->GetGeolocationPromptType();
      accuracy_ = delegate->GetInitialGeolocationAccuracySelection();
      // DEV-963: the accuracy the prompt type allows, as the sheet's control
      // shows it; Chromium CHECKs an approximate-only grant for approximate.
      if (*geo_ == permissions::GeolocationPromptType::kApproximateOnly)
        accuracy_ = GeolocationAccuracy::kApproximate;
      else if (*geo_ == permissions::GeolocationPromptType::kUpgradeToPrecise)
        accuracy_ = GeolocationAccuracy::kPrecise;
    }
    if (auto* model = delegate->GetEmbeddedPromptFlowModel()) variant_ = model->prompt_variant();
    quiet_ = delegate->ShouldCurrentRequestUseQuietUI();
    auto weak = weak_factory_.GetWeakPtr();
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<PermissionSheet> prompt) {
          if (prompt) prompt->Present();
        }, weak));
  }
  ~PermissionSheet() override {
    // DEV-963: answered, the tab switched, the page navigated or closed.
    if (hosted_) PagePermissionPromptChanged(page_, 0);
    if (auto found = PermissionSheets().find(contents_);
        found != PermissionSheets().end() && found->second == this) PermissionSheets().erase(found);
    weak_factory_.InvalidateWeakPtrs();
    [quiet_button_ removeFromSuperview];
    if (alert_.window.sheetParent)
      [alert_.window.sheetParent endSheet:alert_.window returnCode:NSModalResponseCancel];
  }
  bool SourceCurrent() const { return Current(); }
  // Strings are borrowed until the next call.
  bool Describe(ArxPageDialog* dialog) {
    if (!Current() || !dialog) return false;
    described_message_ = base::UTF16ToUTF8(message_);
    described_origin_ = base::UTF16ToUTF8(origin_);
    *dialog = {token_, ARX_PAGE_DIALOG_PERMISSION, described_message_.c_str(), "",
               described_origin_.c_str()};
    return true;
  }
  // The app has the user's approval for an accept. A decline dismisses rather
  // than blocks. Only an ordinary ask can be answered this way.
  ArxPageDialogStatus Answer(uint64_t token, bool accept) {
    if (token != token_ || !Current()) return ARX_PAGE_DIALOG_STALE;
    if (variant_ != PromptVariant::kAsk && variant_ != PromptVariant::kPreviouslyDenied)
      return ARX_PAGE_DIALOG_INVALID;
    auto delegate = delegate_;
    PromptOptions options = std::monostate();
    if (geo_) options = GeolocationPromptOptions{accuracy_};
    delegate->SetDecisionTime();
    // Each delegate call can synchronously delete this prompt.
    if (!accept) delegate->Dismiss(options);
    else if (temporary_) delegate->AcceptThisTime(options);
    else delegate->Accept(options);
    return ARX_PAGE_DIALOG_OK;
  }
  // ABI56 (DEV-963). The hosted prompt for the app to draw, as JSON.
  bool CopyHosted(uint64_t token, std::string* json) {
    if (!hosted_ || token != token_ || !Current() || !json) return false;
    base::DictValue value;
    value.Set("token", base::NumberToString(token_));
    value.Set("variant", variant_ == PromptVariant::kAsk ? "ask" : "previouslyDenied");
    value.Set("requestingOrigin", url::Origin::Create(delegate_->GetRequestingOrigin()).Serialize());
    if (delegate_->GetEmbeddingOrigin() != delegate_->GetRequestingOrigin()) {
      value.Set("embeddingOrigin", url::Origin::Create(delegate_->GetEmbeddingOrigin()).Serialize());
    } else {
      value.Set("embeddingOrigin", base::Value());
    }
    base::ListValue permissions, fragments;
    for (const auto& request : delegate_->Requests()) {
      permissions.Append(PermissionName(request->GetContentSettingsType()));
      fragments.Append(base::UTF16ToUTF8(request->GetMessageTextFragment()));
    }
    value.Set("permissions", std::move(permissions));
    value.Set("fragments", std::move(fragments));
    value.Set("allowOnce", temporary_);
    if (geo_) {
      base::DictValue geolocation;
      geolocation.Set("prompt",
          *geo_ == permissions::GeolocationPromptType::kApproximateOnly ? "approximateOnly"
          : *geo_ == permissions::GeolocationPromptType::kUpgradeToPrecise ? "upgradeToPrecise"
          : "default");
      geolocation.Set("initial", accuracy_ == GeolocationAccuracy::kPrecise ? "precise" : "approximate");
      value.Set("geolocation", std::move(geolocation));
    } else {
      value.Set("geolocation", base::Value());
    }
    value.Set("quiet", quiet_);
    auto encoded = base::WriteJson(value);
    if (!encoded) return false;
    *json = std::move(*encoded);
    return true;
  }
  // ABI56 (DEV-963). The person's answer from the app's prompt, with the same
  // checks as the engine's own sheet: still current, its source unchanged, its
  // window active and half a second gone; otherwise anything but a dismissal
  // becomes one. A dismissal never blocks.
  ArxPageDialogStatus AnswerHosted(uint64_t token, ArxPagePermissionDecision decision,
                                   ArxPagePermissionAccuracy accuracy) {
    if (!hosted_ || token != token_ || !Current()) return ARX_PAGE_DIALOG_STALE;
    const bool known_decision = decision == ARX_PAGE_PERMISSION_ALLOW ||
        decision == ARX_PAGE_PERMISSION_ALLOW_ONCE || decision == ARX_PAGE_PERMISSION_BLOCK ||
        decision == ARX_PAGE_PERMISSION_DISMISS;
    const bool known_accuracy = accuracy == ARX_PAGE_PERMISSION_ACCURACY_NONE ||
        accuracy == ARX_PAGE_PERMISSION_ACCURACY_APPROXIMATE ||
        accuracy == ARX_PAGE_PERMISSION_ACCURACY_PRECISE;
    if (!known_decision || !known_accuracy) return ARX_PAGE_DIALOG_INVALID;
    if (decision == ARX_PAGE_PERMISSION_ALLOW_ONCE && !temporary_) return ARX_PAGE_DIALOG_INVALID;
    if (accuracy != ARX_PAGE_PERMISSION_ACCURACY_NONE &&
        (!geo_ ||
         (accuracy == ARX_PAGE_PERMISSION_ACCURACY_PRECISE &&
          *geo_ == permissions::GeolocationPromptType::kApproximateOnly) ||
         (accuracy == ARX_PAGE_PERMISSION_ACCURACY_APPROXIMATE &&
          *geo_ == permissions::GeolocationPromptType::kUpgradeToPrecise)))
      return ARX_PAGE_DIALOG_INVALID;
    const bool source_window_active = NSApp.active && host_.window &&
        (NSApp.keyWindow == host_.window || NSApp.keyWindow.sheetParent == host_.window);
    if (!source_window_active || base::TimeTicks::Now() < allow_after_)
      decision = ARX_PAGE_PERMISSION_DISMISS;
    PromptOptions options = std::monostate();
    if (geo_) {
      options = GeolocationPromptOptions{
          accuracy == ARX_PAGE_PERMISSION_ACCURACY_PRECISE ? GeolocationAccuracy::kPrecise
          : accuracy == ARX_PAGE_PERMISSION_ACCURACY_APPROXIMATE ? GeolocationAccuracy::kApproximate
          : accuracy_};
    }
    auto delegate = delegate_;
    delegate->SetDecisionTime();
    // Each delegate call can synchronously delete this prompt.
    switch (decision) {
      case ARX_PAGE_PERMISSION_ALLOW: delegate->Accept(options); break;
      case ARX_PAGE_PERMISSION_ALLOW_ONCE: delegate->AcceptThisTime(options); break;
      case ARX_PAGE_PERMISSION_BLOCK: delegate->Deny(options); break;
      case ARX_PAGE_PERMISSION_DISMISS: delegate->Dismiss(options); break;
    }
    return ARX_PAGE_DIALOG_OK;
  }
  bool UpdateAnchor() override { return guard_.Run(); }
  TabSwitchingBehavior GetTabSwitchingBehavior() override {
    return kDestroyPromptAndIgnoreRequest;
  }
  permissions::PermissionPromptDisposition GetPromptDisposition() const override {
    return permissions::PermissionPromptDisposition::MODAL_DIALOG;
  }
  bool IsAskPrompt() const override { return variant_ == PromptVariant::kAsk; }
  std::optional<gfx::Rect> GetViewBoundsInScreen() const override { return std::nullopt; }
  std::vector<permissions::ElementAnchoredBubbleVariant> GetPromptVariants() const override {
    return delegate_ && delegate_->GetEmbeddedPromptFlowModel()
        ? delegate_->GetEmbeddedPromptFlowModel()->GetPromptVariants()
        : std::vector<permissions::ElementAnchoredBubbleVariant>{};
  }
  std::optional<permissions::feature_params::PermissionElementPromptPosition>
  GetPromptPosition() const override { return std::nullopt; }

 private:
  bool Current() const {
    return delegate_ && delegate_->GetCurrentPrompt() == this && guard_.Run();
  }
  void Present() {
    if (!Current()) return;
    // Kept: on close the page may leave the bridge before this prompt goes.
    // Contents that aren't an Arx page keep the engine's sheet.
    if (PagePromptsHostedFlag() &&
        (variant_ == PromptVariant::kAsk || variant_ == PromptVariant::kPreviouslyDenied) &&
        (page_ = PageIdentifier(contents_))) {
      // DEV-963: the app draws it, quiet or not, and answers through
      // AnswerHosted. Input protection starts when the app is told.
      hosted_ = true;
      delegate_->SetPromptShown();
      allow_after_ = base::TimeTicks::Now() + base::Milliseconds(500);
      PagePermissionPromptChanged(page_, token_);
      return;
    }
    if (quiet_) {
      // Respect quiet policy: a native affordance requires a deliberate click
      // before showing a sheet. It never silently changes to a loud prompt.
      quiet_action_ = [[ArxConsentAction alloc] init];
      auto weak = weak_factory_.GetWeakPtr();
      quiet_action_.action = ^{ if (weak) weak->ShowSheet(); };
      quiet_button_ = [NSButton buttonWithTitle:@"Permission request…"
          target:quiet_action_ action:@selector(perform:)];
      quiet_button_.accessibilityLabel = @"Review this page’s permission request";
      [quiet_button_ sizeToFit];
      quiet_button_.frame = NSMakeRect(12, 12, quiet_button_.frame.size.width,
                                      quiet_button_.frame.size.height);
      quiet_button_.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
      [host_.view addSubview:quiet_button_];
      delegate_->SetPromptShown();
      return;
    }
    ShowSheet();
  }
  void ShowSheet() {
    if (!Current() || alert_ || !host_.window) return;
    if (host_.window.attachedSheet) {
      if (!show_timer_.IsRunning()) {
        show_deadline_ = base::TimeTicks::Now() + base::Seconds(30);
        show_timer_.Start(FROM_HERE, base::Milliseconds(100), this,
                          &PermissionSheet::RetrySheet);
      }
      return;
    }
    show_timer_.Stop();
    [quiet_button_ removeFromSuperview];
    alert_ = [[NSAlert alloc] init];
    alert_.messageText = @"Website permission";
    alert_.window.identifier = @"ArxWebsitePermission";
    alert_.informativeText = base::SysUTF16ToNSString(origin_ + u"\n\n" + message_);
    const auto add = [&](NSString* title, Decision action) {
      [alert_ addButtonWithTitle:title];
      decisions_.push_back(action);
    };
    switch (variant_) {
      case PromptVariant::kAsk:
      case PromptVariant::kPreviouslyDenied:
        add(@"Block", Decision::kBlock);
        if (temporary_) add(@"Allow Once", Decision::kOnce);
        add(temporary_ ? @"Always Allow" : @"Allow", Decision::kAllow);
        break;
      case PromptVariant::kPreviouslyGranted:
        alert_.informativeText = [alert_.informativeText stringByAppendingString:
            @"\n\nYou have already allowed this website."];
        add(@"Stop Allowing", Decision::kBlock);
        break;
      case PromptVariant::kOsPrompt:
        alert_.informativeText = [alert_.informativeText stringByAppendingString:
            @"\n\nThe website has permission. macOS must also allow Arx to continue."];
        add(@"Continue to macOS Permission…", Decision::kSystemRequest);
        break;
      case PromptVariant::kOsSystemSettings:
        alert_.informativeText = [alert_.informativeText stringByAppendingString:
            @"\n\nmacOS currently blocks Arx. You can review this in System Settings."];
        add(@"Open System Settings…", Decision::kSystemSettings);
        break;
      case PromptVariant::kAdministratorGranted:
      case PromptVariant::kAdministratorDenied:
        alert_.informativeText = [alert_.informativeText stringByAppendingString:
            variant_ == PromptVariant::kAdministratorGranted
                ? @"\n\nYour administrator allows this permission."
                : @"\n\nYour administrator blocks this permission."];
        break;
      case PromptVariant::kUninitialized:
        alert_.informativeText = [alert_.informativeText stringByAppendingString:
            @"\n\nThis permission request is no longer available."];
        break;
    }
    add(@"Cancel", Decision::kDismiss);
    for (NSUInteger index = 0; index < decisions_.size(); ++index) {
      if (decisions_[index] == Decision::kBlock)
        alert_.buttons[index].identifier = @"ArxPermissionBlock";
      if (decisions_[index] == Decision::kOnce)
        alert_.buttons[index].identifier = @"ArxPermissionAllowOnce";
    }
    alert_.buttons.lastObject.identifier = @"ArxPermissionCancel";
    for (NSButton* button in alert_.buttons) button.keyEquivalent = @"";
    alert_.buttons.lastObject.keyEquivalent = @"\e";
    if (geo_ && (variant_ == PromptVariant::kAsk || variant_ == PromptVariant::kPreviouslyDenied)) {
      accuracy_control_ = [NSSegmentedControl segmentedControlWithLabels:
          @[@"Approximate location", @"Precise location"]
          trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
      accuracy_control_.selectedSegment = accuracy_ == GeolocationAccuracy::kPrecise ? 1 : 0;
      if (*geo_ == permissions::GeolocationPromptType::kApproximateOnly) {
        accuracy_control_.selectedSegment = 0;
        [accuracy_control_ setEnabled:NO forSegment:1];
      } else if (*geo_ == permissions::GeolocationPromptType::kUpgradeToPrecise) {
        accuracy_control_.selectedSegment = 1;
        [accuracy_control_ setEnabled:NO forSegment:0];
      }
      alert_.accessoryView = accuracy_control_;
    }
    delegate_->SetPromptShown();
    allow_after_ = base::TimeTicks::Now() + base::Milliseconds(500);
    // Ignore click-through/held keys from the gesture that produced the prompt.
    for (NSUInteger index = 0; index + 1 < alert_.buttons.count; ++index)
      alert_.buttons[index].enabled = NO;
    auto weak = weak_factory_.GetWeakPtr();
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<PermissionSheet> prompt) {
          if (!prompt || !prompt->Current()) return;
          for (NSButton* button in prompt->alert_.buttons) button.enabled = YES;
        }, weak), base::Milliseconds(500));
    [alert_ beginSheetModalForWindow:host_.window completionHandler:^(NSModalResponse response) {
      if (weak) weak->Decide(response);
    }];
  }
  void RetrySheet() {
    if (!Current()) {
      show_timer_.Stop();
      return;
    }
    if (base::TimeTicks::Now() >= show_deadline_) {
      show_timer_.Stop();
      delegate_->Ignore(std::monostate());
      return;
    }
    ShowSheet();
  }
  void Decide(NSModalResponse response) {
    if (!Current()) return;
    const auto index = response - NSAlertFirstButtonReturn;
    Decision decision = index >= 0 && static_cast<size_t>(index) < decisions_.size()
        ? decisions_[index] : Decision::kDismiss;
    const bool source_window_active = NSApp.active &&
        (NSApp.keyWindow == host_.window || NSApp.keyWindow.sheetParent == host_.window);
    if (!source_window_active || base::TimeTicks::Now() < allow_after_)
      decision = Decision::kDismiss;
    auto delegate = delegate_;
    PromptOptions options = std::monostate();
    if (geo_ && accuracy_control_) {
      options = GeolocationPromptOptions{accuracy_control_.selectedSegment == 1
          ? GeolocationAccuracy::kPrecise : GeolocationAccuracy::kApproximate};
    }
    delegate->SetDecisionTime();
    // Each delegate call can synchronously delete this prompt.
    switch (decision) {
      case Decision::kBlock: delegate->Deny(options); return;
      case Decision::kOnce: delegate->AcceptThisTime(options); return;
      case Decision::kAllow: delegate->Accept(options); return;
      case Decision::kDismiss: delegate->Dismiss(options); return;
      case Decision::kSystemRequest: RequestSystem(); return;
      case Decision::kSystemSettings:
        for (auto type : types_) {
          if (system_permission_settings::IsDenied(type)) {
            system_permission_settings::OpenSystemSettings(delegate->GetAssociatedWebContents(), type);
            delegate->Dismiss(options);
            return;
          }
        }
        delegate->AdvanceOrFinalizeEmbeddedPromptFlow();
        return;
    }
  }
  void RequestSystem() {
    if (!Current()) return;
    if (types_.empty() || types_.size() > 2) {
      delegate_->Ignore(std::monostate());
      return;
    }
    pending_os_ = types_.size();
    auto weak = weak_factory_.GetWeakPtr();
    auto* profile = Profile::FromBrowserContext(delegate_->GetAssociatedWebContents()->GetBrowserContext());
    // A system callback may complete synchronously. Copy before invoking it;
    // completion can finalize this prompt and destroy the member collection.
    const auto types = types_;
    for (auto type : types) {
      auto work = std::make_unique<MediaWork>(profile);
      if (!work->keep_alive) {
        if (weak && weak->Current()) weak->delegate_->Ignore(std::monostate());
        return;
      }
      system_permission_settings::Request(type, base::BindOnce(
          [](base::WeakPtr<PermissionSheet> prompt, std::unique_ptr<MediaWork> work) {
            if (!prompt || !prompt->Current()) return;
            if (--prompt->pending_os_) return;
            if (std::ranges::any_of(prompt->types_, [](auto type) {
                  return system_permission_settings::CanPrompt(type);
                })) {
              prompt->delegate_->Ignore(std::monostate());
              return;
            }
            prompt->delegate_->AdvanceOrFinalizeEmbeddedPromptFlow();
          }, weak, std::move(work)));
    }
  }
  enum class Decision { kBlock, kAllow, kOnce, kDismiss, kSystemRequest, kSystemSettings };
  std::vector<Decision> decisions_;
  std::vector<ContentSettingsType> types_;
  PromptVariant variant_ = PromptVariant::kAsk;
  size_t pending_os_ = 0;
  base::WeakPtr<Delegate> delegate_;
  Guard guard_;
  SourceHost host_;
  raw_ptr<content::WebContents> contents_;
  uint64_t token_;
  std::string described_message_, described_origin_;
  std::u16string origin_, message_;
  bool temporary_ = true;
  bool quiet_ = false;
  // DEV-963: the app draws this prompt, for this Arx page.
  bool hosted_ = false;
  uint64_t page_ = 0;
  base::TimeTicks allow_after_;
  base::TimeTicks show_deadline_;
  base::RepeatingTimer show_timer_;
  std::optional<permissions::GeolocationPromptType> geo_;
  GeolocationAccuracy accuracy_ = GeolocationAccuracy::kApproximate;
  NSAlert* __strong alert_;
  NSSegmentedControl* __strong accuracy_control_;
  NSButton* __strong quiet_button_;
  ArxConsentAction* __strong quiet_action_;
  base::WeakPtrFactory<PermissionSheet> weak_factory_{this};
};

class ConsentHost final : public content::WebContentsObserver,
                          public content::WebContentsUserData<ConsentHost>,
                          public web_modal::WebContentsModalDialogManagerDelegate,
                          public web_modal::WebContentsModalDialogHost {
 public:
  ~ConsentHost() override {
    weak_factory_.InvalidateWeakPtrs();
    RemoveAttachmentObserver();
    if (web_contents()) ShutDown();
    for (auto& observer : observers_) observer.OnHostDestroying();
  }
  void ShutDown() {
    Configure(false);
    if (auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(web_contents()))
      manager->SetDelegate(nullptr);
  }
  void Configure(bool enabled) {
    authority_.Configure(false);
    protocol_observer_.reset();
    RemoveAttachmentObserver();
    InvalidateDecisions();
    // ExtensionViewHost may replace the manager delegate while loading. An
    // explicitly disabled helper must also reclaim routing and deny fallback.
    if (auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(web_contents()))
      manager->SetDelegate(this);
    if (enabled) {
      // Chrome rearms external anti-flood only from real input. Do not synthesize
      // PermitLaunchUrl when a child resumes, a dialog closes, or a timer fires.
      protocol_observer_ = std::make_unique<ExternalProtocolObserver>(web_contents());
      attachment_ = [[ArxConsentAttachmentView alloc] initWithFrame:NSZeroRect];
      attachment_.accessibilityElement = NO;
      auto weak = weak_factory_.GetWeakPtr();
      attachment_.willChange = ^{ if (weak) weak->SourceAttachmentWillChange(); };
      attachment_.didChange = ^{ if (weak) weak->ObserveSourceWindow(); };
      [web_contents()->GetNativeView().GetNativeNSView() addSubview:attachment_];
      ObserveSourceWindow();
      authority_.Configure(true);
      hosting_ = true;
      UpdatePolling();
    } else {
      hosting_ = false;
      timer_.Stop();
      last_host_.reset();
    }
  }
  Guard Bind(const std::vector<content::WeakDocumentPtr>& sources, bool require_visible = true) {
    const auto epoch = authority_.generation();
    auto host = std::make_shared<SourceHost>(web_contents()->GetNativeView().GetNativeNSView());
    auto primary = web_contents()->GetPrimaryMainFrame()->GetWeakDocumentPtr();
    auto* profile = web_contents()->GetBrowserContext();
    return base::BindRepeating([](base::WeakPtr<ConsentHost> owner, uint64_t epoch,
        std::shared_ptr<SourceHost> host, content::WeakDocumentPtr primary,
        std::vector<content::WeakDocumentPtr> sources, content::BrowserContext* profile, bool require_visible) {
      if (!owner || !owner->authority_.Current(epoch)) return false;
      auto* contents = owner->web_contents();
      if (contents->GetBrowserContext() != profile || (require_visible && !host->Visible(contents)) ||
          !LiveSource(contents, primary) ||
          primary.AsRenderFrameHostIfValid() != contents->GetPrimaryMainFrame()) return false;
      return std::ranges::all_of(sources, [contents](const auto& source) {
        return LiveSource(contents, source);
      });
    }, weak_factory_.GetWeakPtr(), epoch, host, primary, sources, profile, require_visible);
  }
  bool enabled() const { return authority_.enabled(); }
  void BindPublishedBlank(content::WebContents* source,
      content::WeakDocumentPtr initiator, content::WeakDocumentPtr source_primary, Guard epoch) {
    auto* contents = web_contents();
    auto* source_host = source ? ConsentHost::FromWebContents(source) : nullptr;
    consent_testing::PublishedAttributionDiagnostic(source, 0, static_cast<int>(PublishedBlankAttribution::Count()));
    if (blank_attribution_ || !enabled() || !source_host || !source_host->enabled() ||
        !source || source == contents || !epoch || !epoch.Run() ||
        contents->GetBrowserContext() != source->GetBrowserContext() ||
        !(contents->GetLastCommittedURL().is_empty() || contents->GetLastCommittedURL() == GURL("about:blank")) ||
        contents->GetController().GetPendingEntry() ||
        !LiveSource(source, initiator) || !LiveSource(source, source_primary) ||
        source_primary.AsRenderFrameHostIfValid() != source->GetPrimaryMainFrame() ||
        PublishedBlankAttribution::Count() >= 16) return;
    blank_attribution_ = std::make_shared<PublishedBlankAttribution>(contents, source,
        std::move(initiator), std::move(source_primary), std::move(epoch));
    UpdatePolling();
  }


  // This host remains disabled for ordinary page/media permission requests.
  // Only the exact registered external navigation may borrow source modal UI.
  void BindExternal(ConsentHost* source, Guard current,
                    content::WeakDocumentPtr initiator,
                    content::WeakDocumentPtr child_primary,
                    base::RepeatingClosure started,
                    base::RepeatingClosure finished) {
    external_source_ = source->weak_factory_.GetWeakPtr();
    external_current_ = std::move(current);
    external_initiator_ = std::move(initiator);
    external_primary_ = std::move(child_primary);
    external_started_ = std::move(started);
    external_finished_ = std::move(finished);
    std::erase_if(source->external_children_, [](const auto& child) { return !child; });
    source->external_children_.push_back(weak_factory_.GetWeakPtr());
    source->UpdatePolling();
  }
  void CancelExternal() {
    if (!external_finished_) return;
    auto finished = std::move(external_finished_);
    external_current_.Reset();
    finished.Run();
  }
  base::OnceClosure GetExternalProtocolRequestCompletion(content::WebContents* contents) override {
    if (contents != web_contents()) return {};
    if (blank_attribution_ && blank_attribution_->deciding())
      return blank_attribution_->Completion();
    if (!external_finished_) return {};
    external_started_.Run();
    return base::BindOnce([](base::WeakPtr<ConsentHost> host) {
      if (host) host->CancelExternal();
    }, weak_factory_.GetWeakPtr());
  }
  void DidShowExternalProtocolDialogForTesting(content::WebContents* contents,
      const GURL& url, const std::u16string& program, Guard visible,
      base::OnceClosure cancel, base::OnceClosure accept) override {
    if (contents != web_contents()) return;
    if (blank_attribution_ && blank_attribution_->deciding()) {
      if (url != blank_attribution_->target()) { blank_attribution_->Finish(); return; }
      consent_testing::DialogShown(contents, contents, url, program,
          blank_attribution_->Decision(blank_attribution_->opener()),
          std::move(visible), std::move(cancel), std::move(accept), blank_attribution_->source());
      return;
    }
    if (!external_finished_) return;
    consent_testing::DialogShown(contents, external_source_ ? external_source_->web_contents() : nullptr,
        url, program, external_current_, std::move(visible), std::move(cancel), std::move(accept));
  }
  bool ExternalCurrent() const {
    return external_source_ && external_current_ && external_current_.Run();
  }
  gfx::NativeView ModalView() const {
    return ExternalCurrent() ? external_source_->web_contents()->GetNativeView()
                             : web_contents()->GetNativeView();
  }

  Guard GetDialogDecisionGuard(content::WebContents* contents,
                                content::WeakDocumentPtr initiator) override {
    if (contents != web_contents()) return base::BindRepeating([] { return false; });
    if (blank_attribution_ && blank_attribution_->deciding())
      return blank_attribution_->Decision(std::move(initiator));
    if (external_finished_) {
      auto* frame = initiator.AsRenderFrameHostIfValid();
      const bool exact_initiator = frame &&
          (frame == external_initiator_.AsRenderFrameHostIfValid() ||
           frame == external_primary_.AsRenderFrameHostIfValid());
      return exact_initiator && ExternalCurrent()
          ? external_current_ : base::BindRepeating([] { return false; });
    }
    return Bind({initiator});
  }
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHost(
      content::WebContents* contents) override { return contents == web_contents() ? this : nullptr; }
  bool IsWebContentsVisible(content::WebContents* contents) override {
    if (contents != web_contents()) return false;
    if (external_finished_) return ExternalCurrent();
    SourceHost host(contents->GetNativeView().GetNativeNSView());
    return authority_.enabled() && host.Visible(contents);
  }
  gfx::NativeView GetHostView() const override { return ModalView(); }
  gfx::Point GetDialogPosition(const gfx::Size& size) override {
    const auto maximum = GetMaximumDialogSize();
    return gfx::Point(std::max(0, (maximum.width() - size.width()) / 2), 0);
  }
  gfx::Size GetMaximumDialogSize() override {
    NSView* view = ModalView().GetNativeNSView();
    return gfx::Size(std::max(0, static_cast<int>(view.bounds.size.width)),
                     std::max(0, static_cast<int>(view.bounds.size.height)));
  }
  bool ShouldActivateDialog() const override { return false; }
  void AddObserver(web_modal::ModalDialogHostObserver* value) override {
    observers_.AddObserver(value);
    UpdatePolling();
  }
  void RemoveObserver(web_modal::ModalDialogHostObserver* value) override { observers_.RemoveObserver(value); }
  void NotifyPositionRequiresUpdate() override {
    for (auto& observer : observers_) observer.OnPositionRequiresUpdate();
  }

 private:
  friend class content::WebContentsUserData<ConsentHost>;
  explicit ConsentHost(content::WebContents* contents) : content::WebContentsObserver(contents),
      content::WebContentsUserData<ConsentHost>(*contents) {
    web_modal::WebContentsModalDialogManager::CreateForWebContents(contents);
    web_modal::WebContentsModalDialogManager::FromWebContents(contents)->SetDelegate(this);
    permissions::PermissionRequestManager::CreateForWebContents(contents);
    auto* manager = permissions::PermissionRequestManager::FromWebContents(contents);
    manager->SetPromptFactoryForEmbedding(base::BindRepeating(
        [](base::WeakPtr<ConsentHost> host, content::WebContents* contents,
           PermissionPrompt::Delegate* delegate) -> std::unique_ptr<PermissionPrompt> {
          return host ? host->CreatePrompt(contents, delegate) : nullptr;
        }, weak_factory_.GetWeakPtr()));
  }
  std::unique_ptr<PermissionPrompt> CreatePrompt(content::WebContents* contents,
                                                 PermissionPrompt::Delegate* delegate) {
    if (contents != web_contents() || delegate->Requests().empty()) return nullptr;
    if (delegate->ShouldDropCurrentRequestIfCannotShowQuietly()) return nullptr;
    std::vector<content::WeakDocumentPtr> sources;
    for (const auto& request : delegate->Requests()) {
      auto* frame = content::RenderFrameHost::FromID(request->get_requesting_frame_id());
      if (!frame || content::WebContents::FromRenderFrameHost(frame) != contents) return nullptr;
      sources.push_back(frame->GetWeakDocumentPtr());
    }
    Guard guard = Bind(sources);
    if (!guard.Run()) return nullptr;
    auto prompt = std::make_unique<PermissionSheet>(delegate, std::move(guard),
                                                    contents->GetNativeView().GetNativeNSView());
    UpdatePolling();
    return prompt;
  }
  void InvalidateDecisions() {
    if (blank_attribution_) blank_attribution_->Finish();
    blank_attribution_.reset();
    for (auto& child : external_children_) if (child) child->CancelExternal();
    external_children_.clear();
    CancelExternal();
    if (auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(web_contents()))
      manager->CloseAllDialogs();
    auto* permissions = permissions::PermissionRequestManager::FromWebContents(web_contents());
    if (permissions && !permissions->Requests().empty()) permissions->Ignore(std::monostate());
  }
  void WebContentsDestroyed() override { ShutDown(); }
  void DidStartNavigation(content::NavigationHandle* navigation) override {
    // The owned external child observer separately permits exactly its initial
    // navigation. It has no ordinary authority to invalidate here.
    if (external_finished_) return;
    consent_testing::PublishedNavigationStarted(web_contents(), navigation->GetURL(),
        navigation->IsInPrimaryMainFrame());
    auto attribution = std::move(blank_attribution_);
    if (attribution) attribution->NavigationStarted(navigation);
    if (!navigation->IsSameDocument()) {
      authority_.Invalidate();
      InvalidateDecisions();
    }
    if (attribution && attribution->live()) blank_attribution_ = std::move(attribution);
  }
  void DidRedirectNavigation(content::NavigationHandle*) override {
    if (blank_attribution_) blank_attribution_->Finish();
  }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (blank_attribution_) blank_attribution_->NavigationFinished(navigation);
  }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override {
    if (blank_attribution_) blank_attribution_->Finish();
  }
  void OnVisibilityChanged(content::Visibility visibility) override {
    if (visibility == content::Visibility::VISIBLE) {
      // Keeps the last-seen visibility current while nothing polls (DEV-935).
      CheckSourceVisibility();
      return;
    }
    if (external_finished_) return;
    authority_.Invalidate();
    InvalidateDecisions();
  }
  void SourceAttachmentWillChange() {
    if (blank_attribution_ && blank_attribution_->has_host()) blank_attribution_->Finish();
    authority_.Invalidate();
    for (auto& child : external_children_) if (child) child->CancelExternal();
    external_children_.clear();
    // Cocoa is still mutating a view hierarchy. Do not destroy its source page
    // reentrantly. Guards already reject decisions synchronously; retire old UI
    // on the next task and leave any freshly bound permission prompt alone.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&ConsentHost::CloseStaleAttachmentUI, weak_factory_.GetWeakPtr()));
  }
  void CloseStaleAttachmentUI() {
    if (auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(web_contents()))
      manager->CloseAllDialogs();
    auto* manager = permissions::PermissionRequestManager::FromWebContents(web_contents());
    auto* prompt = manager ? manager->GetCurrentPrompt() : nullptr;
    if (prompt && !static_cast<const PermissionSheet*>(prompt)->SourceCurrent())
      manager->Ignore(std::monostate());
  }
  void RemoveAttachmentObserver() {
    attachment_.willChange = nil;
    attachment_.didChange = nil;
    [attachment_ removeFromSuperview];
    attachment_ = nil;
    for (id token in window_observers_)
      [NSNotificationCenter.defaultCenter removeObserver:token];
    window_observers_ = nil;
  }
  void ObserveSourceWindow() {
    for (id token in window_observers_)
      [NSNotificationCenter.defaultCenter removeObserver:token];
    NSView* view = web_contents()->GetNativeView().GetNativeNSView();
    last_host_ = std::make_unique<SourceHost>(view);
    last_visible_ = last_host_->Visible(web_contents());
    window_observers_ = [[NSMutableArray alloc] init];
    if (!view.window) return;
    auto weak = weak_factory_.GetWeakPtr();
    for (NSNotificationName name in @[NSWindowWillCloseNotification, NSWindowDidMiniaturizeNotification]) {
      id token = [NSNotificationCenter.defaultCenter addObserverForName:name object:view.window
          queue:nil usingBlock:^(NSNotification*) {
            if (weak) weak->SourceAttachmentWillChange();
          }];
      [window_observers_ addObject:token];
    }
    // DEV-935. Ordering the window out or back in (another Space, hiding the
    // app, deminiaturizing) changes its occlusion state; the poll that used to
    // see `window.visible` change runs only while a decision is pending.
    id token = [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowDidChangeOcclusionStateNotification object:view.window
                     queue:nil usingBlock:^(NSNotification*) {
                       if (weak) weak->CheckSourceVisibility();
                     }];
    [window_observers_ addObject:token];
  }
  // A visible source that stops being visible revokes as a detach does.
  void CheckSourceVisibility() {
    if (!hosting_ || !last_host_) return;
    const bool visible = last_host_->Visible(web_contents());
    if (last_visible_ && !visible) SourceAttachmentWillChange();
    last_visible_ = visible;
  }
  // DEV-935. Revocation is driven by the attachment view (detach, window
  // change, hide), window close, miniaturize and occlusion notifications and
  // Chromium's own visibility. The 100 ms poll runs only while something here
  // is pending: a modal dialog anchored on this page, which needs its position
  // kept and its source rechecked; a permission prompt; a published blank
  // child's attribution (at most 30 s); or an external child of this page.
  // Every page used to poll for as long as it hosted content.
  bool NeedsPolling() const {
    return blank_attribution_ || !observers_.empty() ||
        PermissionSheets().contains(web_contents()) ||
        std::ranges::any_of(external_children_, [](const auto& child) { return !!child; });
  }
  void UpdatePolling() {
    if (!hosting_ || !NeedsPolling()) {
      timer_.Stop();
      return;
    }
    if (!timer_.IsRunning())
      timer_.Start(FROM_HERE, base::Milliseconds(100), this, &ConsentHost::UpdateHost);
  }
  void UpdateHost() {
    if (blank_attribution_) {
      blank_attribution_->CaptureHost();
      if (!blank_attribution_->Current()) {
        blank_attribution_->Finish();
        blank_attribution_.reset();
        if (auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(web_contents()))
          manager->CloseAllDialogs();
      }
    }
    CheckSourceVisibility();
    NotifyPositionRequiresUpdate();
    UpdatePolling();
  }
  std::shared_ptr<PublishedBlankAttribution> blank_attribution_;
  base::WeakPtr<ConsentHost> external_source_;
  Guard external_current_;
  content::WeakDocumentPtr external_initiator_, external_primary_;
  base::RepeatingClosure external_started_, external_finished_;
  std::vector<base::WeakPtr<ConsentHost>> external_children_;
  std::unique_ptr<ExternalProtocolObserver> protocol_observer_;
  ConsentAuthority authority_;
  base::RepeatingTimer timer_;
  bool hosting_ = false;
  std::unique_ptr<SourceHost> last_host_;
  bool last_visible_ = false;
  ArxConsentAttachmentView* __strong attachment_;
  NSMutableArray* __strong window_observers_;
  base::ObserverList<web_modal::ModalDialogHostObserver> observers_;
  base::WeakPtrFactory<ConsentHost> weak_factory_{this};
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};
WEB_CONTENTS_USER_DATA_KEY_IMPL(ConsentHost);
// Unlike tab adoption this ownership is never published to Swift. The original
// native navigation is resumed after AddNewContents unwinds, including Chrome's
// sandbox, protocol registry, enterprise policy and anti-flood decisions.
class ExternalChild final : public content::WebContentsDelegate,
                            public content::WebContentsObserver {
 public:
  using Owners = std::map<uint64_t, std::unique_ptr<ExternalChild>>;
  static Owners& Pending() {
    static base::NoDestructor<Owners> owners;
    return *owners;
  }
  ExternalChild(uint64_t id, std::unique_ptr<content::WebContents> child,
                const GURL& target, Guard source, std::unique_ptr<MediaWork> work)
      : content::WebContentsObserver(child.get()), id_(id), contents_(std::move(child)),
        target_(target), source_(std::move(source)), work_(std::move(work)),
        initial_(contents_->GetPrimaryMainFrame()->GetWeakDocumentPtr()) {
    contents_->SetDelegate(this);
  }
  ~ExternalChild() override {
    weak_factory_.InvalidateWeakPtrs();
    TearDownPageConsentHosting(contents_.get());
    Observe(nullptr);
    contents_->SetDelegate(nullptr);
    contents_.reset();
    // Keep physical work visible until the actual child and its dialogs drain.
    work_.reset();
    consent_testing::ChildDestroyed(target_);
  }
  void Start(ConsentHost* source, content::WeakDocumentPtr initiator) {
    ConfigurePageConsentHosting(contents_.get(), false);
    auto weak = weak_factory_.GetWeakPtr();
    ConsentHost::FromWebContents(contents_.get())->BindExternal(source,
        base::BindRepeating([](base::WeakPtr<ExternalChild> owner) {
          return owner && owner->authority_.deciding() && owner->Current();
        }, weak), std::move(initiator), initial_,
        base::BindRepeating([](base::WeakPtr<ExternalChild> owner) {
          if (owner && !owner->authority_.ProtocolStarted()) owner->Finish();
        }, weak), base::BindRepeating(&ExternalChild::Finish, weak));
    deadline_ = base::TimeTicks::Now() + base::Seconds(30);
    timer_.Start(FROM_HERE, base::Milliseconds(100), this, &ExternalChild::CheckSource);
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<ExternalChild> owner) {
          if (!owner) return;
          if (!owner->Current()) { owner->Finish(); return; }
          owner->contents_->ResumeLoadingCreatedWebContents();
        }, weak));
  }
  content::WebContents* contents() const { return contents_.get(); }
  void Finish() {
    if (terminal_) return;
    terminal_ = true;
    authority_.Finish();
    timer_.Stop();
    // Shell callbacks, modal cancellation, navigation, and source teardown can
    // all finish synchronously. Destruction only occurs after those stacks exit.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<ExternalChild> owner) {
          if (!owner) return;
          auto found = Pending().find(owner->id_);
          if (found != Pending().end() && found->second.get() == owner.get()) Pending().erase(found);
        }, weak_factory_.GetWeakPtr()));
  }
 private:
  bool Current() const {
    auto* initial = initial_.AsRenderFrameHostIfValid();
    return authority_.live() && source_.Run() && initial &&
        initial == contents_->GetPrimaryMainFrame();
  }
  void CheckSource() {
    if (!Current() || base::TimeTicks::Now() >= deadline_) Finish();
  }
  void DidStartNavigation(content::NavigationHandle* navigation) override {
    if (!authority_.BeginNavigation(navigation->GetNavigationId(),
        navigation->IsInPrimaryMainFrame(), navigation->IsSameDocument(),
        navigation->GetURL() == target_) || !Current()) Finish();
  }
  void DidRedirectNavigation(content::NavigationHandle*) override { Finish(); }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (authority_.NavigationFinished(navigation->GetNavigationId(), navigation->HasCommitted())) Finish();
  }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override { Finish(); }
  void CloseContents(content::WebContents*) override { Finish(); }
  uint64_t id_;
  std::unique_ptr<content::WebContents> contents_;
  GURL target_;
  Guard source_;
  std::unique_ptr<MediaWork> work_;
  content::WeakDocumentPtr initial_;
  ExternalHandoffAuthority authority_;
  bool terminal_ = false;
  base::TimeTicks deadline_;
  base::RepeatingTimer timer_;
  base::WeakPtrFactory<ExternalChild> weak_factory_{this};
};

}  // namespace

void ConfigurePageConsentHosting(content::WebContents* contents, bool enabled) {
  CHECK([NSThread isMainThread]);
  ConsentHost::CreateForWebContents(contents);
  ConsentHost::FromWebContents(contents)->Configure(enabled);
}
void TearDownPageConsentHosting(content::WebContents* contents) {
  if (auto* host = ConsentHost::FromWebContents(contents)) host->ShutDown();
}
bool HasPageConsentWork(Profile* profile) { return Work().contains(profile); }
bool HasPageConsentWorkForPath(const base::FilePath& path) {
  return std::ranges::any_of(WorkPaths(), [&path](const auto& entry) {
    return entry.second == path;
  });
}

bool IsPageExternalTarget(content::WebContents* source, const GURL& target) {
  if (!source || !target.is_valid() || target.spec().size() > 32768 ||
      !target.has_scheme() || target.has_username() || target.has_password()) return false;
  // These are the pinned ChromeContentBrowserClient predicates. Do not keep
  // a separate hard-coded scheme allowlist or render a custom web handler here.
  auto* registry = ProtocolHandlerRegistryFactory::GetForBrowserContext(source->GetBrowserContext());
  return !ProfileIOData::IsHandledURL(target) &&
      !(registry && registry->IsHandledProtocol(target.scheme()));
}
content::WebContents* AdoptPageExternalTarget(
    std::unique_ptr<content::WebContents> child, content::WebContents* source,
    content::WeakDocumentPtr initiator, content::WeakDocumentPtr source_primary,
    const GURL& target, Guard epoch_current) {
  static uint64_t next = 1;
  auto* host = source ? ConsentHost::FromWebContents(source) : nullptr;
  if (!child || !host || !host->enabled() || !epoch_current || !epoch_current.Run() ||
      child->GetBrowserContext() != source->GetBrowserContext() ||
      !IsPageExternalTarget(source, target) || !LiveSource(source, initiator) ||
      !LiveSource(source, source_primary) ||
      source_primary.AsRenderFrameHostIfValid() != source->GetPrimaryMainFrame() ||
      ExternalChild::Pending().size() >= 16 || !next) return nullptr;
  auto proof = host->Bind({initiator, source_primary});
  if (!proof.Run()) return nullptr;
  auto work = std::make_unique<MediaWork>(Profile::FromBrowserContext(source->GetBrowserContext()));
  if (!work->keep_alive) return nullptr;
  Guard current = base::BindRepeating([](Guard source, Guard epoch) {
    return source.Run() && epoch.Run();
  }, std::move(proof), std::move(epoch_current));
  const uint64_t id = next++;
  auto owner = std::make_unique<ExternalChild>(id, std::move(child), target,
                                              std::move(current), std::move(work));
  auto* retained = owner.get();
  auto result = owner->contents()->GetWeakPtr();
  ExternalChild::Pending().emplace(id, std::move(owner));
  retained->Start(host, std::move(initiator));
  return result.get();
}
void BindPublishedBlankChildProvenance(content::WebContents* child, content::WebContents* source,
    content::WeakDocumentPtr initiator, content::WeakDocumentPtr source_primary, Guard epoch) {
  if (auto* host = child ? ConsentHost::FromWebContents(child) : nullptr)
    host->BindPublishedBlank(source, std::move(initiator), std::move(source_primary), std::move(epoch));
}
void StopPageExternalTargets() { ExternalChild::Pending().clear(); }

void RequestPageMediaAccess(content::WebContents* contents,
    const content::MediaStreamRequest& request, content::MediaResponseCallback callback) {
  auto* host = ConsentHost::FromWebContents(contents);
  auto* frame = content::RenderFrameHost::FromID(request.render_process_id, request.render_frame_id);
  Guard guard;
  if (host && frame && content::WebContents::FromRenderFrameHost(frame) == contents &&
      request.url_origin == frame->GetLastCommittedOrigin() &&
      url::Origin::Create(request.security_origin) == request.url_origin) {
    auto source = frame->GetWeakDocumentPtr();
    guard = base::BindRepeating([](Guard visible, Guard document,
        content::WeakDocumentPtr source, url::Origin origin,
        blink::mojom::MediaStreamType audio, blink::mojom::MediaStreamType video) {
      // New native/site consent still requires its original visible source.
      // A fresh background request is valid only with all real site AND OS
      // device grants already present, checked again at final delivery.
      return visible.Run() || (document.Run() &&
          ExistingDeviceGrants(source.AsRenderFrameHostIfValid(), origin, audio, video));
    }, host->Bind({source}), host->Bind({source}, false), source,
       request.url_origin, request.audio_type, request.video_type);
  }
  if (!guard || !guard.Run()) {
    std::move(callback).Run({}, blink::mojom::MediaStreamRequestResult::INVALID_STATE, nullptr);
    return;
  }
  auto* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  auto work = std::make_unique<MediaWork>(profile);
  if (!work->keep_alive) {
    std::move(callback).Run({}, blink::mojom::MediaStreamRequestResult::INVALID_STATE, nullptr);
    return;
  }
  MediaCaptureDevicesDispatcher::GetInstance()->ProcessMediaAccessRequest(contents, request,
      base::BindOnce([](Guard guard, std::unique_ptr<MediaWork> work,
          content::MediaResponseCallback callback, const blink::mojom::StreamDevicesSet& devices,
          blink::mojom::MediaStreamRequestResult result, std::unique_ptr<content::MediaStreamUI> ui) {
        if (!guard.Run()) {
          std::move(callback).Run({}, blink::mojom::MediaStreamRequestResult::INVALID_STATE, nullptr);
          return;
        }
        std::move(callback).Run(devices, result, std::move(ui));
      }, std::move(guard), std::move(work), std::move(callback)),
      ExtensionForOrigin(profile, request.security_origin));
}
bool CheckPageMediaAccess(content::RenderFrameHost* frame, const url::Origin& origin,
                          blink::mojom::MediaStreamType type) {
  auto* contents = content::WebContents::FromRenderFrameHost(frame);
  auto* host = contents ? ConsentHost::FromWebContents(contents) : nullptr;
  if (!host || !host->enabled() || origin != frame->GetLastCommittedOrigin() ||
      !LiveSource(contents, frame->GetWeakDocumentPtr())) return false;
  return MediaCaptureDevicesDispatcher::GetInstance()->CheckMediaAccessPermission(
      frame, origin, type, ExtensionForOrigin(Profile::FromBrowserContext(
          contents->GetBrowserContext()), origin.GetURL()));
}
bool PagePermissionPrompt(content::WebContents* contents, ArxPageDialog* dialog) {
  auto found = PermissionSheets().find(contents);
  return found != PermissionSheets().end() && found->second->Describe(dialog);
}

ArxPageDialogStatus AnswerPagePermissionPrompt(content::WebContents* contents, uint64_t token,
                                               bool accept) {
  auto found = PermissionSheets().find(contents);
  if (found == PermissionSheets().end()) return ARX_PAGE_DIALOG_STALE;
  return found->second->Answer(token, accept);
}

void SetPagePromptsHosted(bool hosted) { PagePromptsHostedFlag() = hosted; }

bool CopyHostedPagePermissionPrompt(content::WebContents* contents, uint64_t token,
                                    std::string* json) {
  auto found = PermissionSheets().find(contents);
  return found != PermissionSheets().end() && found->second->CopyHosted(token, json);
}

ArxPageDialogStatus AnswerHostedPagePermissionPrompt(content::WebContents* contents,
                                                     uint64_t token,
                                                     ArxPagePermissionDecision decision,
                                                     ArxPagePermissionAccuracy accuracy) {
  auto found = PermissionSheets().find(contents);
  if (found == PermissionSheets().end()) return ARX_PAGE_DIALOG_STALE;
  return found->second->AnswerHosted(token, decision, accuracy);
}
}  // namespace arx
