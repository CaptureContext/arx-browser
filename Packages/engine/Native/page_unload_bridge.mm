#include "chrome/browser/arx/page_unload_bridge.h"

#import <Foundation/Foundation.h>

#include <vector>

#include "base/auto_reset.h"
#include "base/check.h"
#include "base/feature_list.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "chrome/browser/arx/capture_bridge.h"
#include "chrome/browser/arx/devtools_bridge.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "chrome/browser/performance_manager/policies/cannot_discard_reason.h"
#include "chrome/browser/performance_manager/policies/discard_eligibility_policy.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
#include "components/performance_manager/public/decorators/page_live_state_decorator.h"
#include "components/performance_manager/public/graph/page_node.h"
#include "components/performance_manager/public/performance_manager.h"
#include "content/public/browser/arx_live_connection.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "content/public/common/content_features.h"

namespace arx {
namespace {

using performance_manager::PageLiveStateDecorator;
using performance_manager::PerformanceManager;
using performance_manager::policies::CanDiscardResult;
using performance_manager::policies::CannotDiscardReason;
using performance_manager::policies::DiscardEligibilityPolicy;

// The page UnloadPage is ending the renderer of. FastShutdownIfPossible reports
// the exit to observers synchronously, before Discard() marks the page, so
// engine_bridge asks PageIsBeingUnloaded to tell it from a crash. UI thread.
content::WebContents* g_unloading_contents = nullptr;

// Clears Performance Manager's discarded flag, as Chrome's TabLifecycleUnit
// does, once the unloaded page starts loading again (shown, restored or
// navigated). Lives as long as the contents.
class UnloadedPageObserver final
    : public content::WebContentsObserver,
      public content::WebContentsUserData<UnloadedPageObserver> {
 public:
  ~UnloadedPageObserver() override = default;

  void MarkUnloaded() {
    unloaded_ = true;
    PageLiveStateDecorator::SetIsDiscarded(web_contents(), true);
  }

  void DidStartNavigation(content::NavigationHandle* navigation) override {
    if (!unloaded_ || !navigation->IsInPrimaryMainFrame()) return;
    unloaded_ = false;
    PageLiveStateDecorator::SetIsDiscarded(web_contents(), false);
  }

 private:
  friend class content::WebContentsUserData<UnloadedPageObserver>;

  explicit UnloadedPageObserver(content::WebContents* contents)
      : content::WebContentsObserver(contents),
        content::WebContentsUserData<UnloadedPageObserver>(*contents) {}

  bool unloaded_ = false;

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(UnloadedPageObserver);

// Either closed-window reason (DEV-1104, DEV-1107).
bool ForClosedWindow(PageUnloadReason reason) {
  return reason == kPageUnloadWindowClosed || reason == kPageUnloadWindowClosedAnswered;
}

// What no longer keeps a page loaded once the window that held it closed
// (DEV-1104): what it plays, floats, records or shares, and what it would only
// notify about. Chrome's EXTERNAL discards ignore every rule; a closed window
// keeps the rest.
bool IgnoredForClosedWindow(CannotDiscardReason reason) {
  switch (reason) {
    case CannotDiscardReason::kAudible:
    case CannotDiscardReason::kRecentlyAudible:
    case CannotDiscardReason::kPictureInPicture:
    case CannotDiscardReason::kRecentlyVisible:
    case CannotDiscardReason::kNotificationsEnabled:
    case CannotDiscardReason::kBackgroundActivity:
    case CannotDiscardReason::kExtensionProtected:
    case CannotDiscardReason::kOptedOut:
    case CannotDiscardReason::kCapturingVideo:
    case CannotDiscardReason::kCapturingAudio:
    case CannotDiscardReason::kCapturingWindow:
    case CannotDiscardReason::kCapturingDisplay:
    case CannotDiscardReason::kBeingMirrored:
      return true;
    default:
      return false;
  }
}

// Chrome's eligibility, with no recent-visibility window: the app has already
// applied its own hidden time. A closed window reads Chrome's proactive
// reasons and drops the ones IgnoredForClosedWindow names.
uint32_t ChromeBlockers(content::WebContents* contents, PageUnloadReason reason) {
  if (!PerformanceManager::IsAvailable()) return kPageUnloadBlockedUnknownPage;
  base::WeakPtr<performance_manager::PageNode> node =
      PerformanceManager::GetPrimaryPageNodeForWebContents(contents);
  auto* policy = DiscardEligibilityPolicy::GetFromGraph(PerformanceManager::GetGraph());
  if (!node || !policy) return kPageUnloadBlockedUnknownPage;

  const bool window_closed = ForClosedWindow(reason);
  const bool answered = reason == kPageUnloadWindowClosedAnswered;
  const auto discard_reason = reason == kPageUnloadMemoryPressure
      ? DiscardEligibilityPolicy::DiscardReason::URGENT
      : DiscardEligibilityPolicy::DiscardReason::PROACTIVE;
  std::vector<CannotDiscardReason> reasons;
  const CanDiscardResult result = policy->CanDiscardWithCustomRecentVisibilityWindow(
      node.get(), discard_reason, base::TimeDelta(), &reasons);
  if (result == CanDiscardResult::kEligible) return 0;

  uint32_t blockers = 0;
  bool ignored = false;
  for (const CannotDiscardReason cannot : reasons) {
    const bool unsaved_input = cannot == CannotDiscardReason::kFormInteractions ||
        cannot == CannotDiscardReason::kUserEdits;
    if ((window_closed && IgnoredForClosedWindow(cannot)) || (answered && unsaved_input)) {
      ignored = true;
      continue;
    }
    switch (cannot) {
      case CannotDiscardReason::kNoMainFrame:
      case CannotDiscardReason::kAlreadyDiscarded:
        blockers |= kPageUnloadBlockedNoDocument;
        break;
      case CannotDiscardReason::kVisible:
        blockers |= kPageUnloadBlockedVisible;
        break;
      case CannotDiscardReason::kFormInteractions:
      case CannotDiscardReason::kUserEdits:
        blockers |= window_closed ? kPageUnloadBlockedUnsavedInput : kPageUnloadBlockedByChrome;
        break;
      default:
        blockers |= kPageUnloadBlockedByChrome;
        break;
    }
  }
  // Every reason a closed window ignores: nothing else keeps the page.
  if (!blockers && ignored) return 0;
  // A refusal always names a reason; keep it a refusal if one ever doesn't.
  return blockers ? blockers : kPageUnloadBlockedByChrome;
}

bool HasPictureInPicture(content::WebContents* contents) {
  return contents->HasPictureInPictureVideo() || contents->HasPictureInPictureDocument();
}

// Picture in picture closes with the window that owns its tab (DEV-1104, Max):
// the video or document window goes before the page unloads.
void EndPictureInPicture(content::WebContents* contents) {
  if (!HasPictureInPicture(contents)) return;
  auto* manager = PictureInPictureWindowManager::GetInstance();
  if (manager->GetWebContents() == contents) manager->ExitPictureInPicture();
}

}  // namespace

uint32_t PageUnloadBlockers(content::WebContents* contents, PageUnloadReason reason) {
  if (!contents || contents->IsBeingDestroyed()) return kPageUnloadBlockedUnknownPage;

  uint32_t blockers = ChromeBlockers(contents, reason);
  // Arx's own, also where Performance Manager may lag behind the contents.
  if (contents->GetVisibility() != content::Visibility::HIDDEN)
    blockers |= kPageUnloadBlockedVisible;
  if (DevToolsIsOpen(contents) || content::DevToolsAgentHost::IsDebuggerAttached(contents))
    blockers |= kPageUnloadBlockedDevTools;
  const bool window_closed = ForClosedWindow(reason);
  if (!window_closed && contents->IsCurrentlyAudible()) blockers |= kPageUnloadBlockedAudible;
  if (!window_closed && HasPictureInPicture(contents))
    blockers |= kPageUnloadBlockedPictureInPicture;
  // A closed window keeps a page only for Arx's own capture, which mustn't be cut
  // off mid-frame; another tab sharing it, as into a call, no longer does
  // (DEV-1125). Other reasons keep any capturer.
  if (window_closed ? CapturesPage(contents) : contents->IsBeingCaptured())
    blockers |= kPageUnloadBlockedCaptured;
  if (contents->IsLoading()) blockers |= kPageUnloadBlockedLoading;
  if (!window_closed && content::ArxPageHoldsLiveConnection(contents))
    blockers |= kPageUnloadBlockedLiveConnection;
  auto* frame = contents->GetPrimaryMainFrame();
  if (contents->WasDiscarded() || !frame || !frame->IsRenderFrameLive())
    blockers |= kPageUnloadBlockedNoDocument;
  return blockers;
}

PageUnloadStatus UnloadPage(content::WebContents* contents, PageUnloadReason reason,
                            uint32_t* blockers) {
  if (blockers) *blockers = 0;
  if (!contents || contents->IsBeingDestroyed() ||
      !base::FeatureList::IsEnabled(features::kWebContentsDiscard))
    return kPageUnloadUnavailable;
  if (contents->WasDiscarded()) return kPageAlreadyUnloaded;
  // Even when the page has to stay loaded, as with unsaved input or DevTools.
  if (ForClosedWindow(reason)) EndPictureInPicture(contents);

  const uint32_t found = PageUnloadBlockers(contents, reason);
  if (blockers) *blockers = found;
  if (found == kPageUnloadBlockedLoading) return kPageUnloadBusy;
  if (found) return kPageUnloadRefused;

  // As Chrome's TabLifecycleUnit does with kWebContentsDiscard on desktop: end
  // the renderer at once when it hosts nothing but this page, keeping unload
  // handlers, workers and keep-alives, then discard in place.
  {
    base::AutoReset<content::WebContents*> unloading(&g_unloading_contents, contents);
    if (content::RenderProcessHost* process = contents->GetPrimaryMainFrame()->GetProcess()) {
      process->FastShutdownIfPossible(1u, /*skip_unload_handlers=*/false,
                                      /*ignore_workers=*/false, /*ignore_keep_alive=*/false,
                                      /*ignore_pending_reuse=*/false,
                                      /*use_outermost_main_frame_check=*/true);
    }
    contents->Discard(base::NullCallback());
  }
  // FrameTree::Discard skips a frame tree with a navigation waiting to commit.
  if (!contents->WasDiscarded()) return kPageUnloadBusy;

  UnloadedPageObserver::CreateForWebContents(contents);
  UnloadedPageObserver::FromWebContents(contents)->MarkUnloaded();
  return kPageUnloaded;
}

bool EndPagePictureInPicture(content::WebContents* contents) {
  if (!contents || contents->IsBeingDestroyed() || !HasPictureInPicture(contents)) return false;
  EndPictureInPicture(contents);
  return true;
}

bool PageIsUnloaded(content::WebContents* contents) {
  return contents && !contents->IsBeingDestroyed() && contents->WasDiscarded();
}

bool PageIsBeingUnloaded(content::WebContents* contents) {
  return contents && (contents == g_unloading_contents || PageIsUnloaded(contents));
}

bool RestoreUnloadedPage(content::WebContents* contents) {
  if (!PageIsUnloaded(contents)) return false;
  // FrameTree::Discard set NeedsReload; showing the view would call this too
  // (NavigationControllerImpl::SetActive).
  auto& controller = contents->GetController();
  if (!controller.NeedsReload()) controller.SetNeedsReload();
  controller.LoadIfNecessary();
  return true;
}
}  // namespace arx

// DEV-1107. Exported outside the ABI table; see page_unload_bridge.h.
extern "C" __attribute__((visibility("default")))
uint32_t ArxEnginePageUnloadBlockers(uint64_t page, uint32_t reason) {
  CHECK([NSThread isMainThread]);
  if (reason > arx::kPageUnloadWindowClosedAnswered) return arx::kPageUnloadBlockedUnknownPage;
  content::WebContents* contents = arx::PageContents(page);
  if (!contents) return arx::kPageUnloadBlockedUnknownPage;
  return arx::PageUnloadBlockers(contents, static_cast<arx::PageUnloadReason>(reason));
}

extern "C" __attribute__((visibility("default")))
int32_t ArxEngineUnloadAnsweredPage(uint64_t page, uint32_t* blockers) {
  CHECK([NSThread isMainThread]);
  if (blockers) *blockers = 0;
  content::WebContents* contents = arx::PageContents(page);
  if (!contents) return arx::kPageUnloadUnavailable;
  return arx::UnloadPage(contents, arx::kPageUnloadWindowClosedAnswered, blockers);
}
