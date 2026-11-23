#include "chrome/browser/arx/gestures/fixture.h"

#import <AppKit/AppKit.h>

#include <cstdio>
#include <iterator>
#include <optional>
#include <string>

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "base/timer/timer.h"
#include "chrome/browser/arx/gestures/controller.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/arx_gesture_fixture.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "third_party/blink/public/common/input/web_gesture_event.h"
#include "ui/base/page_transition_types.h"

namespace arx::gestures {
namespace {
using Type = blink::WebInputEvent::Type;

enum class Case {
  kBack, kForward, kCancel, kPartial, kInverted, kBoundary, kContain,
  kScrollable, kScrubber, kReverse, kEscape, kChangedHistory,
  kNavigationInvalidation, kDetach, kRetreat,
  // A back swipe from scroll events alone over a window that isn't key, as
  // AppKit sends it there: no touches (DEV-1232).
  kUnfocusedScroll, kCount
};

class Fixture final : public content::WebContentsObserver,
                      public content::WebContentsUserData<Fixture> {
 public:
  ~Fixture() override { Complete(false); }
  void Start() {
    web_contents()->Focus();
    timeout_.Start(FROM_HERE, base::Seconds(60),
        base::BindOnce(&Fixture::Complete, weak_.GetWeakPtr(), false));
    Load("plain", "seed-0");
  }

 private:
  friend class content::WebContentsUserData<Fixture>;
  Fixture(content::WebContents* contents, GURL origin,
          base::OnceCallback<void(bool)> completed)
      : WebContentsObserver(contents), WebContentsUserData<Fixture>(*contents),
        origin_(std::move(origin)), completed_(std::move(completed)) {}

  Controller* owner() const {
    return web_contents() ? Controller::FromWebContents(web_contents()) : nullptr;
  }
  void Post(base::OnceClosure callback) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, std::move(callback));
  }
  void Load(std::string mode, std::string nonce) {
    waiting_url_ = origin_.Resolve("/gestures/" + mode + ".html?case=" + nonce);
    content::NavigationController::LoadURLParams params(*waiting_url_);
    params.transition_type = ui::PAGE_TRANSITION_TYPED;
    web_contents()->GetController().LoadURLWithParams(params);
  }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    if (!handle->IsInPrimaryMainFrame() || !handle->HasCommitted()) return;
    ++navigation_count_;
    if (!handle->GetURL().DeprecatedGetOriginAsURL().EqualsIgnoringRef(origin_))
      Complete(false);
  }
  void DidStopLoading() override {
    if (!completed_ || !waiting_url_ ||
        web_contents()->GetLastCommittedURL() != *waiting_url_) return;
    const auto url = *waiting_url_;
    waiting_url_.reset();
    auto* frame = web_contents()->GetPrimaryMainFrame();
    frame->InsertVisualStateCallback(base::BindOnce(
        &Fixture::VisualReady, weak_.GetWeakPtr(), frame->GetWeakDocumentPtr(), url));
  }
  void VisualReady(content::WeakDocumentPtr document, GURL url, bool success) {
    if (!completed_) return;
    if (!success || document.AsRenderFrameHostIfValid() !=
            web_contents()->GetPrimaryMainFrame() ||
        web_contents()->GetLastCommittedURL() != url) {
      Complete(false);
      return;
    }
    Post(base::BindOnce(&Fixture::Loaded, weak_.GetWeakPtr()));
  }
  void Loaded() {
    if (!completed_ || !owner()) { Complete(false); return; }
    if (seed_ < 11) {
      Load("plain", "seed-" + std::to_string(++seed_));
      return;
    }
    if (navigating_invalidation_) {
      navigating_invalidation_ = false;
      if (owner()->EndFixture(false)) { Complete(false); return; }
      Post(base::BindOnce(&Fixture::CaseComplete, weak_.GetWeakPtr()));
      return;
    }
    if (waiting_commit_) {
      waiting_commit_ = false;
      auto& history = web_contents()->GetController();
      if (!expected_target_ || !history.GetLastCommittedEntry() ||
          history.GetLastCommittedEntry()->GetUniqueID() != *expected_target_ ||
          navigation_count_ != before_navigations_ + 1 ||
          owner()->EvidenceForFixture().panel_visible) {
        Complete(false);
        return;
      }
      Post(base::BindOnce(&Fixture::CaseComplete, weak_.GetWeakPtr()));
      return;
    }
    BeginCase();
  }
  void PrepareCase() {
    if (test_ == Case::kCount) { Complete(true); return; }
    if (test_ == Case::kForward) { BeginCase(); return; }
    const std::string mode = test_ == Case::kContain ? "contained" :
        test_ == Case::kScrollable ? "scrollable" : "plain";
    Load(mode, std::to_string(static_cast<int>(test_)));
  }
  bool WaitForInputReadiness() {
    auto* frame = web_contents()->GetPrimaryMainFrame();
    auto* view = web_contents()->GetRenderWidgetHostView();
    auto* widget = view ? view->GetRenderWidgetHost() : nullptr;
    if (!frame || !frame->IsActive() || !frame->IsRenderFrameLive() || !widget) {
      Complete(false);
      return false;
    }
    if (!input_ready_deadline_) {
      input_ready_deadline_ = base::TimeTicks::Now() + base::Seconds(3);
      input_ready_document_ = frame->GetWeakDocumentPtr();
      input_was_held_ = false;
    }
    if (input_ready_document_.AsRenderFrameHostIfValid() != frame) {
      Complete(false);
      return false;
    }
    if (!content::IsInputRouterActiveForArxGestureFixture(widget)) {
      if (!input_was_held_) {
        input_was_held_ = true;
        std::fprintf(stderr, "ARX_GESTURE_FIXTURE_INPUT_HELD case=%d active=0\n",
            static_cast<int>(test_));
      }
      if (base::TimeTicks::Now() >= *input_ready_deadline_) {
        Complete(false);
        return false;
      }
      poll_.Start(FROM_HERE, base::Milliseconds(20),
          base::BindOnce(&Fixture::BeginCase, weak_.GetWeakPtr()));
      return false;
    }
    std::fprintf(stderr,
        "ARX_GESTURE_FIXTURE_INPUT_READY case=%d held=%d active=1 ignored=%d hidden=%d\n",
        static_cast<int>(test_), input_was_held_,
        web_contents()->ShouldIgnoreInputEventsForTesting(), web_contents()->GetVisibility() != content::Visibility::VISIBLE);
    input_ready_deadline_.reset();
    input_ready_document_ = {};
    return true;
  }
  void BeginCase() {
    if (!owner()) { Complete(false); return; }
    // VisualStateCallback reaches the renderer before browser compositor
    // metadata activation necessarily releases paint-holding input suppression.
    // Observe the real router state; never force activation or retry a denied
    // gesture after its first ACK has chosen content ownership.
    if (!WaitForInputReadiness()) return;
    web_contents()->Focus();
    auto& history = web_contents()->GetController();
    if (!history.GetLastCommittedEntry() || history.GetPendingEntry()) {
      Complete(false);
      return;
    }
    before_entry_ = history.GetLastCommittedEntry()->GetUniqueID();
    before_navigations_ = navigation_count_;
    const bool edge = Edge();
    const bool forward = test_ == Case::kForward || test_ == Case::kBoundary;
    horizontal_ = forward || test_ == Case::kInverted ? 0.18 : -0.18;
    if (edge) horizontal_ = -0.34;
    if (test_ == Case::kPartial) horizontal_ = -0.08;
    // A lead-in before the renderer replies; the ring and the commit count only
    // travel after history takes the gesture.
    lead_ = horizontal_ > 0 ? 0.01 : -0.01;
    if (test_ == Case::kUnfocusedScroll) {
      if (!ResignKey()) { Complete(false); return; }
      // Scroll deltas against the fingers, as without natural scrolling.
      if (owner()->ScrollFixture(ScrollPhase::kBegan, 0) ||
          owner()->ScrollFixture(ScrollPhase::kChanged,
                                 -lead_ * kScrollPointsPerUnit) ||
          owner()->EvidenceForFixture().owner != Owner::kPending) {
        Complete(false);
        return;
      }
    } else {
      if (!owner()->BeginFixture(edge, test_ == Case::kInverted)) {
        Complete(false);
        return;
      }
      owner()->AdvanceFixture(lead_, 0);
    }
    auto* target = history.GetEntryAtOffset(test_ == Case::kScrubber ? -10 : forward ? 1 : -1);
    expected_target_ = target ? std::optional<int>(target->GetUniqueID()) : std::nullopt;
    target_url_ = target ? target->GetURL() : GURL();
    Send(Type::kGestureScrollBegin);
    Send(Type::kGestureScrollUpdate);
    if (test_ == Case::kNavigationInvalidation) {
      Send(Type::kGestureScrollEnd);
      navigating_invalidation_ = true;
      Load("plain", "invalidate");
      return;
    }
    poll_deadline_ = base::TimeTicks::Now() + base::Seconds(3);
    PollReply();
  }
  bool Edge() const {
    return test_ >= Case::kScrubber && test_ != Case::kUnfocusedScroll;
  }
  // Another window of this app takes key, as another app would.
  bool ResignKey() {
    NSWindow* window = web_contents()->GetNativeView().GetNativeNSView().window;
    if (!window) return false;
    helper_ = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 80, 80)
                                          styleMask:NSWindowStyleMaskTitled
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    helper_.releasedWhenClosed = NO;
    [helper_ makeKeyAndOrderFront:nil];
    return !window.keyWindow;
  }
  void RestoreKey() {
    if (!helper_) return;
    [helper_ close];
    helper_ = nil;
    if (!web_contents()) return;
    [web_contents()->GetNativeView().GetNativeNSView().window makeKeyAndOrderFront:nil];
  }
  void Send(Type type) {
    auto* view = web_contents()->GetRenderWidgetHostView();
    if (!view) { Complete(false); return; }
    blink::WebGestureEvent event(type, blink::WebInputEvent::kNoModifiers,
        base::TimeTicks::Now(), blink::WebGestureDevice::kTouchpad);
    event.SetPositionInWidget(gfx::PointF(100, 100));
    if (type == Type::kGestureScrollBegin) {
      event.data.scroll_begin.delta_x_hint = horizontal_ > 0 ? -120 : 120;
      event.data.scroll_begin.delta_hint_units = ui::ScrollGranularity::kScrollByPrecisePixel;
    } else if (type == Type::kGestureScrollUpdate) {
      event.data.scroll_update.delta_x = horizontal_ > 0 ? -120 : 120;
      event.data.scroll_update.delta_units = ui::ScrollGranularity::kScrollByPrecisePixel;
    }
    view->GetRenderWidgetHost()->ForwardGestureEvent(event);
  }
  void PollReply() {
    if (!completed_ || !owner()) { Complete(false); return; }
    auto evidence = owner()->EvidenceForFixture();
    if (!evidence.renderer_replies) {
      if (base::TimeTicks::Now() >= poll_deadline_) { Complete(false); return; }
      poll_.Start(FROM_HERE, base::Milliseconds(20),
          base::BindOnce(&Fixture::PollReply, weak_.GetWeakPtr()));
      return;
    }
    Send(Type::kGestureScrollEnd);
    const bool denied = test_ == Case::kBoundary || test_ == Case::kContain ||
        test_ == Case::kScrollable;
    if (denied) {
      if (evidence.admitted || owner()->EndFixture(false) ||
          (test_ == Case::kScrollable && !evidence.consumed) ||
          (test_ == Case::kContain && !evidence.consumed &&
           evidence.propagates_x != false)) {
        Complete(false);
        return;
      }
      WaitStable();
      return;
    }
    if (!evidence.admitted || evidence.propagates_x != true) {
      Complete(false);
      return;
    }
    if (test_ == Case::kUnfocusedScroll) {
      // The rest of the travel, then the scroll's end releases it.
      if (!owner()->ScrollFixture(ScrollPhase::kChanged,
                                  -horizontal_ * kScrollPointsPerUnit) ||
          owner()->EvidenceForFixture().owner != Owner::kHistory) {
        Complete(false);
        return;
      }
      waiting_commit_ = true;
      waiting_url_ = target_url_;
      if (owner()->ScrollFixture(ScrollPhase::kEnded, 0) ||
          owner()->EvidenceForFixture().panel_visible ||
          web_contents()->GetNativeView().GetNativeNSView().window.keyWindow) {
        Complete(false);
      }
      return;
    }
    owner()->AdvanceFixture(horizontal_ + lead_, 0);
    evidence = owner()->EvidenceForFixture();
    if (Edge() &&
        (!evidence.panel_visible || evidence.owner != Owner::kScrubber)) {
      Complete(false);
      return;
    }
    if (test_ == Case::kScrubber) {
      // Nine rows down at 0.07 a row (DEV-1292): fingers down go back.
      owner()->AdvanceFixture(horizontal_ + lead_, -0.64);
      if (owner()->EvidenceForFixture().selected != 9) { Complete(false); return; }
    }
    if (test_ == Case::kReverse) owner()->AdvanceFixture(0.01, -0.05);
    if (test_ == Case::kRetreat) {
      owner()->AdvanceFixture(-0.36, -0.05);
      const auto adjusted = owner()->EvidenceForFixture();
      if (!adjusted.panel_visible || adjusted.owner != Owner::kScrubber ||
          adjusted.selected != 1) { Complete(false); return; }
      owner()->AdvanceFixture(-0.06, -0.05);
      const auto retreated = owner()->EvidenceForFixture();
      // Under the threshold the list folds back into the indicator. Verify it
      // now, before release can clean up the panel itself.
      if (retreated.panel_visible || retreated.owner != Owner::kHistory) {
        Complete(false);
        return;
      }
    }
    if (test_ == Case::kEscape) {
      NSWindow* window = web_contents()->GetNativeView().GetNativeNSView().window;
      NSEvent* escape = [NSEvent keyEventWithType:NSEventTypeKeyDown
          location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
          windowNumber:window.windowNumber context:nil characters:@"\x1b"
          charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53];
      if (!owner()->HandleEvent(escape)) { Complete(false); return; }
    }
    if (test_ == Case::kChangedHistory) {
      if (!web_contents()->GetController().RemoveEntryAtIndex(0)) { Complete(false); return; }
    }
    if (test_ == Case::kDetach) {
      NSView* view = web_contents()->GetNativeView().GetNativeNSView();
      NSView* parent = view.superview;
      [view removeFromSuperview];
      const bool committed = owner()->EndFixture(false);
      [parent addSubview:view];
      if (committed) { Complete(false); return; }
      WaitStable();
      return;
    }
    const bool should_commit = test_ == Case::kBack || test_ == Case::kForward ||
        test_ == Case::kInverted || test_ == Case::kScrubber;
    waiting_commit_ = should_commit;
    if (should_commit) waiting_url_ = target_url_;
    const bool committed = owner()->EndFixture(test_ == Case::kCancel);
    if (committed != should_commit) { Complete(false); return; }
    if (!should_commit) WaitStable();
  }
  void WaitStable() {
    poll_.Start(FROM_HERE, base::Milliseconds(200),
        base::BindOnce(&Fixture::Stable, weak_.GetWeakPtr()));
  }
  void Stable() {
    auto* entry = web_contents()->GetController().GetLastCommittedEntry();
    if (!entry || entry->GetUniqueID() != before_entry_ ||
        before_navigations_ != navigation_count_ ||
        owner()->EvidenceForFixture().panel_visible) { Complete(false); return; }
    CaseComplete();
  }
  void CaseComplete() {
    static constexpr const char* kNames[] = {
        "BACK_ONE", "FORWARD_ONE", "CANCEL", "PARTIAL", "INVERTED",
        "BOUNDARY", "CSS_CONTAIN", "CONTENT_SCROLL", "SCRUBBER_DIRECT",
        "REVERSE", "ESCAPE", "HISTORY_CHANGED", "NAVIGATION_INVALIDATED", "DETACH",
        "RETREAT", "UNFOCUSED_SCROLL_BACK"};
    static_assert(std::size(kNames) == static_cast<size_t>(Case::kCount));
    std::fprintf(stderr, "ARX_GESTURE_FIXTURE_%s\n", kNames[static_cast<int>(test_)]);
    RestoreKey();
    test_ = static_cast<Case>(static_cast<int>(test_) + 1);
    Post(base::BindOnce(&Fixture::PrepareCase, weak_.GetWeakPtr()));
  }
  void Complete(bool success) {
    if (!completed_) return;
    timeout_.Stop();
    poll_.Stop();
    if (!success) {
      const auto evidence = owner() ? owner()->EvidenceForFixture() : Controller::FixtureEvidence{};
      std::fprintf(stderr, "ARX_GESTURE_FIXTURE_FAILED case=%d owner=%d replies=%llu css=%d browser=%llu consumed=%d\n",
          static_cast<int>(test_), static_cast<int>(evidence.owner),
          static_cast<unsigned long long>(evidence.renderer_replies),
          evidence.propagates_x ? (*evidence.propagates_x ? 1 : 0) : -1,
          static_cast<unsigned long long>(evidence.browser_replies), evidence.consumed);
    }
    if (owner()) owner()->EndFixture(true);
    RestoreKey();
    auto callback = std::move(completed_);
    Post(base::BindOnce(std::move(callback), success));
  }
  void WebContentsDestroyed() override { Complete(false); }
  GURL origin_;
  base::OnceCallback<void(bool)> completed_;
  std::optional<GURL> waiting_url_;
  std::optional<int> expected_target_;
  GURL target_url_;
  int seed_ = 0, before_entry_ = 0;
  uint64_t navigation_count_ = 0, before_navigations_ = 0;
  Case test_ = Case::kBack;
  double horizontal_ = 0;
  double lead_ = 0;
  bool waiting_commit_ = false, navigating_invalidation_ = false;
  base::TimeTicks poll_deadline_;
  std::optional<base::TimeTicks> input_ready_deadline_;
  content::WeakDocumentPtr input_ready_document_;
  bool input_was_held_ = false;
  NSWindow* __strong helper_ = nil;
  base::OneShotTimer timeout_, poll_;
  base::WeakPtrFactory<Fixture> weak_{this};
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};
WEB_CONTENTS_USER_DATA_KEY_IMPL(Fixture);
}  // namespace

void RunFixture(content::WebContents* contents, const GURL& origin,
                base::OnceCallback<void(bool)> completed) {
  if (!contents || !origin.is_valid() || !origin.SchemeIs("http") ||
      origin.host() != "127.0.0.1" || !origin.has_port() ||
      origin.EffectiveIntPort() <= 0 || origin.has_username() || origin.has_password() ||
      origin.has_query() || origin.has_ref() || origin.path() != "/" ||
      Fixture::FromWebContents(contents)) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(std::move(completed), false));
    return;
  }
  Fixture::CreateForWebContents(contents, origin, std::move(completed));
  Fixture::FromWebContents(contents)->Start();
}
}  // namespace arx::gestures
