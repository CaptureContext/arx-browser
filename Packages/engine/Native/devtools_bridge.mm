#include "chrome/browser/arx/devtools_bridge.h"

#import <AppKit/AppKit.h>

#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/values.h"
#include "chrome/browser/devtools/devtools_dock_side.h"
#include "chrome/browser/devtools/devtools_settings.h"
#include "chrome/browser/devtools/devtools_ui_bindings.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents_observer.h"
#include "ui/base/page_transition_types.h"
#include "ui/gfx/geometry/rect.h"
#include "url/gurl.h"

namespace arx { class DevToolsHost; }

// Cmd-W closes only this inspector; it never reaches Arx's tab-closing menu item.
@interface ARXDevToolsWindow : NSWindow
@end

@implementation ARXDevToolsWindow
- (BOOL)performKeyEquivalent:(NSEvent*)event {
  const NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if (flags == NSEventModifierFlagCommand && [event.charactersIgnoringModifiers isEqualToString:@"w"]) {
    [self performClose:nil];
    return YES;
  }
  return [super performKeyEquivalent:event];
}
@end

@interface ARXDevToolsWindowDelegate : NSObject <NSWindowDelegate> {
  base::OnceClosure closing_;
}
- (instancetype)initWithClosing:(base::OnceClosure)closing;
- (void)invalidate;
@end

@implementation ARXDevToolsWindowDelegate
- (instancetype)initWithClosing:(base::OnceClosure)closing {
  if ((self = [super init])) closing_ = std::move(closing);
  return self;
}
- (void)windowWillClose:(NSNotification*)notification {
  if (closing_) std::move(closing_).Run();
}
- (void)invalidate { closing_.Reset(); }
@end

namespace arx {
namespace {

// can_dock lets the frontend offer its Dock side menu and report where the page goes.
constexpr char kFrontendURL[] =
    "devtools://devtools/bundled/devtools_app.html?targetType=tab&can_dock=true";
// The docked frontend view's identifier, so the app can tell keys typed in it.
NSString* const kDockedIdentifier = @"ArxDockedDeveloperTools";

struct DevToolsState {
  std::string window_title = "Developer Tools";
  std::string inspect_title = "Inspect Element";
  bool inspect_context = false;
  DevToolsLayoutObserver observer = nullptr;
  std::map<content::WebContents*, std::unique_ptr<DevToolsHost>> hosts;
};

DevToolsState& State() {
  static base::NoDestructor<DevToolsState> state;
  return *state;
}

void CheckThread() { CHECK([NSThread isMainThread]); }

void DestroyHost(content::WebContents* inspected);

void NotifyLayout(content::WebContents* inspected) {
  if (auto observer = State().observer) observer(inspected);
}

// A frontend panel name: lowercase letters, digits, dashes and underscores only.
bool ValidPanel(const std::string& panel) {
  if (panel.empty() || panel.size() > 64) return false;
  for (char c : panel)
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_')) return false;
  return true;
}

}  // namespace

// Owned by DevToolsUIBindings. It only forwards to the host through a weak pointer,
// because the bindings outlive neither the frontend WebContents nor this host.
class DevToolsDelegate final : public DevToolsUIBindings::Delegate {
 public:
  DevToolsDelegate(content::WebContents* inspected, base::WeakPtr<DevToolsHost> host)
      : inspected_(inspected), host_(std::move(host)) {}

  content::WebContents* GetInspectedWebContents() override { return host_ ? inspected_.get() : nullptr; }
  void ActivateWindow() override;
  void CloseWindow() override { ScheduleClose(); }
  void Inspect(scoped_refptr<content::DevToolsAgentHost>) override {}
  void SetInspectedPageBounds(const gfx::Rect& rect) override;
  void InspectElementCompleted() override {}
  void SetIsDocked(bool docked) override;
  // Arx never routes frontend links into a browsing space without ownership.
  void OpenInNewTab(const std::string&) override {}
  void OpenSearchResultsInNewTab(const std::string&) override {}
  void SetWhitelistedShortcuts(const std::string&) override {}
  void SetEyeDropperActive(bool) override {}
  void OpenNodeFrontend() override {}
  void InspectedContentsClosing() override { ScheduleClose(); }
  void OnLoadCompleted() override;
  // The frontend found its page target: its panels have something to show.
  void ReadyForTest() override;
  void ConnectionReady() override {}
  void SetOpenNewWindowForPopups(bool) override {}
  infobars::ContentInfoBarManager* GetInfoBarManager() override { return nullptr; }
  void RenderProcessGone(bool) override { ScheduleClose(); }
  void ShowCertificateViewer(const std::string&) override {}
  int GetDockStateForLogging() override { return 0; }
  int GetOpenedByForLogging() override { return 0; }
  int GetClosedByForLogging() override { return 0; }

 private:
  void ScheduleClose();

  raw_ptr<content::WebContents> inspected_;
  base::WeakPtr<DevToolsHost> host_;
};

class DevToolsHost final : public content::WebContentsDelegate,
                           public content::WebContentsObserver {
 public:
  explicit DevToolsHost(content::WebContents* inspected)
      : content::WebContentsObserver(inspected), inspected_(inspected) {}

  ~DevToolsHost() override {
    Observe(nullptr);
    CloseWindow();
    if (frontend_) {
      NSView* view = frontend_->GetNativeView().GetNativeNSView();
      view.identifier = nil;
      [view removeFromSuperview];
      frontend_->SetDelegate(nullptr);
    }
    // The bindings belong to the frontend contents.
    bindings_ = nullptr;
    frontend_.reset();
  }

  bool Start() {
    Profile* profile = Profile::FromBrowserContext(inspected_->GetBrowserContext());
    if (!profile) return false;
    frontend_ = content::WebContents::Create(content::WebContents::CreateParams(profile));
    frontend_->SetDelegate(this);
    frontend_->GetController().LoadURL(GURL(kFrontendURL), content::Referrer(),
        ui::PAGE_TRANSITION_AUTO_TOPLEVEL, std::string());
    bindings_ = DevToolsUIBindings::ForWebContents(frontend_.get());
    if (!bindings_) return false;
    bindings_->SetDelegate(new DevToolsDelegate(inspected_, weak_factory_.GetWeakPtr()));
    agent_ = content::DevToolsAgentHost::GetOrCreateForTab(inspected_);
    bindings_->AttachTo(agent_);
    NSView* view = frontend_->GetNativeView().GetNativeNSView();
    view.identifier = kDockedIdentifier;
    // Until the frontend says where it goes, it's docked: the app places it at once.
    NotifyLayout(inspected_);
    return true;
  }

  void Activate() {
    if (!docked_ && window_) {
      if (window_.miniaturized) [window_ deminiaturize:nil];
      [window_ makeKeyAndOrderFront:nil];
    }
    if (docked_ && !View().window) {
      focus_when_placed_ = true;
      return;
    }
    frontend_->Focus();
  }

  // The app put the docked view into a window; a pending activation focuses it now.
  void Placed() {
    if (!focus_when_placed_ || !docked_ || !View().window) return;
    focus_when_placed_ = false;
    frontend_->Focus();
  }

  void MarkLoaded() {
    loaded_ = true;
    // A frontend that never reported docking stays docked.
    if (!dock_known_) SetDocked(true);
    for (auto& [method, argument] : std::exchange(pending_, {})) Call(method, argument);
  }
  bool loaded() const { return loaded_; }
  void MarkConnected() { connected_ = true; }
  bool connected() const { return connected_; }

  void InspectElement(content::RenderFrameHost* frame, int x, int y) {
    if (agent_) agent_->InspectElement(frame, x, y);
  }

  // Runs a DevToolsAPI method now, or once the frontend has loaded.
  void Call(const std::string& method, std::string argument) {
    if (!loaded_ || !bindings_) {
      pending_.emplace_back(method, std::move(argument));
      return;
    }
    if (argument.empty())
      bindings_->CallClientMethod("DevToolsAPI", method);
    else
      bindings_->CallClientMethod("DevToolsAPI", method, base::Value(std::move(argument)));
  }

  void SetDocked(bool docked) {
    dock_known_ = true;
    if (docked == docked_ && (docked || window_)) return;
    docked_ = docked;
    if (docked) {
      CloseWindow();
      NotifyLayout(inspected_);
      Activate();
      return;
    }
    // The app removes the view from the page first; then the window takes it.
    bounds_ = gfx::Rect();
    NotifyLayout(inspected_);
    OpenWindow();
    Activate();
  }

  void SetBounds(const gfx::Rect& rect) {
    if (rect == bounds_) return;
    bounds_ = rect;
    if (docked_) NotifyLayout(inspected_);
  }

  void Layout(ArxDevToolsLayout* layout) {
    *layout = {};
    layout->dock = !dock_known_ ? ARX_DEVTOOLS_DOCK_PENDING : !docked_ ? ARX_DEVTOOLS_UNDOCKED
                                                                       : DockSide();
    if (docked_) layout->view = (__bridge void*)View();
    layout->x = bounds_.x();
    layout->y = bounds_.y();
    layout->width = bounds_.width();
    layout->height = bounds_.height();
  }

  // content::WebContentsObserver
  void TitleWasSet(content::NavigationEntry*) override { UpdateTitle(); }
  void PrimaryPageChanged(content::Page&) override { UpdateTitle(); }
  void WebContentsDestroyed() override {
    // The registry erases synchronously; nothing may touch this host afterwards.
    DestroyHost(inspected_);
  }

  // content::WebContentsDelegate for the frontend.
  void CloseContents(content::WebContents* source) override {
    if (source != frontend_.get()) return;
    content::WebContents* inspected = inspected_;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&DestroyHost, inspected));
  }

 private:
  NSView* View() const { return frontend_->GetNativeView().GetNativeNSView(); }

  ArxDevToolsDock DockSide() const {
    Profile* profile = Profile::FromBrowserContext(frontend_->GetBrowserContext());
    switch (DevToolsSettings::GetDockSide(profile)) {
      case devtools::DockSide::kLeft: return ARX_DEVTOOLS_DOCK_LEFT;
      case devtools::DockSide::kBottom: return ARX_DEVTOOLS_DOCK_BOTTOM;
      case devtools::DockSide::kRight:
      case devtools::DockSide::kNone: return ARX_DEVTOOLS_DOCK_RIGHT;
    }
    return ARX_DEVTOOLS_DOCK_RIGHT;
  }

  void OpenWindow() {
    if (window_) return;
    window_ = [[ARXDevToolsWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1040, 720)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window_.releasedWhenClosed = NO;
    window_.identifier = @"ArxDeveloperTools";
    window_.minSize = NSMakeSize(420, 300);
    content::WebContents* inspected = inspected_;
    window_delegate_ = [[ARXDevToolsWindowDelegate alloc] initWithClosing:base::BindOnce(
        [](content::WebContents* inspected) {
          // AppKit is still closing the window; destroy after its stack unwinds.
          base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
              FROM_HERE, base::BindOnce(&DestroyHost, inspected));
        }, inspected)];
    window_.delegate = window_delegate_;
    NSView* view = View();
    [view removeFromSuperview];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    window_.contentView = view;
    UpdateTitle();
    Place();
  }

  // Closes only the undocked window; the frontend lives on.
  void CloseWindow() {
    if (!window_) return;
    [window_delegate_ invalidate];
    window_.delegate = nil;
    window_.contentView = nil;
    [window_ close];
    window_ = nil;
    window_delegate_ = nil;
  }

  void UpdateTitle() {
    if (!window_) return;
    const std::string host(inspected_->GetLastCommittedURL().host());
    const std::string title = host.empty() ? State().window_title : State().window_title + " — " + host;
    window_.title = base::SysUTF8ToNSString(title);
  }

  void Place() {
    NSView* view = inspected_->GetNativeView().GetNativeNSView();
    NSWindow* source = view.window;
    if (!source) { [window_ center]; return; }
    NSRect frame = source.frame;
    NSPoint origin = NSMakePoint(NSMinX(frame) + 32, NSMaxY(frame) - 32);
    [window_ cascadeTopLeftFromPoint:origin];
  }

  raw_ptr<content::WebContents> inspected_;
  std::unique_ptr<content::WebContents> frontend_;
  raw_ptr<DevToolsUIBindings> bindings_ = nullptr;
  scoped_refptr<content::DevToolsAgentHost> agent_;
  ARXDevToolsWindow* __strong window_ = nil;
  ARXDevToolsWindowDelegate* __strong window_delegate_ = nil;
  bool loaded_ = false;
  bool connected_ = false;
  bool docked_ = true;
  bool dock_known_ = false;
  bool focus_when_placed_ = false;
  gfx::Rect bounds_;
  std::vector<std::pair<std::string, std::string>> pending_;
  base::WeakPtrFactory<DevToolsHost> weak_factory_{this};
};

void DevToolsDelegate::OnLoadCompleted() {
  if (host_) host_->MarkLoaded();
}

void DevToolsDelegate::ReadyForTest() {
  if (host_) host_->MarkConnected();
}

void DevToolsDelegate::ActivateWindow() {
  if (host_) host_->Activate();
}

void DevToolsDelegate::SetIsDocked(bool docked) {
  if (host_) host_->SetDocked(docked);
}

void DevToolsDelegate::SetInspectedPageBounds(const gfx::Rect& rect) {
  if (host_) host_->SetBounds(rect);
}

void DevToolsDelegate::ScheduleClose() {
  if (!host_) return;
  content::WebContents* inspected = inspected_;
  // Bindings call this from their own frontend/agent stacks.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
          [](base::WeakPtr<DevToolsHost> host, content::WebContents* inspected) {
            if (host) DestroyHost(inspected);
          }, host_, inspected));
}

namespace {

void DestroyHost(content::WebContents* inspected) {
  CheckThread();
  auto& hosts = State().hosts;
  auto found = hosts.find(inspected);
  if (found == hosts.end()) return;
  // Detach from the map first so reentrant observers see the closed state.
  auto owned = std::move(found->second);
  hosts.erase(found);
  owned.reset();
  NotifyLayout(inspected);
}

DevToolsHost* EnsureHost(content::WebContents* inspected) {
  auto& hosts = State().hosts;
  if (auto found = hosts.find(inspected); found != hosts.end()) return found->second.get();
  auto host = std::make_unique<DevToolsHost>(inspected);
  auto* exact = host.get();
  hosts.emplace(inspected, std::move(host));
  if (!exact->Start()) {
    DestroyHost(inspected);
    return nullptr;
  }
  return exact;
}

}  // namespace

void ConfigureDevTools(const std::string& window_title, const std::string& inspect_title,
                       bool inspect_context) {
  CheckThread();
  auto& state = State();
  if (!window_title.empty()) state.window_title = window_title;
  if (!inspect_title.empty()) state.inspect_title = inspect_title;
  state.inspect_context = inspect_context;
}

bool DevToolsInspectContextEnabled() { return State().inspect_context; }

void SetDevToolsLayoutObserver(DevToolsLayoutObserver observer) {
  CheckThread();
  State().observer = observer;
}

const std::string& DevToolsInspectTitle() { return State().inspect_title; }

ArxDevToolsStatus OpenDevTools(content::WebContents* inspected) {
  CheckThread();
  if (!inspected || inspected->IsBeingDestroyed()) return ARX_DEVTOOLS_INVALID;
  auto* host = EnsureHost(inspected);
  if (!host) return ARX_DEVTOOLS_UNAVAILABLE;
  host->Activate();
  return ARX_DEVTOOLS_OPENED;
}

ArxDevToolsStatus ShowDevToolsPanel(content::WebContents* inspected, const std::string& panel) {
  CheckThread();
  if (!inspected || inspected->IsBeingDestroyed() || !ValidPanel(panel)) return ARX_DEVTOOLS_INVALID;
  auto* host = EnsureHost(inspected);
  if (!host) return ARX_DEVTOOLS_UNAVAILABLE;
  host->Call("showPanel", panel);
  host->Activate();
  return ARX_DEVTOOLS_OPENED;
}

ArxDevToolsStatus StartDevToolsInspectMode(content::WebContents* inspected) {
  CheckThread();
  if (!inspected || inspected->IsBeingDestroyed()) return ARX_DEVTOOLS_INVALID;
  auto* host = EnsureHost(inspected);
  if (!host) return ARX_DEVTOOLS_UNAVAILABLE;
  host->Call("enterInspectElementMode", std::string());
  return ARX_DEVTOOLS_OPENED;
}

ArxDevToolsStatus InspectElement(content::WebContents* inspected,
                                 content::RenderFrameHost* frame, int x, int y) {
  CheckThread();
  if (!inspected || inspected->IsBeingDestroyed() || !frame || !frame->IsActive() ||
      !frame->IsRenderFrameLive() || content::WebContents::FromRenderFrameHost(frame) != inspected)
    return ARX_DEVTOOLS_INVALID;
  auto* host = EnsureHost(inspected);
  if (!host) return ARX_DEVTOOLS_UNAVAILABLE;
  host->InspectElement(frame, x, y);
  host->Activate();
  return ARX_DEVTOOLS_OPENED;
}

bool CloseDevTools(content::WebContents* inspected) {
  CheckThread();
  if (!State().hosts.contains(inspected)) return false;
  DestroyHost(inspected);
  return true;
}

bool DevToolsIsOpen(content::WebContents* inspected) {
  CheckThread();
  return State().hosts.contains(inspected);
}

bool DevToolsFrontendLoaded(content::WebContents* inspected) {
  CheckThread();
  auto found = State().hosts.find(inspected);
  return found != State().hosts.end() && found->second->loaded() && found->second->connected();
}

bool ReadDevToolsLayout(content::WebContents* inspected, ArxDevToolsLayout* layout) {
  CheckThread();
  auto found = State().hosts.find(inspected);
  if (!layout || found == State().hosts.end()) return false;
  found->second->Layout(layout);
  found->second->Placed();
  return true;
}

void CloseAllDevTools() {
  CheckThread();
  auto hosts = std::move(State().hosts);
  State().hosts.clear();
  hosts.clear();
}

}  // namespace arx
