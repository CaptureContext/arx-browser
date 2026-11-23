#ifndef ARX_GESTURES_CONTROLLER_H_
#define ARX_GESTURES_CONTROLLER_H_

#import <AppKit/AppKit.h>

#include <optional>

#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/unguessable_token.h"
#include "chrome/browser/arx/gestures/ownership.h"
#include "chrome/browser/arx/gestures/panel.h"
#include "components/input/arx_history_gesture.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_observer.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"

namespace arx::gestures {

// Explicit owner installed by each Arx Page.
// Existing ChromeRenderWidgetHostViewMacDelegate remains installed and forwards
// only its gesture hooks here; all other responder behavior stays upstream.
class Controller final : public content::WebContentsObserver,
                         public content::WebContentsUserData<Controller>,
                         public content::RenderWidgetHost::InputEventObserver,
                         public content::RenderWidgetHostObserver {
 public:
  ~Controller() override;
  void TouchesBegan(NSEvent* event, NSView* view);
  void TouchesMoved(NSEvent* event);
  void TouchesEnded(NSEvent* event, bool cancelled);
  bool HandleEvent(NSEvent* event);
  // Always true: this controller is the only history swipe on an Arx page.
  // Chromium's HistorySwiper never shows its arrow here, Magic Mouse and
  // inactive windows included.
  bool BlocksChromeHistory() const;
  // Page calls this synchronously before issuing host navigation/reload/history
  // commands; observer invalidation also covers renderer-initiated changes.
  void InvalidateForHostNavigation();

  // DEV-1293: the tab's other engine has a page right behind or ahead of this
  // one's current entry, which the app keeps. A swipe that way is offered and,
  // released, goes to the app's handler instead of this page's own history,
  // which has no entry for it. The history list keeps this page's entries.
  void SetSharedHistory(bool back, bool forward);
  using SharedHistoryHandler = void (*)(void* context, uint64_t page,
                                        int32_t direction);
  // Main thread; direction is -1 for back, 1 for forward.
  static void SetSharedHistoryHandler(SharedHistoryHandler handler,
                                      void* context);

  struct FixtureEvidence {
    Owner owner = Owner::kCancelled;
    bool admitted = false;
    bool panel_visible = false;
    size_t selected = 0;
    uint64_t renderer_replies = 0;
    bool consumed = false;
    std::optional<bool> propagates_x;
    uint64_t browser_replies = 0;
  };
  // Explicit owned-fixture only; browser points are synthetic, while ACK/CSS
  // evidence must still come from the actual renderer through the input queue.
  bool BeginFixture(bool edge, bool inverted = false);
  void AdvanceFixture(double horizontal, double vertical);
  bool EndFixture(bool cancelled);
  // A precise, non-momentum scroll at the middle of the page view, as a swipe
  // without touches sends. Returns whether the scroll was consumed.
  bool ScrollFixture(ScrollPhase phase, double delta_x);
  FixtureEvidence EvidenceForFixture() const;

  std::optional<input::HistoryGestureAck> CaptureHistoryGestureAck(
      const content::RenderWidgetHost& host,
      const blink::WebGestureEvent& event) override;

 private:
  // The parts of a scroll event a gesture reads.
  struct Scroll {
    ScrollPhase phase = ScrollPhase::kNone;
    bool momentum = false, precise = false, inverted = false;
    double delta_x = 0, delta_y = 0;
    // Sent to the page view's window, at `pointer` in the view.
    bool in_window = false;
    NSPoint pointer = NSZeroPoint;
    base::TimeTicks time;
  };

  friend class content::WebContentsUserData<Controller>;
  Controller(content::WebContents* contents, uint64_t page,
             double viewport_edge_points, bool owned_fixture = false);
  NSView* PageView() const;
  Scroll ScrollFrom(NSEvent* event) const;
  bool HandleScroll(const Scroll& scroll);
  void BeginFromScroll(const Scroll& scroll);
  void ScrollEndedElsewhere(NSEvent* event);
  void Begin(NSView* view, NSPoint touch, NSPoint pointer,
             bool inverted, base::TimeTicks began);
  void UpdatePoint(NSPoint point);
  bool Finish(bool cancelled);
  bool Current();
  bool UpstreamAllows() const;
  void Invalidate();
  void Update(NSEvent* event);
  void UpdateOverlay();
  void RevealAfterHold();
  bool CaptureHistory();
  bool HistoryIsCurrent() const;
  // The selection's favicons for the list, NSNull where there is none.
  NSArray* Favicons() const;
  bool UpdateSelection();
  void AutoScrollSelection();
  void Acknowledged(Proof proof, bool renderer_reply, bool consumed,
                    std::optional<bool> propagates_x);
  void DidStartNavigation(content::NavigationHandle* navigation) override;
  void DidFinishNavigation(content::NavigationHandle* navigation) override;
  void PrimaryPageWillBeDeactivated(content::Page&) override;
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override;
  void RenderWidgetHostDestroyed(content::RenderWidgetHost*) override;
  void NavigationEntryCommitted(const content::LoadCommittedDetails&) override;
  void NavigationListPruned(const content::PrunedDetails&) override;
  void NavigationEntriesDeleted() override;
  void NavigationEntryChanged(const content::EntryChangedDetails&) override;
  void OnVisibilityWillChange(content::Visibility visibility) override;
  void WebContentsDestroyed() override;

  Ownership ownership_;
  const uint64_t page_;
  bool shared_back_ = false, shared_forward_ = false;
  const double viewport_edge_points_;
  const bool owned_fixture_;
  uint64_t fixture_renderer_replies_ = 0;
  uint64_t fixture_browser_replies_ = 0;
  bool fixture_consumed_ = false;
  std::optional<bool> fixture_propagates_x_;
  std::optional<Identity> gesture_;
  base::UnguessableToken dispatch_identity_;
  content::WeakDocumentPtr document_;
  NSView* __weak view_ = nil;
  NSWindow* __weak window_ = nil;
  NSRect bounds_ = NSZeroRect;
  NSPoint touch_start_ = NSZeroPoint, touch_current_ = NSZeroPoint;
  // Where the pointer was when the gesture began, in the view.
  double total_vertical_ = 0;
  bool tracking_touches_ = false, wheel_began_ = false;
  bool real_scroll_begin_ = false;
  // Driven by scroll deltas, not touches: `touch_*` then hold the travel the
  // deltas stand for, and have no physical trackpad position.
  bool scroll_driven_ = false;
  // A scroll-driven gesture's end can reach another view, when the pointer has
  // left the page; this local monitor sees it there.
  id __strong scroll_end_monitor_ = nil;
  Focus focus_;
  base::TimeTicks began_;
  int current_entry_ = 0, back_entry_ = 0, forward_entry_ = 0;
  std::vector<int> history_entry_ids_;
  Selection selection_;
  double selection_anchor_y_ = 0;
  size_t selection_anchor_index_ = 0;
  // The swipe indicator; armed, it is the history list.
  std::unique_ptr<Panel> indicator_;
  bool history_unavailable_ = false;
  base::RepeatingTimer selection_scroll_timer_;
  // Past the reveal distance the list waits a moment, so a closed ring can be
  // released as a single step without the list flashing open.
  base::OneShotTimer reveal_timer_;
  bool reveal_due_ = false;
  base::ScopedObservation<content::RenderWidgetHost,
                          content::RenderWidgetHost::InputEventObserver>
      input_observation_{this};
  base::ScopedObservation<content::RenderWidgetHost,
                          content::RenderWidgetHostObserver>
      widget_observation_{this};
  base::WeakPtrFactory<Controller> weak_factory_{this};
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

}  // namespace arx::gestures
#endif  // ARX_GESTURES_CONTROLLER_H_
