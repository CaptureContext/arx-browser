#include "chrome/browser/arx/extension_action_host.h"

#import <AppKit/AppKit.h>
#include <algorithm>
#include <cmath>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>
#include "chrome/browser/arx/extension_action_policy.h"
#include "chrome/browser/extensions/extension_keybinding_registry.h"
#include "chrome/browser/extensions/commands/command_service.h"
#include "extensions/common/command.h"
#include "ui/content_accelerators/accelerator_util.h"
#include "chrome/browser/arx/page_consent_host.h"
#include "chrome/browser/arx/extensions_bridge.h"
#include "base/check.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/timer/timer.h"
#include "base/time/time.h"
#include "chrome/browser/extensions/extension_action_runner.h"
#include "extensions/browser/permissions/site_permissions_helper.h"
#include "extensions/common/manifest_handlers/incognito_info.h"
#include "extensions/common/api/extension_action/action_info.h"
#include "extensions/common/manifest_handlers/icons_handler.h"
#include "extensions/common/icons/extension_icon_set.h"
#include "base/strings/string_util.h"
#include "chrome/browser/extensions/api/side_panel/side_panel_service.h"
#include "chrome/browser/extensions/extension_view.h"
#include "chrome/browser/extensions/extension_view_host.h"
#include "chrome/browser/profiles/profile.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/sessions/content/session_tab_helper.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/eye_dropper.h"
#include "content/public/browser/keyboard_event_processing_result.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/global_routing_id.h"
#include "ui/base/window_open_disposition.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest.h"
#include "extensions/common/mojom/view_type.mojom.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_rep.h"

using ARXExtensionActionEntries = std::vector<std::pair<uint64_t, std::string>>;

@interface ARXExtensionActionTarget : NSObject <NSMenuDelegate> {
  base::RepeatingCallback<ARXExtensionActionEntries()> entries_;
  base::RepeatingCallback<void(uint64_t)> choose_;
  NSMenu* menu_;
  NSHashTable<NSMenu*>* menus_;
}
- (instancetype)initWithEntries:(base::RepeatingCallback<ARXExtensionActionEntries()>)entries
                        choose:(base::RepeatingCallback<void(uint64_t)>)choose;
- (void)show:(NSButton*)sender;
- (NSMenu*)menu;
- (void)cancel;
- (void)dispose;
@end

@interface ARXExtensionActionButton : NSButton
@property(copy) void (^sourceHidden)(void);
@end
@implementation ARXExtensionActionButton
@synthesize sourceHidden;
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.window && self.sourceHidden) self.sourceHidden();
}
- (void)viewDidHide {
  [super viewDidHide];
  if (self.sourceHidden) self.sourceHidden();
}
@end

@implementation ARXExtensionActionTarget
- (instancetype)initWithEntries:(base::RepeatingCallback<ARXExtensionActionEntries()>)entries
                        choose:(base::RepeatingCallback<void(uint64_t)>)choose {
  if ((self = [super init])) {
    entries_ = std::move(entries); choose_ = std::move(choose);
    menus_ = [NSHashTable weakObjectsHashTable];
  }
  return self;
}
- (NSMenu*)menu {
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Extensions"];
  menu.autoenablesItems = NO;
  menu.delegate = self;
  [menus_ addObject:menu];
  return menu;
}
- (void)menuNeedsUpdate:(NSMenu*)menu {
  [menu removeAllItems];
  const auto entries = entries_.Run();
  for (const auto& [token, title] : entries) {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:base::SysUTF8ToNSString(title)
        action:@selector(choose:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = @(token);
    item.enabled = token != 0;
    [menu addItem:item];
  }
}
- (void)show:(NSButton*)sender {
  __attribute__((objc_precise_lifetime)) ARXExtensionActionTarget* retained = self;
  if (!sender.window || !sender.window.keyWindow || !sender.window.visible ||
      sender.window.miniaturized || sender.hiddenOrHasHiddenAncestor) return;
  NSMenu* menu = [self menu];
  menu_ = menu;
  [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds)) inView:sender];
  retained->menu_ = nil;
}
- (void)choose:(NSMenuItem*)item {
  if ([item.representedObject isKindOfClass:[NSNumber class]])
    choose_.Run([item.representedObject unsignedLongLongValue]);
}
- (void)cancel { [menu_ cancelTrackingWithoutAnimation]; menu_ = nil; }
- (void)dispose {
  [self cancel];
  for (NSMenu* menu in menus_) {
    menu.delegate = nil;
    for (NSMenuItem* item in menu.itemArray) {
      item.enabled = NO;
      item.target = nil;
      item.action = nullptr;
    }
  }
  [menus_ removeAllObjects];
}
@end

// DEV-1316. The engine's own window for an extension's popup, used when the app
// gives none: a small utility panel with the extension's name as its title.
@interface ARXExtensionPopupPanel : NSPanel
@end
@implementation ARXExtensionPopupPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

// Hears a popup's window lose focus, begin a move the person makes (AppKit
// posts NSWindowWillMoveNotification for a drag, not for setFrame) and close.
@interface ARXExtensionPopupWindowObserver : NSObject {
  base::RepeatingClosure resigned_;
  base::RepeatingClosure moved_;
  base::RepeatingClosure closed_;
}
- (instancetype)initWithWindow:(NSWindow*)window
                      resigned:(base::RepeatingClosure)resigned
                         moved:(base::RepeatingClosure)moved
                        closed:(base::RepeatingClosure)closed;
- (void)stop;
@end

@implementation ARXExtensionPopupWindowObserver
- (instancetype)initWithWindow:(NSWindow*)window
                      resigned:(base::RepeatingClosure)resigned
                         moved:(base::RepeatingClosure)moved
                        closed:(base::RepeatingClosure)closed {
  if ((self = [super init])) {
    resigned_ = std::move(resigned);
    moved_ = std::move(moved);
    closed_ = std::move(closed);
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(resigned:)
                   name:NSWindowDidResignKeyNotification object:window];
    [center addObserver:self selector:@selector(moved:)
                   name:NSWindowWillMoveNotification object:window];
    [center addObserver:self selector:@selector(closed:)
                   name:NSWindowWillCloseNotification object:window];
  }
  return self;
}
- (void)resigned:(NSNotification*)notification { if (resigned_) resigned_.Run(); }
- (void)moved:(NSNotification*)notification { if (moved_) moved_.Run(); }
- (void)closed:(NSNotification*)notification { if (closed_) closed_.Run(); }
- (void)stop {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  resigned_.Reset();
  moved_.Reset();
  closed_.Reset();
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

namespace arx {
namespace {
// DEV-1316: the app's popup window and closing rule, from
// ArxEngineSetExtensionPopupPresenter.
struct PopupPresenter {
  ArxExtensionPopupMakeWindowFunction make_window = nullptr;
  ArxExtensionPopupResizeWindowFunction resize_window = nullptr;
  uint32_t closing = ARX_EXTENSION_POPUP_CLOSES_UNLESS_MOVED;
  void* context = nullptr;
};
PopupPresenter& Presenter() {
  static PopupPresenter presenter;
  return presenter;
}
// Chrome's popup limits: the page lays itself out between these.
constexpr int kPopupMinimumSide = 25;
constexpr int kPopupMaximumWidth = 800;
constexpr int kPopupMaximumHeight = 600;
// At most this many popups stay open over one page: one per extension, and
// the others only because the person moved them.
constexpr size_t kMaximumPopups = 8;

bool Visible(content::WebContents* contents) {
  NSView* view = contents->GetNativeView().GetNativeNSView();
  return view && view.window && view.window.visible && !view.window.miniaturized &&
      !view.hiddenOrHasHiddenAncestor && !NSIsEmptyRect(view.visibleRect);
}

// Reuse Chrome's conflict resolution, lazy-worker event dispatch, activeTab
// grant and tab scrubbing. No Chrome BrowserWindow/TabList is fabricated.
class SourceExtensionCommands final : public extensions::ExtensionKeybindingRegistry {
 public:
  using Current = base::RepeatingCallback<bool()>;
  SourceExtensionCommands(content::WebContents* source, Current current)
      : ExtensionKeybindingRegistry(source->GetBrowserContext(), nullptr, ALL_EXTENSIONS),
        source_(source), current_(std::move(current)) { Init(); }
  bool Match(const ui::Accelerator& accelerator, std::string* id, std::string* command) const {
    return browser_context() && !shortcut_handling_suspended() && current_.Run() &&
        !accelerator.IsMediaKey() && GetFirstTarget(accelerator, id, command);
  }
  bool Dispatch(const ui::Accelerator& accelerator, const std::string& id, const std::string& command) {
    std::string actual_id, actual_command;
    return Match(accelerator, &actual_id, &actual_command) && actual_id == id && actual_command == command &&
        !extensions::Command::IsActionRelatedCommand(command) && NotifyEventTargets(accelerator);
  }
 private:
  content::WebContents* GetCommandWebContents() const override { return current_.Run() ? source_.get() : nullptr; }
  bool ShouldIgnoreCommand(const std::string&) const override { return false; }
  bool PopulateCommands(const extensions::Extension* extension, ui::CommandMap* commands) override {
    auto* service = extensions::CommandService::Get(browser_context());
    service->GetNamedCommands(extension->id(), extensions::CommandService::ACTIVE,
        extensions::CommandService::REGULAR, commands);
    extensions::Command action;
    if (service->GetExtensionActionCommand(extension->id(), extensions::ActionInfo::Type::kAction,
        extensions::CommandService::ACTIVE, &action, nullptr) && !action.global()) commands->emplace(action.command_name(), action);
    return !commands->empty();
  }
  bool RegisterAccelerator(const ui::Accelerator& accelerator, const extensions::ExtensionId&,
      const std::string&) override {
    // No global/media hook. Native AppKit/system shortcuts retain first ownership.
    return accelerator.key_code() != ui::VKEY_UNKNOWN && !accelerator.IsMediaKey();
  }
  raw_ptr<content::WebContents> source_;
  Current current_;
};

class PopupProofObserver final : public content::WebContentsObserver {
 public:
  PopupProofObserver(content::WebContents* contents, base::RepeatingClosure changed)
      : content::WebContentsObserver(contents), changed_(std::move(changed)) {}
  void TitleWasSet(content::NavigationEntry*) override { changed_.Run(); }
  void DidStopLoading() override { changed_.Run(); }
 private:
  base::RepeatingClosure changed_;
};

// Chrome installs its own modal-handler delegate during this call. Reclaim the
// exact Arx consent host afterward, before renderer work can run, including a
// deferred background-ready retry. WebContents and media delegates stay Chrome's.
class ConsentExtensionViewHost : public extensions::ExtensionViewHost {
 public:
  ConsentExtensionViewHost(const extensions::Extension* extension, content::BrowserContext* context,
      const GURL& url, std::unique_ptr<Delegate> delegate,
      base::RepeatingCallback<bool()> source_current)
      : extensions::ExtensionViewHost(extension, context, url,
            extensions::mojom::ViewType::kExtensionPopup, std::move(delegate)),
        source_current_(std::move(source_current)) {}
  void LoadInitialURL() override {
    if (source_current_.Run()) extensions::ExtensionViewHost::LoadInitialURL();
    // A source can invalidate while Chrome replaces its modal delegate. Even
    // the disabled helper must reclaim routing so that fallback cannot grant.
    ConfigurePageConsentHosting(host_contents(), source_current_.Run());
  }
 private:
  base::RepeatingCallback<bool()> source_current_;
};

// The popup's real WebContents remains owned by ExtensionViewHost. Only its
// exact HTTP(S) children enter Arx's existing source-bound adoption callback.
class NavigableExtensionViewHost final : public ConsentExtensionViewHost {
 public:
  using Current = base::RepeatingCallback<bool()>;
  NavigableExtensionViewHost(const extensions::Extension* extension,
      content::BrowserContext* context, const GURL& url, std::unique_ptr<Delegate> delegate,
      Current current, ExtensionActionHost::RunScoped scope, ExtensionActionHost::Offer offer)
      : ConsentExtensionViewHost(extension, context, url, std::move(delegate), current),
        current_(std::move(current)), scope_(std::move(scope)), offer_(std::move(offer)) {}

  content::WebContents* OpenURLFromTab(content::WebContents* source,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)> callback) override {
    content::WebContents* result = nullptr;
    scope_.Run(base::BindOnce(&NavigableExtensionViewHost::OpenInScope,
        base::Unretained(this), source, params, std::move(callback), base::Unretained(&result)));
    return result;
  }
  bool ShouldResumeRequestsForCreatedWindow() override { return false; }
  void WebContentsCreated(content::WebContents* source,
      const content::GlobalRenderFrameHostId& opener_id, const std::string&,
      const GURL& target, content::WebContents* child) override {
    auto* opener = content::RenderFrameHost::FromID(opener_id);
    if (source != host_contents() || !child || !NavigationCurrent() || !Initiator(opener) ||
        child->GetBrowserContext() != source->GetBrowserContext() || !HTTP(target)) return;
    if (children_.size() >= 16) children_.erase(children_.begin());
    children_[child] = {child->GetWeakPtr(), opener->GetWeakDocumentPtr(),
        source->GetPrimaryMainFrame()->GetWeakDocumentPtr()};
  }
  content::WebContents* AddNewContents(content::WebContents* source,
      std::unique_ptr<content::WebContents> child, const GURL& target,
      WindowOpenDisposition disposition, const blink::mojom::WindowFeatures&,
      bool, bool* was_blocked) override {
    if (was_blocked) *was_blocked = true;
    content::WebContents* result = nullptr;
    scope_.Run(base::BindOnce(&NavigableExtensionViewHost::AddInScope,
        base::Unretained(this), source, std::move(child), target, disposition,
        was_blocked, base::Unretained(&result)));
    return result;
  }
 private:
  void AddInScope(content::WebContents* source, std::unique_ptr<content::WebContents> child,
    const GURL& target, WindowOpenDisposition disposition, bool* was_blocked,
    content::WebContents** result) {
    auto proof = children_.extract(child.get());
    if (source != host_contents() || !child || !NavigationCurrent() || proof.empty() ||
        proof.mapped().child.get() != child.get() ||
        child->GetBrowserContext() != source->GetBrowserContext() || !Target(target, disposition) ||
        proof.mapped().primary.AsRenderFrameHostIfValid() != source->GetPrimaryMainFrame() ||
        !Initiator(proof.mapped().opener.AsRenderFrameHostIfValid())) return;
    *result = offer_.Run(std::move(child), target, disposition);
    if (!*result) return;
    if (was_blocked) *was_blocked = false;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<content::WebContents> accepted) {
          if (accepted) accepted->ResumeLoadingCreatedWebContents();
        }, (*result)->GetWeakPtr()));
  }
  void OpenInScope(content::WebContents* source, content::OpenURLParams params,
    base::OnceCallback<void(content::NavigationHandle&)> callback, content::WebContents** result) {
    if (source != host_contents() || !NavigationCurrent() || !Target(params.url, params.disposition)) return;
    auto* initiator = params.initiator_frame_token ? content::RenderFrameHost::FromFrameToken(
        content::GlobalRenderFrameHostToken(params.initiator_process_id,
            *params.initiator_frame_token)) : nullptr;
    if (!Initiator(initiator)) return;
    content::WebContents::CreateParams creation(source->GetBrowserContext(), initiator->GetSiteInstance());
    creation.opener_id = initiator->GetGlobalId();
    creation.opened_by_another_window = true;
    creation.initially_hidden = params.disposition == WindowOpenDisposition::NEW_BACKGROUND_TAB;
    auto* accepted = offer_.Run(content::WebContents::Create(creation), params.url, params.disposition);
    if (!accepted) return;
    // Publication can reenter and invalidate the popup. The accepted child is
    // independently owned; all remaining navigation uses the captured params.
    auto weak = accepted->GetWeakPtr();
    auto navigation = accepted->GetController().LoadURLWithParams(
        content::NavigationController::LoadURLParams(params));
    if (callback && navigation) std::move(callback).Run(*navigation);
    *result = weak.get();
  }
  static bool HTTP(const GURL& target) {
    return target.is_valid() && target.SchemeIsHTTPOrHTTPS() &&
        !target.has_username() && !target.has_password() && target.spec().size() <= 32768;
  }
  static bool Target(const GURL& target, WindowOpenDisposition disposition) {
    return HTTP(target) && (disposition == WindowOpenDisposition::NEW_FOREGROUND_TAB ||
        disposition == WindowOpenDisposition::NEW_BACKGROUND_TAB ||
        disposition == WindowOpenDisposition::NEW_WINDOW || disposition == WindowOpenDisposition::NEW_POPUP);
  }
  bool NavigationCurrent() const {
    const auto& url = host_contents()->GetLastCommittedURL();
    return current_.Run() && Visible(host_contents()) && url.SchemeIs("chrome-extension") &&
        url.host() == extension_id();
  }
  bool Initiator(content::RenderFrameHost* frame) const {
    auto* primary = host_contents()->GetPrimaryMainFrame();
    return primary && frame && frame->IsActive() && frame->IsRenderFrameLive() &&
        content::WebContents::FromRenderFrameHost(frame) == host_contents() &&
        frame->GetOutermostMainFrame() == primary;
  }
  struct Child {
    base::WeakPtr<content::WebContents> child;
    content::WeakDocumentPtr opener, primary;
  };
  Current current_;
  ExtensionActionHost::RunScoped scope_;
  ExtensionActionHost::Offer offer_;
  std::map<content::WebContents*, Child> children_;
};

class PopupDelegate final : public extensions::ExtensionViewHost::Delegate {
 public:
  content::WebContents* OpenURL(const content::OpenURLParams&,
      base::OnceCallback<void(content::NavigationHandle&)>) override {
    // No Chrome browser-window fallback may escape the Arx profile/session host.
    return nullptr;
  }
  content::KeyboardEventProcessingResult PreHandleKeyboardEvent(
      content::WebContents*, const input::NativeWebKeyboardEvent&) override {
    return content::KeyboardEventProcessingResult::NOT_HANDLED;
  }
  std::unique_ptr<content::EyeDropper> OpenEyeDropper(
      content::RenderFrameHost*, content::EyeDropperListener*) override { return nullptr; }
  extensions::WindowController* GetExtensionWindowController() override { return nullptr; }
};
}  // namespace

class ExtensionActionHost::Impl final : public extensions::ExtensionRegistryObserver,
                                       public content::WebContentsObserver {
 public:
  Impl(content::WebContents* source, Current current, RunScoped run, Offer offer)
      : content::WebContentsObserver(source), source_(source), current_(std::move(current)),
        run_(std::move(run)), offer_(std::move(offer)), registry_(extensions::ExtensionRegistry::Get(source->GetBrowserContext())) {
    registry_->AddObserver(this);
    const auto weak = weak_factory_.GetWeakPtr();
    commands_ = std::make_unique<SourceExtensionCommands>(source,
        base::BindRepeating([](base::WeakPtr<Impl> owner) {
          return owner && owner->SourceCurrent();
        }, weak));
    target_ = [[ARXExtensionActionTarget alloc]
        initWithEntries:base::BindRepeating([](base::WeakPtr<Impl> owner) {
          return owner ? owner->Entries() : ARXExtensionActionEntries{};
        }, weak)
        choose:base::BindRepeating([](base::WeakPtr<Impl> owner, uint64_t token) {
          if (owner) owner->Choose(token);
        }, weak)];
    // DEV-849: the button is only the native menu's owner and the popup's
    // anchor, never something to see. A titled bezel button here drew a dark
    // "Extensions" pill over every page, at the screen's top-right corner for
    // a page filling the screen. The site menu is the visible entry point. A
    // transparent 1x1 button with no title still owns the menu and anchors the
    // popup; it stays unhidden, because hiding it invalidates the host.
    button_ = [[ARXExtensionActionButton alloc] initWithFrame:NSZeroRect];
    button_.title = @"";
    button_.bordered = NO;
    button_.transparent = YES;
    button_.toolTip = nil;
    button_.refusesFirstResponder = YES;
    button_.target = target_;
    button_.action = @selector(show:);
    button_.identifier = @"ArxExtensionActions";
    button_.accessibilityElement = NO;
    button_.translatesAutoresizingMaskIntoConstraints = NO;
    button_.sourceHidden = ^{ if (weak) weak->Invalidate(); };
    NSView* view = source_->GetNativeView().GetNativeNSView();
    [view addSubview:button_];
    [NSLayoutConstraint activateConstraints:@[
      [button_.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-12],
      [button_.topAnchor constraintEqualToAnchor:view.topAnchor constant:8],
      [button_.widthAnchor constraintEqualToConstant:1],
      [button_.heightAnchor constraintEqualToConstant:1],
    ]];
    Refresh();
  }
  ~Impl() override {
    weak_factory_.InvalidateWeakPtrs();
    button_.sourceHidden = nil;
    [target_ dispose];
    // Nothing runs inside a popup's call now: each closes at once.
    while (!popups_.empty()) {
      auto popup = std::move(popups_.back());
      popups_.pop_back();
      TearDown(*popup);
    }
    lifecycle_.Stop();
    [button_ removeFromSuperview];
    registry_->RemoveObserver(this);
  }
  content::WebContents* PopupContents() const {
    return popups_.empty() ? nullptr : popups_.back()->host_->host_contents();
  }
  bool HostsPopup(const content::WebContents* contents) const {
    return contents && std::any_of(popups_.begin(), popups_.end(), [&](const auto& popup) {
      return popup->host_->host_contents() == contents;
    });
  }
  bool HasFocusedPopup() const {
    // One still loading takes the keyboard as it shows, so it counts already:
    // its page's first chrome.tabs.query can run before that.
    return std::any_of(popups_.begin(), popups_.end(), [](const auto& popup) {
      return !popup->window_ || popup->window_.keyWindow;
    });
  }
  void Invalidate() {
    for (const auto& popup : popups_) {
      ConfigurePageConsentHosting(popup->host_->host_contents(), false);
      popup->generation_ = 0;
    }
    authority_.Clear(); choices_.clear();
    shortcut_epoch_ = NSProcessInfo.processInfo.systemUptime;
    [target_ cancel];
    for (const auto& popup : popups_) PostClose(*popup);
  }

  bool HandleShortcut(const input::NativeWebKeyboardEvent& event) {
    NSEvent* native = event.os_event.Get();
    NSView* view = source_->GetNativeView().GetNativeNSView();
    if (!native || event.skip_if_unhandled ||
        event.GetType() != blink::WebInputEvent::Type::kRawKeyDown ||
        native.type != NSEventTypeKeyDown || native.isARepeat || native.window != view.window ||
        (event.GetModifiers() & (blink::WebInputEvent::kIsComposing | blink::WebInputEvent::kIsAutoRepeat)) ||
        !SourceCurrent() || !KeyboardFocused()) return false;
    const auto accelerator = ui::GetAcceleratorFromNativeWebKeyboardEvent(event);
    input::NativeWebKeyboardEvent original{base::apple::OwnedNSEvent(native)};
    if (accelerator != ui::GetAcceleratorFromNativeWebKeyboardEvent(original)) return false;
    std::string id, command;
    if (!commands_->Match(accelerator, &id, &command)) return false;
    scoped_refptr<const extensions::Extension> extension = registry_->enabled_extensions().GetByID(id);
    auto* primary = source_->GetPrimaryMainFrame();
    auto* frame = source_->GetFocusedFrame();
    // DEV-974: Chromium learns the focused frame only from the renderer's
    // DidFocusFrame, and a navigation clears it. The page's view already holds
    // first responder in the key window (KeyboardFocused), so a key pressed
    // before that answer belongs to the main frame.
    if (!frame) frame = primary;
    if (!Allowed(extension.get()) || !frame || !frame->IsActive() || !frame->IsRenderFrameLive() ||
        frame->GetOutermostMainFrame() != primary) return false;
    if (!shortcut_replay_.Consume(reinterpret_cast<uintptr_t>(native), native.timestamp,
        shortcut_epoch_, NSProcessInfo.processInfo.systemUptime)) return false;
    // Retaining the exact NSEvent prevents pointer reuse and duplicate dispatch.
    // DevTools/MCP key events without that event never obtain command authority.
    shortcut_event_ = event.os_event;
    Choice choice{extension, primary->GetWeakDocumentPtr(), command, accelerator, current_.Run(), shortcut_epoch_, true};
    bool handled = false;
    run_.Run(base::BindOnce(&Impl::RunCommand, weak_factory_.GetWeakPtr(),
        std::move(choice), base::Unretained(&handled)));
    return handled;
  }

  // ABI48 (DEV-828). The app's own click, such as a site menu tile: no native
  // menu token, so the page itself must be current, in a visible window while
  // Arx is active. The popup anchors at the app's screen point, kept inside the
  // page's window.
  ArxExtensionActionRunStatus RunAppAction(const std::string& id, double screen_x, double screen_y) {
    if (popup_call_depth_ || !NSApp.active || !SourceCurrent())
      return ARX_EXTENSION_ACTION_RUN_UNAVAILABLE;
    NSView* view = source_->GetNativeView().GetNativeNSView();
    NSWindow* window = view.window;
    NSView* content = window.contentView;
    if (!window || !content || NSIsEmptyRect(content.bounds))
      return ARX_EXTENSION_ACTION_RUN_UNAVAILABLE;
    if (!std::isfinite(screen_x) || !std::isfinite(screen_y))
      return ARX_EXTENSION_ACTION_RUN_INVALID;
    scoped_refptr<const extensions::Extension> extension =
        registry_->enabled_extensions().GetByID(id);
    auto* action = extension ? Action(extension.get()) : nullptr;
    const int tab_id = sessions::SessionTabHelper::IdForTab(source_).id();
    if (!Allowed(extension.get()) || !action || !action->GetIsVisible(tab_id))
      return ARX_EXTENSION_ACTION_RUN_INVALID;
    NSPoint point = [content convertPoint:[window convertPointFromScreen:NSMakePoint(screen_x, screen_y)]
                                 fromView:nil];
    const NSRect bounds = content.bounds;
    point.x = std::max(NSMinX(bounds), std::min(point.x, NSMaxX(bounds) - 1));
    point.y = std::max(NSMinY(bounds), std::min(point.y, NSMaxY(bounds) - 1));
    auto* primary = source_->GetPrimaryMainFrame();
    Choice choice{extension, primary->GetWeakDocumentPtr(), {}, {}, current_.Run(), shortcut_epoch_, false};
    ArxExtensionActionRunStatus status = ARX_EXTENSION_ACTION_RUN_UNAVAILABLE;
    // The adoption scope runs it now, or not at all while the page is busy.
    run_.Run(base::BindOnce([](base::WeakPtr<Impl> owner, Choice choice, NSRect anchor,
                               ArxExtensionActionRunStatus* status) {
      if (owner) *status = owner->RunAction(std::move(choice), anchor);
    }, weak_factory_.GetWeakPtr(), std::move(choice), NSMakeRect(point.x, point.y, 1, 1),
        base::Unretained(&status)));
    return status;
  }

  // DEV-824 follow-up. The icon setIcon or a declarative rule chose for this
  // tab, as Chrome's ExtensionActionIconFactory picks it before the default.
  // The default icon loads asynchronously and shows a placeholder until then,
  // so it's left to the app, which reads the manifest's files.
  std::vector<uint8_t> ActionIcon(const std::string& id, float scale) const {
    if (scale != 1 && scale != 2) return {};
    scoped_refptr<const extensions::Extension> extension =
        registry_->enabled_extensions().GetByID(id);
    auto* action = extension ? Action(extension.get()) : nullptr;
    if (!Allowed(extension.get()) || !action) return {};
    const int tab_id = sessions::SessionTabHelper::IdForTab(source_).id();
    gfx::Image image = action->GetExplicitlySetIcon(tab_id);
    if (image.IsEmpty()) image = action->GetDeclarativeIcon(tab_id);
    if (image.IsEmpty()) return {};
    const gfx::ImageSkiaRep& rep = image.AsImageSkia().GetRepresentation(scale);
    if (rep.is_null()) return {};
    const SkBitmap& bitmap = rep.GetBitmap();
    if (bitmap.drawsNothing() || bitmap.width() > 512 || bitmap.height() > 512) return {};
    auto png = gfx::PNGCodec::EncodeBGRASkBitmap(bitmap, /*discard_transparency=*/false);
    return png ? std::move(*png) : std::vector<uint8_t>{};
  }

 private:
  struct Choice {
    scoped_refptr<const extensions::Extension> extension;
    content::WeakDocumentPtr document;
    std::string command;
    ui::Accelerator accelerator;
    uint64_t generation;
    double host_epoch;
    bool native_key;
  };
  bool SourceCurrent() const {
    auto* frame = source_->GetPrimaryMainFrame();
    return current_.Run() && frame && frame->IsActive() && frame->IsRenderFrameLive() &&
        Visible(source_);
  }
  bool KeyboardFocused() const {
    NSView* view = source_->GetNativeView().GetNativeNSView();
    NSWindow* window = view.window;
    NSResponder* responder = window.firstResponder;
    return view && window && window == NSApp.keyWindow && window.keyWindow && Visible(source_) &&
        [responder isKindOfClass:[NSView class]] &&
        (responder == view || [(NSView*)responder isDescendantOf:view]);
  }
  bool MenuHostIsKey() const {
    NSView* view = source_->GetNativeView().GetNativeNSView();
    return button_.window && button_.window == view.window && button_.window.keyWindow;
  }
  void RunCommand(Choice choice, bool* handled) {
    if (!(choice.native_key ? KeyboardFocused() : MenuHostIsKey()) || !SourceCurrent() || !Allowed(choice.extension.get()) ||
        current_.Run() != choice.generation || shortcut_epoch_ != choice.host_epoch ||
        choice.document.AsRenderFrameHostIfValid() != source_->GetPrimaryMainFrame()) return;
    std::string id, command;
    if (!commands_->Match(choice.accelerator, &id, &command) || id != choice.extension->id() ||
        command != choice.command) return;
    if (extensions::Command::IsActionRelatedCommand(command)) {
      *handled = true;
      RunAction(std::move(choice));
    } else {
      *handled = commands_->Dispatch(choice.accelerator, id, command);
    }
  }
  bool Allowed(const extensions::Extension* extension) const {
    auto* profile = Profile::FromBrowserContext(source_->GetBrowserContext());
    return extension && ExtensionRunsInContext(*extension, profile) && ExtensionViewsAvailable() &&
        extension->manifest_version() == 3 &&
        !extensions::Manifest::IsComponentLocation(extension->location()) &&
        !extensions::ExtensionPrefs::Get(profile)->DidExtensionEscalatePermissions(extension->id()) &&
        registry_->enabled_extensions().GetByID(extension->id()) == extension;
  }
  // DEV-956: as Chrome's CreateViewHostForIncognito, a spanning extension's
  // popup over a private page runs in the ordinary profile the extension runs
  // in; only a split-mode extension's runs in the private context. A link it
  // opens would land in that ordinary profile, so the source's offer refuses it.
  Profile* PopupProfile(const extensions::Extension& extension) const {
    auto* profile = Profile::FromBrowserContext(source_->GetBrowserContext());
    return profile->IsOffTheRecord() && !extensions::IncognitoInfo::IsSplitMode(&extension)
        ? profile->GetOriginalProfile() : profile;
  }
  extensions::ExtensionAction* Action(const extensions::Extension* extension) const {
    return extensions::ExtensionActionManager::Get(source_->GetBrowserContext())->GetExtensionAction(*extension);
  }
  void Refresh() {
    bool available = false;
    for (const auto& extension : registry_->enabled_extensions()) {
      if (!Allowed(extension.get())) continue;
      ui::CommandMap commands;
      extensions::CommandService::Get(source_->GetBrowserContext())->GetNamedCommands(extension->id(),
          extensions::CommandService::ACTIVE, extensions::CommandService::REGULAR, &commands);
      if (Action(extension.get()) || !commands.empty()) { available = true; break; }
    }
    button_.hidden = !available;
    button_.menu = available ? [target_ menu] : nil;
  }
  ARXExtensionActionEntries Entries() {
    Invalidate();
    ARXExtensionActionEntries result;
    if (!SourceCurrent()) return {{0, "Extensions unavailable for this page"}};
    const auto generation = current_.Run();
    const auto document = source_->GetPrimaryMainFrame()->GetWeakDocumentPtr();
    const int tab_id = sessions::SessionTabHelper::IdForTab(source_).id();
    for (const auto& extension : registry_->enabled_extensions()) {
      if (!Allowed(extension.get())) continue;
      // Named command presentation remains available for commands-only extensions.
      const size_t first_command = result.size();
      ui::CommandMap named;
      extensions::CommandService::Get(source_->GetBrowserContext())->GetNamedCommands(extension->id(),
          extensions::CommandService::ACTIVE, extensions::CommandService::REGULAR, &named);
      for (const auto& [name, command] : named) {
        std::string target_id, target_name;
        if (!commands_->Match(command.accelerator(), &target_id, &target_name) ||
            target_id != extension->id() || target_name != name) continue;
        const auto token = authority_.Issue(generation);
        if (!token) break;
        choices_.emplace(token, Choice{extension, document, name, command.accelerator(), generation, shortcut_epoch_, false});
        const auto description = command.description().empty() ? name : base::UTF16ToUTF8(command.description());
        result.emplace_back(token, extension->name().substr(0, 4096) + ": " + description.substr(0, 4096) +
            " (" + base::UTF16ToUTF8(command.accelerator().GetShortcutText()) + ")");
      }
      auto* action = Action(extension.get());
      if (!action || !action->GetIsVisible(tab_id)) continue;
      auto* side_panel = extensions::SidePanelService::Get(source_->GetBrowserContext());
      if (side_panel && side_panel->HasSidePanelActionForTab(*extension, tab_id)) {
        result.emplace_back(0, extension->name().substr(0, 4096) + " (side panel unavailable)");
        continue;
      }
      auto* runner = extensions::ExtensionActionRunner::GetForWebContents(source_);
      extensions::SitePermissionsHelper permissions(source_->GetBrowserContext());
      if (!runner || permissions.PageNeedsRefreshToRun(runner->GetBlockedActions(extension->id()))) {
        result.emplace_back(0, extension->name().substr(0, 4096) + " (page reload consent unavailable)");
        continue;
      }
      const uint64_t token = authority_.Issue(generation);
      if (!token) break;
      choices_.emplace(token, Choice{extension, document, {}, {}, generation, shortcut_epoch_, false});
      std::string label = extension->name().substr(0, 4096);
      extensions::Command command;
      if (extensions::CommandService::Get(source_->GetBrowserContext())->GetExtensionActionCommand(
          extension->id(), extensions::ActionInfo::Type::kAction,
          extensions::CommandService::ACTIVE, &command, nullptr)) {
        label += " (" + base::UTF16ToUTF8(command.accelerator().GetShortcutText()) + ")";
      }
      result.insert(result.begin() + first_command, {token, std::move(label)});
    }
    return result;
  }
  void Choose(uint64_t token) {
    auto found = choices_.find(token);
    if (found == choices_.end()) return;
    Choice choice = found->second;
    const bool source_current = SourceCurrent() && button_.window.keyWindow &&
        choice.document.AsRenderFrameHostIfValid() == source_->GetPrimaryMainFrame();
    const bool valid = authority_.Consume(token, current_.Run(), source_current,
        Allowed(choice.extension.get()));
    choices_.clear();
    if (!valid) return;
    run_.Run(base::BindOnce(&Impl::RunChoice, weak_factory_.GetWeakPtr(), std::move(choice)));
  }
  void RunChoice(Choice choice) {
    if (choice.command.empty()) RunAction(std::move(choice));
    else {
      bool handled = false;
      RunCommand(std::move(choice), &handled);
    }
  }
  // anchor, in the source window's content view, is set for the app's own
  // click (ABI48); without it the popup anchors at the native button.
  ArxExtensionActionRunStatus RunAction(Choice choice, std::optional<NSRect> anchor = std::nullopt) {
    constexpr auto kUnavailable = ARX_EXTENSION_ACTION_RUN_UNAVAILABLE;
    if (popup_call_depth_) return kUnavailable;
    if (!SourceCurrent() || current_.Run() != choice.generation ||
        choice.host_epoch != shortcut_epoch_ || choice.document.AsRenderFrameHostIfValid() != source_->GetPrimaryMainFrame())
      return kUnavailable;
    if (!Allowed(choice.extension.get())) return ARX_EXTENSION_ACTION_RUN_INVALID;
    auto* runner = extensions::ExtensionActionRunner::GetForWebContents(source_);
    auto* action = Action(choice.extension.get());
    if (!runner) return kUnavailable;
    if (!action) return ARX_EXTENSION_ACTION_RUN_INVALID;
    extensions::SitePermissionsHelper permissions(source_->GetBrowserContext());
    if (permissions.PageNeedsRefreshToRun(runner->GetBlockedActions(choice.extension->id())))
      return ARX_EXTENSION_ACTION_RUN_REFUSED;
    const int tab_id = sessions::SessionTabHelper::IdForTab(source_).id();
    // Side-panel dispatch requires a separate real host. Refuse before activeTab grants.
    auto* side_panel = extensions::SidePanelService::Get(source_->GetBrowserContext());
    if (side_panel && side_panel->HasSidePanelActionForTab(*choice.extension, tab_id))
      return ARX_EXTENSION_ACTION_RUN_REFUSED;
    if (action->HasPopup(tab_id)) {
      const auto url = action->GetPopupUrl(tab_id);
      if (!url.is_valid() || url.host() != choice.extension->id() ||
          !IsEnabledExtensionPage(PopupProfile(*choice.extension), url))
        return ARX_EXTENSION_ACTION_RUN_INVALID;
      // DEV-1316: one popup per extension over a page. Asked for again, the
      // open one comes forward with the keyboard.
      if (Popup* open = FindPopup(choice.extension->id());
          open && open->window_ && PopupCurrent(*open)) {
        FocusPopup(*open);
        return ARX_EXTENSION_ACTION_RUN_POPUP;
      }
    }
    const auto result = runner->RunAction(choice.extension.get(), true);
    if (result != extensions::ExtensionAction::ShowAction::kShowPopup)
      return ARX_EXTENSION_ACTION_RUN_CLICKED;
    if (!SourceCurrent() ||
        choice.document.AsRenderFrameHostIfValid() != source_->GetPrimaryMainFrame() ||
        !Allowed(choice.extension.get())) return kUnavailable;
    action = Action(choice.extension.get());
    if (!action) return kUnavailable;
    const auto url = action->GetPopupUrl(tab_id);
    if (!IsEnabledExtensionPage(PopupProfile(*choice.extension), url) ||
        url.host() != choice.extension->id()) return kUnavailable;
    // The extension's own popup, still loading or no longer current, is
    // replaced. Another extension's closes as losing focus to this one would
    // close it, so one the person moved stays.
    for (auto it = popups_.begin(); it != popups_.end();) {
      Popup& other = **it;
      if (other.extension_->id() == choice.extension->id() || !StaysOnFocusLoss(other)) {
        auto closing = std::move(*it);
        it = popups_.erase(it);
        TearDown(*closing);
      } else {
        ++it;
      }
    }
    if (popups_.size() >= kMaximumPopups) return kUnavailable;
    const std::optional<NSPoint> point = AnchorInWindow(anchor);
    if (!point) return kUnavailable;
    auto popup = std::make_unique<Popup>(this, ++next_popup_id_, choice.extension,
        choice.document, current_.Run(), *point);
    const uint64_t id = popup->id_;
    popup->host_ = std::make_unique<NavigableExtensionViewHost>(choice.extension.get(),
        PopupProfile(*choice.extension), url, std::make_unique<PopupDelegate>(),
        base::BindRepeating([](base::WeakPtr<Impl> owner, uint64_t id) {
          Popup* popup = owner ? owner->FindPopup(id) : nullptr;
          return popup && owner->PopupCurrent(*popup);
        }, weak_factory_.GetWeakPtr(), id),
        base::BindRepeating(&Impl::RunPopupScoped, weak_factory_.GetWeakPtr(), id), offer_);
    popup->host_->set_view(popup.get());
    popup->proof_observer_ = std::make_unique<PopupProofObserver>(popup->host_->host_contents(),
        base::BindRepeating(&Impl::UpdateFixtureProof, weak_factory_.GetWeakPtr(), id));
    // The page's window.close(), and Chrome closing the host.
    popup->host_->SetCloseHandler(base::BindOnce([](base::WeakPtr<Impl> owner, uint64_t id,
                                                    extensions::ExtensionHost*) {
      if (Popup* popup = owner ? owner->FindPopup(id) : nullptr) owner->PostClose(*popup);
    }, weak_factory_.GetWeakPtr(), id));
    NSView* view = popup->host_->host_contents()->GetNativeView().GetNativeNSView();
    view.frame = NSMakeRect(0, 0, 320, 240);
    content::WebContents* contents = popup->host_->host_contents();
    auto* host = popup->host_.get();
    popups_.push_back(std::move(popup));
    if (!lifecycle_.IsRunning())
      lifecycle_.Start(FROM_HERE, base::Milliseconds(100), this, &Impl::CheckPopups);
    ConfigurePageConsentHosting(contents, true);
    host->CreateRendererSoon();
    return ARX_EXTENSION_ACTION_RUN_POPUP;
  }

  // DEV-1316. An extension's action popup: the ExtensionViewHost Chrome's
  // popup would have, in a small window of its own instead of a popover.
  class Popup final : public extensions::ExtensionView {
   public:
    Popup(Impl* owner, uint64_t id, scoped_refptr<const extensions::Extension> extension,
          content::WeakDocumentPtr document, uint64_t generation, NSPoint anchor)
        : owner_(owner), id_(id), extension_(std::move(extension)),
          document_(document), generation_(generation), anchor_(anchor) {}
    gfx::NativeView GetNativeView() override { return host_->host_contents()->GetNativeView(); }
    void ResizeDueToAutoResize(content::WebContents*, const gfx::Size& size) override {
      owner_->ResizePopup(*this, size);
    }
    void RenderFrameCreated(content::RenderFrameHost*) override {
      if (!owner_->PopupCurrent(*this)) owner_->PostClose(*this);
    }
    bool HandleKeyboardEvent(content::WebContents*,
                             const input::NativeWebKeyboardEvent& event) override {
      return owner_->PopupKey(*this, event);
    }
    void OnLoaded() override { owner_->ShowPopup(*this); }

    const raw_ptr<Impl> owner_;
    const uint64_t id_;
    const scoped_refptr<const extensions::Extension> extension_;
    const content::WeakDocumentPtr document_;
    uint64_t generation_;
    // Where the window hangs from, the middle of its top edge, from the page
    // window's origin: a child window moves with its parent, so the anchor
    // does too (Codex review).
    const NSPoint anchor_;
    std::unique_ptr<extensions::ExtensionViewHost> host_;
    std::unique_ptr<PopupProofObserver> proof_observer_;
    ExtensionPopupEpoch epoch_;
    NSWindow* __strong window_ = nil;
    ARXExtensionPopupWindowObserver* __strong observer_ = nil;
    NSSize size_ = NSMakeSize(320, 240);
    // The person moved the window; it keeps its place and, by default, stays
    // open when it loses focus.
    bool moved_ = false;
    bool positioning_ = false;
    bool close_pending_ = false;
  };

  Popup* FindPopup(uint64_t id) const {
    for (const auto& popup : popups_) if (popup->id_ == id) return popup.get();
    return nullptr;
  }
  Popup* FindPopup(const std::string& extension_id) const {
    for (const auto& popup : popups_) if (popup->extension_->id() == extension_id) return popup.get();
    return nullptr;
  }
  // Where the popover's arrow would have pointed, from the page window's
  // origin in screen points: the bottom middle of the app's anchor, or of the
  // native button.
  std::optional<NSPoint> AnchorInWindow(std::optional<NSRect> anchor) const {
    NSWindow* window = source_->GetNativeView().GetNativeNSView().window;
    NSView* content = window.contentView;
    if (!window || !content) return std::nullopt;
    NSRect rect = anchor ? [content convertRect:*anchor toView:nil]
                         : [button_ convertRect:button_.bounds toView:nil];
    if (!anchor && button_.window != window) return std::nullopt;
    rect = [window convertRectToScreen:rect];
    return NSMakePoint(NSMidX(rect) - NSMinX(window.frame), NSMinY(rect) - NSMinY(window.frame));
  }
  bool StaysOnFocusLoss(const Popup& popup) const {
    switch (Presenter().closing) {
      case ARX_EXTENSION_POPUP_STAYS_OPEN: return true;
      case ARX_EXTENSION_POPUP_CLOSES_ON_FOCUS_LOSS: return false;
      default: return popup.moved_;
    }
  }
  void ShowPopup(Popup& popup) {
    if (!PopupCurrent(popup)) { PostClose(popup); return; }
    if (popup.window_) return;
    NSWindow* source = source_->GetNativeView().GetNativeNSView().window;
    content::WebContents* contents = popup.host_->host_contents();
    NSView* view = contents->GetNativeView().GetNativeNSView();
    if (!source || !view) { PostClose(popup); return; }
    NSWindow* window = MakeWindow(popup, view);
    if (!window) { PostClose(popup); return; }
    popup.window_ = window;
    const auto weak = weak_factory_.GetWeakPtr();
    const uint64_t id = popup.id_;
    popup.observer_ = [[ARXExtensionPopupWindowObserver alloc] initWithWindow:window
        resigned:base::BindRepeating([](base::WeakPtr<Impl> owner, uint64_t id) {
          // Focus settles first: a sheet or the popup's own DevTools may take it.
          base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
              base::BindOnce(&Impl::CheckFocus, owner, id));
        }, weak, id)
        moved:base::BindRepeating([](base::WeakPtr<Impl> owner, uint64_t id) {
          Popup* popup = owner ? owner->FindPopup(id) : nullptr;
          if (popup && !popup->positioning_) popup->moved_ = true;
        }, weak, id)
        closed:base::BindRepeating([](base::WeakPtr<Impl> owner, uint64_t id) {
          // The person's Close, or AppKit closing it.
          if (Popup* popup = owner ? owner->FindPopup(id) : nullptr) owner->PostClose(*popup);
        }, weak, id)];
    Place(popup);
    // Above the window it was opened from, and moving with it.
    [source addChildWindow:window ordered:NSWindowAbove];
    [window makeKeyAndOrderFront:nil];
    MovePopupToBack(popup);
    contents->WasShown();
    if (auto* widget = contents->GetRenderWidgetHostView()) {
      widget->EnableAutoResize(gfx::Size(kPopupMinimumSide, kPopupMinimumSide),
                               gfx::Size(kPopupMaximumWidth, kPopupMaximumHeight));
      widget->Focus();
    }
  }
  // DEV-1316: the icon the extension's toolbar button shows on this page, for
  // the window's header: the one setIcon or a declarative rule chose, as PNG,
  // else the path of the action's default icon or the manifest icon nearest
  // 64 pixels, joined to the extension's folder and never resolved, so nothing
  // touches the disk here. A path with ".." is left out; the app then draws
  // the extension's letter, as the site menu's tile does.
  std::string PopupIconPath(const extensions::Extension& extension) const {
    const ExtensionIconSet* sets[2] = {nullptr, &extensions::IconsInfo::GetIcons(&extension)};
    if (const auto* action = extensions::ActionInfo::GetExtensionActionInfo(&extension))
      sets[0] = &action->default_icon;
    for (const auto* icons : sets) {
      if (!icons) continue;
      std::string relative = icons->Get(64, ExtensionIconSet::Match::kBigger);
      if (relative.empty()) relative = icons->Get(64, ExtensionIconSet::Match::kSmaller);
      if (relative.empty() || relative.find("..") != std::string::npos) continue;
      const auto path = extension.path().Append(base::FilePath::FromUTF8Unsafe(relative)).value();
      if (base::IsStringUTF8(path) && path.size() <= 4096) return path;
    }
    return {};
  }
  // The app's window when it gives one, else the engine's own panel.
  NSWindow* MakeWindow(const Popup& popup, NSView* view) {
    const std::string title = popup.extension_->name().substr(0, 256);
    const auto& presenter = Presenter();
    if (presenter.make_window) {
      const std::vector<uint8_t> png = ActionIcon(popup.extension_->id(), 2);
      const std::string icon_path = png.empty() ? PopupIconPath(*popup.extension_) : std::string();
      void* made = presenter.make_window(presenter.context, (__bridge void*)view, title.c_str(),
                                         png.empty() ? nullptr : png.data(), png.size(),
                                         icon_path.c_str(), popup.size_.width,
                                         popup.size_.height);
      id object = made ? CFBridgingRelease(made) : nil;
      if ([object isKindOfClass:[NSWindow class]] && view.window == object) {
        NSWindow* window = object;
        window.releasedWhenClosed = NO;
        return window;
      }
      // Not a window holding the view: the engine's own takes its place.
      [view removeFromSuperview];
      if ([object isKindOfClass:[NSWindow class]]) [(NSWindow*)object close];
    }
    ARXExtensionPopupPanel* panel = [[ARXExtensionPopupPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, popup.size_.width, popup.size_.height)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskUtilityWindow
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.releasedWhenClosed = NO;
    panel.hidesOnDeactivate = NO;
    panel.becomesKeyOnlyIfNeeded = NO;
    panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.title = base::SysUTF8ToNSString(title);
    view.frame = NSMakeRect(0, 0, popup.size_.width, popup.size_.height);
    panel.contentView = view;
    return panel;
  }
  // Hangs the window from its anchor, inside the screen's visible frame, until
  // the person moves it.
  void Place(Popup& popup) {
    NSWindow* window = popup.window_;
    NSWindow* source = source_->GetNativeView().GetNativeNSView().window;
    if (!window || !source || popup.moved_) return;
    const NSRect frame = window.frame;
    const NSPoint anchor = NSMakePoint(NSMinX(source.frame) + popup.anchor_.x,
                                       NSMinY(source.frame) + popup.anchor_.y);
    NSScreen* screen = source.screen ?: NSScreen.mainScreen;
    for (NSScreen* candidate in NSScreen.screens) {
      if (NSPointInRect(anchor, candidate.frame)) { screen = candidate; break; }
    }
    const NSRect visible = screen ? screen.visibleFrame : frame;
    NSPoint origin = NSMakePoint(anchor.x - NSWidth(frame) / 2, anchor.y - NSHeight(frame));
    origin.x = std::max(NSMinX(visible), std::min(origin.x, NSMaxX(visible) - NSWidth(frame)));
    origin.y = std::max(NSMinY(visible), std::min(origin.y, NSMaxY(visible) - NSHeight(frame)));
    popup.positioning_ = true;
    [window setFrameOrigin:origin];
    popup.positioning_ = false;
  }
  void ResizePopup(Popup& popup, const gfx::Size& size) {
    if (!PopupCurrent(popup)) { PostClose(popup); return; }
    popup.size_ = NSMakeSize(std::clamp(size.width(), kPopupMinimumSide, kPopupMaximumWidth),
                             std::clamp(size.height(), kPopupMinimumSide, kPopupMaximumHeight));
    NSWindow* window = popup.window_;
    if (!window) return;
    const auto& presenter = Presenter();
    popup.positioning_ = true;
    if (presenter.make_window && presenter.resize_window &&
        ![window isKindOfClass:[ARXExtensionPopupPanel class]]) {
      presenter.resize_window(presenter.context, (__bridge void*)window, popup.size_.width,
                              popup.size_.height);
    } else {
      const NSRect frame = window.frame;
      [window setContentSize:popup.size_];
      // Its top edge stays where it was.
      [window setFrameTopLeftPoint:NSMakePoint(NSMinX(frame), NSMaxY(frame))];
    }
    popup.positioning_ = false;
    Place(popup);
  }
  void FocusPopup(Popup& popup) {
    NSWindow* window = popup.window_;
    if (!window) return;
    if (window.miniaturized) [window deminiaturize:nil];
    [window makeKeyAndOrderFront:nil];
    MovePopupToBack(popup);
    popup.host_->host_contents()->Focus();
  }
  // The last popup is the one PopupContents names.
  void MovePopupToBack(const Popup& popup) {
    auto found = std::find_if(popups_.begin(), popups_.end(),
        [&](const auto& candidate) { return candidate.get() == &popup; });
    if (found != popups_.end()) std::rotate(found, found + 1, popups_.end());
  }
  // Chrome's popup closes on an Escape the page didn't take.
  bool PopupKey(Popup& popup, const input::NativeWebKeyboardEvent& event) {
    constexpr int kModifiers = blink::WebInputEvent::kShiftKey | blink::WebInputEvent::kControlKey |
        blink::WebInputEvent::kAltKey | blink::WebInputEvent::kMetaKey;
    if (event.GetType() != blink::WebInputEvent::Type::kRawKeyDown ||
        event.windows_key_code != ui::VKEY_ESCAPE || (event.GetModifiers() & kModifiers))
      return false;
    PostClose(popup);
    return true;
  }
  // A popup that lost focus closes, unless the rule keeps it, it has its
  // focus back, a sheet or modal panel of its own (a file chooser) has it, or
  // DevTools inspects it.
  void CheckFocus(uint64_t id) {
    Popup* popup = FindPopup(id);
    if (!popup || !popup->window_ || StaysOnFocusLoss(*popup)) return;
    NSWindow* window = popup->window_;
    NSWindow* key = NSApp.keyWindow;
    if (window.keyWindow || window.attachedSheet || NSApp.modalWindow) return;
    if (key && (key.sheetParent == window || key.parentWindow == window)) return;
    if (content::DevToolsAgentHost::IsDebuggerAttached(popup->host_->host_contents())) return;
    PostClose(*popup);
  }
  void RunPopupScoped(uint64_t id, base::OnceClosure action) {
    run_.Run(base::BindOnce([](base::WeakPtr<Impl> owner, uint64_t id, base::OnceClosure action) {
      Popup* popup = owner ? owner->FindPopup(id) : nullptr;
      if (!popup || !owner->PopupCurrent(*popup)) return;
      ++owner->popup_call_depth_;
      std::move(action).Run();
      --owner->popup_call_depth_;
      if (owner->popup_call_depth_) return;
      for (const auto& pending : owner->popups_) {
        if (!pending->close_pending_) continue;
        pending->close_pending_ = false;
        owner->PostClose(*pending);
      }
    }, weak_factory_.GetWeakPtr(), id, std::move(action)));
  }
  void PostClose(Popup& popup) {
    const auto epoch = popup.epoch_.ScheduleClose();
    if (!epoch) return;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](base::WeakPtr<Impl> owner, uint64_t id, uint64_t epoch) {
          Popup* popup = owner ? owner->FindPopup(id) : nullptr;
          if (popup && popup->epoch_.Current(epoch)) owner->ClosePopup(*popup);
        }, weak_factory_.GetWeakPtr(), popup.id_, epoch));
  }
  void ClosePopup(Popup& popup) {
    if (popup_call_depth_) {
      popup.close_pending_ = true;
      popup.epoch_.Advance();
      return;
    }
    auto found = std::find_if(popups_.begin(), popups_.end(),
        [&](const auto& candidate) { return candidate.get() == &popup; });
    if (found == popups_.end()) return;
    auto closing = std::move(*found);
    popups_.erase(found);
    TearDown(*closing);
    if (popups_.empty()) lifecycle_.Stop();
  }
  static void TearDown(Popup& popup) {
    popup.epoch_.Advance();
    [popup.observer_ stop];
    popup.observer_ = nil;
    NSWindow* window = popup.window_;
    popup.window_ = nil;
    if (window) {
      [window.parentWindow removeChildWindow:window];
      [window orderOut:nil];
      [window close];
    }
    popup.proof_observer_.reset();
    if (popup.host_) {
      content::WebContents* contents = popup.host_->host_contents();
      TearDownPageConsentHosting(contents);
      [contents->GetNativeView().GetNativeNSView() removeFromSuperview];
      popup.host_->set_view(nullptr);
    }
    popup.host_.reset();
  }
  void CheckPopups() {
    if (popups_.empty()) { lifecycle_.Stop(); return; }
    if (!SourceCurrent()) { Invalidate(); return; }
    for (const auto& popup : popups_) if (!PopupCurrent(*popup)) PostClose(*popup);
  }
  void UpdateFixtureProof(uint64_t id) {
    Popup* popup = FindPopup(id);
    if (!popup || !PopupCurrent(*popup) || !IsOwnedExtensionFixture(popup->extension_.get())) return;
    content::WebContents* contents = popup->host_->host_contents();
    const auto& url = contents->GetLastCommittedURL();
    if (url.host() != popup->extension_->id() || url.path() != "/popup.html") return;
    const auto title = base::UTF16ToUTF8(contents->GetTitle());
    const auto prefix = "ARX_EXTENSION_ACTION:" + popup->extension_->id() + ":count=";
    // DEV-1316: the window smoke's fixture adds what was typed, as ":input=…".
    if (!title.starts_with(prefix) || title.size() > prefix.size() + 40) return;
    contents->GetNativeView().GetNativeNSView().identifier = base::SysUTF8ToNSString(title);
  }
  bool PopupCurrent(const Popup& popup) const {
    return popup.host_ && SourceCurrent() && popup.generation_ && current_.Run() == popup.generation_ &&
        popup.document_.AsRenderFrameHostIfValid() == source_->GetPrimaryMainFrame() &&
        Allowed(popup.extension_.get());
  }
  void DidStopLoading() override { Refresh(); }
  void OnExtensionLoaded(content::BrowserContext*, const extensions::Extension*) override { Refresh(); }
  void OnExtensionUnloaded(content::BrowserContext*, const extensions::Extension*, extensions::UnloadedExtensionReason) override {
    Invalidate(); Refresh();
  }
  void DidStartNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame()) Invalidate();
  }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override { Invalidate(); }

  raw_ptr<content::WebContents> source_;
  Current current_;
  RunScoped run_;
  Offer offer_;
  unsigned popup_call_depth_ = 0;
  raw_ptr<extensions::ExtensionRegistry> registry_;
  ExtensionActionAuthority authority_;
  std::unique_ptr<SourceExtensionCommands> commands_;
  ExtensionShortcutReplayGuard shortcut_replay_;
  gfx::NativeEvent shortcut_event_;
  double shortcut_epoch_ = NSProcessInfo.processInfo.systemUptime;
  std::map<uint64_t, Choice> choices_;
  // DEV-1316: open popups, the one shown or brought forward last at the back.
  std::vector<std::unique_ptr<Popup>> popups_;
  uint64_t next_popup_id_ = 0;
  base::RepeatingTimer lifecycle_;
  ARXExtensionActionTarget* __strong target_;
  ARXExtensionActionButton* __strong button_;
  base::WeakPtrFactory<Impl> weak_factory_{this};
};
ExtensionActionHost::ExtensionActionHost(content::WebContents* source, Current current, RunScoped run, Offer offer)
    : impl_(std::make_unique<Impl>(source, std::move(current), std::move(run), std::move(offer))) {}
ExtensionActionHost::~ExtensionActionHost() = default;
void ExtensionActionHost::Invalidate() { impl_->Invalidate(); }
bool ExtensionActionHost::HandleShortcut(const input::NativeWebKeyboardEvent& event) { return impl_->HandleShortcut(event); }
content::WebContents* ExtensionActionHost::PopupContents() const { return impl_->PopupContents(); }
bool ExtensionActionHost::HostsPopup(const content::WebContents* contents) const {
  return impl_->HostsPopup(contents);
}
bool ExtensionActionHost::HasFocusedPopup() const { return impl_->HasFocusedPopup(); }
ArxExtensionActionRunStatus ExtensionActionHost::RunAction(const std::string& extension_id,
                                                           double screen_x, double screen_y) {
  return impl_->RunAppAction(extension_id, screen_x, screen_y);
}
std::vector<uint8_t> ExtensionActionHost::ActionIcon(const std::string& extension_id,
                                                     float scale) const {
  return impl_->ActionIcon(extension_id, scale);
}
}  // namespace arx

// DEV-1316. See extension_action_host.h.
extern "C" __attribute__((visibility("default")))
void ArxEngineSetExtensionPopupPresenter(ArxExtensionPopupMakeWindowFunction make_window,
                                         ArxExtensionPopupResizeWindowFunction resize_window,
                                         uint32_t closing, void* context) {
  CHECK([NSThread isMainThread]);
  auto& presenter = arx::Presenter();
  presenter.make_window = make_window;
  presenter.resize_window = make_window ? resize_window : nullptr;
  presenter.context = make_window ? context : nullptr;
  presenter.closing = closing <= ARX_EXTENSION_POPUP_STAYS_OPEN
      ? closing : ARX_EXTENSION_POPUP_CLOSES_UNLESS_MOVED;
}
