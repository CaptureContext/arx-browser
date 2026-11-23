#include "chrome/browser/arx/gestures/controller.h"

#include <cmath>

#include "base/apple/owned_objc.h"
#include "base/functional/bind.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/renderer_host/chrome_render_widget_host_view_mac_history_swiping_control.h"
#include "content/public/browser/favicon_status.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"
#include "third_party/blink/public/common/input/web_gesture_event.h"
#include "ui/events/event_utils.h"
#include "ui/gfx/image/image.h"

namespace arx::gestures {
namespace {

// Normalized trackpad travel per history row while the list is open: 0.07,
// raised from 0.05 so a row takes a deliberate move (DEV-1292). Matches
// WebKitHistorySwipe.rowPitch.
constexpr double kRowPitch = 0.07;
// Down goes back through history and up goes forward (DEV-1292): the back list
// runs down from the arrow, nearest on top, and the forward list runs up from
// it, nearest at the bottom, so moving away from the arrow moves away from the
// current page in both. +1 when y falling (fingers down) selects further.
double SelectionSign(Direction direction) {
  return direction == Direction::kBack ? 1 : -1;
}
std::optional<NSPoint> TouchPoint(NSEvent* event) {
  NSPoint point = NSZeroPoint;
  int count = 0;
  for (NSTouch* touch in [event touchesMatchingPhase:NSTouchPhaseAny inView:nil]) {
    if (touch.type != NSTouchTypeIndirect) continue;
    point.x += touch.normalizedPosition.x;
    point.y += touch.normalizedPosition.y;
    ++count;
  }
  if (count != 2) return std::nullopt;  // Preserve OS three/four-finger gestures.
  return NSMakePoint(point.x / count, point.y / count);
}
int EntryID(content::NavigationEntry* entry) {
  return entry ? entry->GetUniqueID() : 0;
}
Focus FocusIn(NSWindow* window, NSView* view) {
  NSResponder* responder = window.firstResponder;
  NSView* responder_view = [responder isKindOfClass:NSView.class]
      ? static_cast<NSView*>(responder) : nil;
  return {static_cast<bool>(window.keyWindow),
          view && responder_view &&
              (responder_view == view || [responder_view isDescendantOf:view])};
}
ScrollPhase PhaseOf(NSEventPhase phase) {
  switch (phase) {
    case NSEventPhaseBegan: return ScrollPhase::kBegan;
    case NSEventPhaseChanged: return ScrollPhase::kChanged;
    case NSEventPhaseEnded: return ScrollPhase::kEnded;
    case NSEventPhaseCancelled: return ScrollPhase::kCancelled;
    default: return ScrollPhase::kNone;
  }
}
}  // namespace

WEB_CONTENTS_USER_DATA_KEY_IMPL(Controller);

Controller::Controller(content::WebContents* contents, uint64_t page,
                       double viewport_edge_points, bool owned_fixture)
    : WebContentsObserver(contents), WebContentsUserData<Controller>(*contents),
      ownership_(page), page_(page), viewport_edge_points_(viewport_edge_points),
      owned_fixture_(owned_fixture) {}

namespace {
Controller::SharedHistoryHandler g_shared_history_handler = nullptr;
void* g_shared_history_context = nullptr;
}  // namespace

void Controller::SetSharedHistory(bool back, bool forward) {
  if (shared_back_ == back && shared_forward_ == forward) return;
  shared_back_ = back;
  shared_forward_ = forward;
  // A gesture under way began with the old answer.
  Invalidate();
}

// static
void Controller::SetSharedHistoryHandler(SharedHistoryHandler handler,
                                         void* context) {
  CHECK([NSThread isMainThread]);
  g_shared_history_handler = handler;
  g_shared_history_context = context;
}

Controller::~Controller() { Invalidate(); }

bool Controller::UpstreamAllows() const {
  auto* control =
      history_swiper::HistorySwipingControl::FromWebContents(web_contents());
  return NSEvent.swipeTrackingFromScrollEventsEnabled &&
         (!control || control->ShouldAllowHistorySwiping());
}

void Controller::TouchesBegan(NSEvent* event, NSView* view) {
  Invalidate();
  auto point = TouchPoint(event);
  tracking_touches_ = point.has_value();
  if (!point || !view.window || event.window != view.window) return;
  Begin(view, *point, [view convertPoint:event.locationInWindow fromView:nil],
        false, ui::EventTimeFromNative(base::apple::OwnedNSEvent(event)));
}

void Controller::Begin(NSView* view, NSPoint touch, NSPoint pointer,
                       bool inverted, base::TimeTicks began) {
  auto* contents = web_contents();
  if (!contents || !UpstreamAllows() || !view.window ||
      !std::isfinite(viewport_edge_points_) ||
      viewport_edge_points_ <= 0 || NSWidth(view.bounds) <= 2 * viewport_edge_points_)
    return;
  auto* native_view = contents->GetRenderWidgetHostView();
  auto* frame = contents->GetPrimaryMainFrame();
  if (!native_view || !frame || native_view->GetNativeView().GetNativeNSView() != view ||
      contents->GetController().GetPendingEntry()) return;
  if (!std::isfinite(pointer.x) || !std::isfinite(pointer.y) ||
      !NSPointInRect(pointer, view.bounds)) return;
  auto& history = contents->GetController();
  current_entry_ = EntryID(history.GetLastCommittedEntry());
  back_entry_ = EntryID(history.GetEntryAtOffset(-1));
  forward_entry_ = EntryID(history.GetEntryAtOffset(1));
  // Every swipe can open the history list, so none is reserved by where it
  // starts: an ordinary swipe arms the list at its commit distance.
  gesture_ = ownership_.Begin(false, inverted, history.CanGoBack() || shared_back_,
                              history.CanGoForward() || shared_forward_);
  history_unavailable_ = false;
  scroll_driven_ = false;
  if (!gesture_) return;
  document_ = frame->GetWeakDocumentPtr();
  view_ = view;
  window_ = view.window;
  focus_ = FocusIn(view.window, view);
  bounds_ = view.bounds;
  touch_start_ = touch_current_ = touch;
  total_vertical_ = 0;
  wheel_began_ = real_scroll_begin_ = false;
  began_ = began;
  fixture_renderer_replies_ = 0;
  fixture_browser_replies_ = 0;
  fixture_consumed_ = false;
  fixture_propagates_x_.reset();
  dispatch_identity_ = base::UnguessableToken::Create();
  auto* widget = native_view->GetRenderWidgetHost();
  input_observation_.Observe(widget);
  widget_observation_.Observe(widget);
}

bool Controller::Current() {
  auto* contents = web_contents();
  auto* frame = document_.AsRenderFrameHostIfValid();
  auto* native_view = contents ? contents->GetRenderWidgetHostView() : nullptr;
  // A swipe needn't start in the key window (AppKit sends scrolls to the
  // window under the pointer); it ends only when it loses focus it had.
  const bool focused = focus_.Keeps(FocusIn(window_, view_));
  if (!gesture_ || !ownership_.Current(*gesture_) || !contents || !frame ||
      contents->GetPrimaryMainFrame() != frame || !native_view ||
      !input_observation_.IsObservingSource(native_view->GetRenderWidgetHost()) ||
      native_view->GetNativeView().GetNativeNSView() != view_ || !view_ ||
      view_.window != window_ || !window_.visible || window_.miniaturized ||
      view_.hiddenOrHasHiddenAncestor || NSIsEmptyRect(view_.visibleRect) ||
      !NSEqualRects(view_.bounds, bounds_) || !focused || !UpstreamAllows()) {
    Invalidate();
    return false;
  }
  return true;
}

void Controller::Invalidate() {
  ownership_.Invalidate();
  gesture_.reset();
  weak_factory_.InvalidateWeakPtrs();
  input_observation_.Reset();
  widget_observation_.Reset();
  selection_scroll_timer_.Stop();
  reveal_timer_.Stop();
  reveal_due_ = false;
  selection_.Reset();
  indicator_.reset();
  history_entry_ids_.clear();
  scroll_driven_ = false;
  if (scroll_end_monitor_) {
    [NSEvent removeMonitor:scroll_end_monitor_];
    scroll_end_monitor_ = nil;
  }
  view_ = nil;
  window_ = nil;
}

void Controller::InvalidateForHostNavigation() { Invalidate(); }

// Chromium's HistorySwiper takes a swipe that comes without touches for a Magic
// Mouse and shows its own arrow: in a window that isn't key, AppKit sends no
// touches, so this controller never began and the swiper took every swipe there
// (DEV-1232). It never runs on an Arx page; this controller takes those swipes
// from their scroll events instead.
bool Controller::BlocksChromeHistory() const { return true; }

std::optional<input::HistoryGestureAck> Controller::CaptureHistoryGestureAck(
    const content::RenderWidgetHost& host, const blink::WebGestureEvent& event) {
  if (!Current() || !wheel_began_ || input_observation_.GetSource() != &host ||
      event.SourceDevice() != blink::WebGestureDevice::kTouchpad ||
      event.TimeStamp() < began_) return std::nullopt;
  input::HistoryGestureAck result;
  result.identity = dispatch_identity_;
  if (event.GetType() == blink::WebInputEvent::Type::kGestureScrollBegin) {
    real_scroll_begin_ = !event.data.scroll_begin.synthetic &&
        event.data.scroll_begin.inertial_phase !=
            blink::WebGestureEvent::InertialPhaseState::kMomentum;
    if (!real_scroll_begin_) ownership_.Cancel(*gesture_);
  }
  if (real_scroll_begin_ &&
      event.GetType() == blink::WebInputEvent::Type::kGestureScrollUpdate &&
      event.data.scroll_update.inertial_phase !=
          blink::WebGestureEvent::InertialPhaseState::kMomentum) {
    if (auto proof = ownership_.IssueUpdate(*gesture_)) {
      result.callback = base::BindRepeating(&Controller::Acknowledged,
          weak_factory_.GetWeakPtr(), *proof);
    }
  }
  return result;
}

void Controller::Acknowledged(Proof proof, bool renderer_reply, bool consumed,
                              std::optional<bool> propagates_x) {
  if (!Current()) return;
  if (owned_fixture_ && !renderer_reply) ++fixture_browser_replies_;
  if (owned_fixture_ && renderer_reply) {
    ++fixture_renderer_replies_;
    fixture_consumed_ |= consumed;
    if (propagates_x) fixture_propagates_x_ = propagates_x;
  }
  ownership_.Acknowledge(proof, renderer_reply, consumed, propagates_x);
  UpdateOverlay();
}

void Controller::UpdateOverlay() {
  const Owner owner = ownership_.owner();
  if (!gesture_ || !ownership_.direction() || !ownership_.admitted() ||
      !(owner == Owner::kHistory || owner == Owner::kEdgeReserved ||
        owner == Owner::kScrubber)) {
    selection_scroll_timer_.Stop();
    reveal_timer_.Stop();
    reveal_due_ = false;
    indicator_.reset();
    return;
  }
  // The direction's history is captured once per gesture; every later step
  // rechecks it. Without it the indicator shows the arrow alone and release
  // keeps the ordinary one-entry navigation.
  if (!selection_.Current(*gesture_) && !history_unavailable_ && !CaptureHistory())
    history_unavailable_ = true;
  if (!indicator_) {
    indicator_ = std::make_unique<Panel>(view_, *ownership_.direction());
    if (selection_.Current(*gesture_))
      indicator_->SetEntries(selection_.entries(), Favicons());
  }
  if (owner == Owner::kScrubber || !ownership_.reveal_reached()) {
    reveal_timer_.Stop();
    reveal_due_ = false;
  } else if (!reveal_due_ && !reveal_timer_.IsRunning()) {
    // Fixtures reveal at once; they check the list synchronously.
    if (owned_fixture_) {
      reveal_due_ = true;
    } else {
      reveal_timer_.Start(FROM_HERE, base::Milliseconds(300),
          base::BindOnce(&Controller::RevealAfterHold, weak_factory_.GetWeakPtr()));
    }
  }
  if (owner != Owner::kScrubber && reveal_due_ && selection_.Current(*gesture_) &&
      ownership_.RevealScrubber(*gesture_)) {
    reveal_due_ = false;
    selection_anchor_y_ = touch_current_.y;
    selection_anchor_index_ = 0;
    selection_.Update(*gesture_, 0);
    selection_scroll_timer_.Start(FROM_HERE, base::Milliseconds(150),
        base::BindRepeating(&Controller::AutoScrollSelection,
                            weak_factory_.GetWeakPtr()));
  }
  if (ownership_.owner() == Owner::kScrubber) {
    if (!UpdateSelection()) return;
    indicator_->Update(1, true, selection_.selected());
    return;
  }
  selection_scroll_timer_.Stop();
  if (selection_.Current(*gesture_)) selection_.Update(*gesture_, 0);
  indicator_->Update(ownership_.progress(), false, 0);
}

void Controller::RevealAfterHold() {
  if (!Current()) return;
  reveal_due_ = true;
  UpdateOverlay();
}

bool Controller::CaptureHistory() {
  auto& history = web_contents()->GetController();
  const int count = history.GetEntryCount();
  if (count <= 1 || count > 512 || !gesture_ || !ownership_.direction()) return false;
  history_entry_ids_.clear();
  for (int index = 0; index < count; ++index) {
    const int identity = EntryID(history.GetEntryAtIndex(index));
    if (!identity) return false;
    history_entry_ids_.push_back(identity);
  }
  std::vector<HistoryEntry> entries;
  const int step = *ownership_.direction() == Direction::kBack ? -1 : 1;
  const int current = history.GetLastCommittedEntryIndex();
  for (int index = current + step; index >= 0 && index < count; index += step) {
    auto* entry = history.GetEntryAtIndex(index);
    GURL::Replacements redaction;
    redaction.ClearUsername();
    redaction.ClearPassword();
    entries.push_back({index, EntryID(entry),
        base::UTF16ToUTF8(entry->GetTitle().substr(0, 512)),
        entry->GetVirtualURL().ReplaceComponents(redaction).spec().substr(0, 2048)});
  }
  return selection_.Begin(*gesture_, std::move(entries));
}

// The list's favicons, index for index with the selection; NSNull where an
// entry has none yet (DEV-1276).
NSArray* Controller::Favicons() const {
  NSMutableArray* icons = [NSMutableArray array];
  auto& history = web_contents()->GetController();
  for (const auto& entry : selection_.entries()) {
    auto* navigation = entry.index < history.GetEntryCount()
        ? history.GetEntryAtIndex(entry.index) : nullptr;
    NSImage* icon = nil;
    if (navigation && EntryID(navigation) == entry.identity) {
      const auto& favicon = navigation->GetFavicon();
      if (favicon.valid && !favicon.image.IsEmpty()) icon = favicon.image.ToNSImage();
    }
    [icons addObject:icon ?: (id)NSNull.null];
  }
  return icons;
}

bool Controller::HistoryIsCurrent() const {
  auto& history = web_contents()->GetController();
  if (history.GetPendingEntry() || history.GetEntryCount() !=
      static_cast<int>(history_entry_ids_.size()) ||
      EntryID(history.GetLastCommittedEntry()) != current_entry_) return false;
  for (size_t index = 0; index < history_entry_ids_.size(); ++index) {
    if (EntryID(history.GetEntryAtIndex(static_cast<int>(index))) !=
        history_entry_ids_[index]) return false;
  }
  return true;
}

bool Controller::UpdateSelection() {
  if (!gesture_ || !selection_.Current(*gesture_) || !HistoryIsCurrent()) {
    Invalidate();
    return false;
  }
  if (!ownership_.direction()) {
    Invalidate();
    return false;
  }
  const double rows = static_cast<double>(selection_anchor_index_) +
      SelectionSign(*ownership_.direction()) *
          (selection_anchor_y_ - touch_current_.y) / kRowPitch;
  if (!selection_.Update(*gesture_, rows)) {
    Invalidate();
    return false;
  }
  return true;
}

void Controller::AutoScrollSelection() {
  if (!Current() || ownership_.owner() != Owner::kScrubber) return;
  if (!HistoryIsCurrent()) {
    Invalidate();
    return;
  }
  // Continue through long history while two fingers remain at the trackpad's
  // physical top/bottom. Physical coordinates affect selection only; viewport
  // edge admission was already captured separately at touchesBegan. Scroll
  // travel has no physical position.
  if (scroll_driven_ || !ownership_.direction()) return;
  // The bottom edge keeps going back, the top edge forward (DEV-1292).
  const int down = touch_current_.y < 0.06 ? 1 :
      touch_current_.y > 0.94 ? -1 : 0;
  const int delta = down * static_cast<int>(SelectionSign(*ownership_.direction()));
  if (!delta || !selection_.Step(*gesture_, delta)) return;
  selection_anchor_y_ = touch_current_.y;
  selection_anchor_index_ = selection_.selected();
  if (indicator_) indicator_->Update(1, true, selection_.selected());
}

void Controller::Update(NSEvent* event) {
  if (!Current()) return;
  const NSPoint pointer = [view_ convertPoint:event.locationInWindow fromView:nil];
  if (event.window != window_ || !NSPointInRect(pointer, view_.bounds)) {
    ownership_.Cancel(*gesture_);
    UpdateOverlay();
    return;
  }
  auto point = TouchPoint(event);
  if (!point && ownership_.owner() == Owner::kScrubber) {
    // A resting thumb or a briefly lifted finger doesn't end a selection.
    UpdateOverlay();
    return;
  }
  if (!point) {
    ownership_.Cancel(*gesture_);
  } else {
    UpdatePoint(*point);
  }
  UpdateOverlay();
}

void Controller::TouchesMoved(NSEvent* event) { Update(event); }

void Controller::TouchesEnded(NSEvent* event, bool cancelled) {
  Update(event);
  Finish(cancelled);
}

void Controller::UpdatePoint(NSPoint point) {
  total_vertical_ += std::abs(point.y - touch_current_.y);
  touch_current_ = point;
  ownership_.Update(*gesture_, point.x - touch_start_.x, total_vertical_);
}

bool Controller::Finish(bool cancelled) {
  tracking_touches_ = false;
  if (!Current()) return false;
  if (cancelled) ownership_.Cancel(*gesture_);
  if (ownership_.owner() == Owner::kScrubber) {
    const auto target = selection_.Target(*gesture_);
    const bool current = HistoryIsCurrent();
    const bool commit = ownership_.ReleaseScrubber(*gesture_);
    auto* contents = web_contents();
    Invalidate();
    if (commit && current && target)
      contents->GetController().GoToIndex(target->index);
    return commit && current && target.has_value();
  }
  const auto direction = ownership_.Release(*gesture_);
  auto* contents = web_contents();
  auto& history = contents->GetController();
  const bool history_current = EntryID(history.GetLastCommittedEntry()) == current_entry_ &&
      EntryID(history.GetEntryAtOffset(-1)) == back_entry_ &&
      EntryID(history.GetEntryAtOffset(1)) == forward_entry_ && !history.GetPendingEntry();
  Invalidate();  // Cleanup precedes a possibly reentrant native navigation.
  if (!direction || !history_current) return false;
  // DEV-1293: the other engine's page comes first that way; the app shows it.
  const bool shared = *direction == Direction::kBack ? shared_back_ : shared_forward_;
  if (shared && g_shared_history_handler) {
    g_shared_history_handler(g_shared_history_context, page_,
                             *direction == Direction::kBack ? -1 : 1);
    return true;
  }
  if (*direction == Direction::kBack && history.CanGoBack()) history.GoBack();
  else if (*direction == Direction::kForward && history.CanGoForward()) history.GoForward();
  else return false;
  return true;
}

bool Controller::BeginFixture(bool edge, bool inverted) {
  if (!owned_fixture_) return false;
  Invalidate();
  auto* native = web_contents()->GetRenderWidgetHostView();
  NSView* view = native ? native->GetNativeView().GetNativeNSView() : nil;
  if (!view.window) return false;
  tracking_touches_ = true;
  Begin(view, NSMakePoint(0.5, 0.5),
        NSMakePoint(edge ? NSMinX(view.bounds) + 1 : NSMidX(view.bounds),
                    NSMidY(view.bounds)), inverted, base::TimeTicks::Now());
  wheel_began_ = gesture_.has_value();
  return gesture_.has_value();
}

void Controller::AdvanceFixture(double horizontal, double vertical) {
  if (!owned_fixture_ || !Current()) return;
  UpdatePoint(NSMakePoint(touch_start_.x + horizontal,
                         touch_start_.y + vertical));
  UpdateOverlay();
}

bool Controller::EndFixture(bool cancelled) {
  return owned_fixture_ && Finish(cancelled);
}

Controller::FixtureEvidence Controller::EvidenceForFixture() const {
  if (!owned_fixture_) return {};
  return {ownership_.owner(), ownership_.admitted(),
          indicator_ && indicator_->armed(), selection_.selected(),
          fixture_renderer_replies_, fixture_consumed_, fixture_propagates_x_,
          fixture_browser_replies_};
}

bool Controller::ScrollFixture(ScrollPhase phase, double delta_x) {
  NSView* view = PageView();
  if (!owned_fixture_ || !view.window) return false;
  Scroll scroll;
  scroll.phase = phase;
  scroll.precise = true;
  scroll.delta_x = delta_x;
  scroll.in_window = true;
  scroll.pointer = NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds));
  scroll.time = base::TimeTicks::Now();
  return HandleScroll(scroll);
}

NSView* Controller::PageView() const {
  auto* native = web_contents() ? web_contents()->GetRenderWidgetHostView() : nullptr;
  return native ? native->GetNativeView().GetNativeNSView() : nil;
}

Controller::Scroll Controller::ScrollFrom(NSEvent* event) const {
  NSView* view = PageView();
  Scroll scroll;
  scroll.phase = PhaseOf(event.phase);
  scroll.momentum = event.momentumPhase != NSEventPhaseNone;
  scroll.precise = event.hasPreciseScrollingDeltas;
  scroll.inverted = event.directionInvertedFromDevice;
  scroll.delta_x = event.scrollingDeltaX;
  scroll.delta_y = event.scrollingDeltaY;
  scroll.in_window = view.window && event.window == view.window;
  if (scroll.in_window)
    scroll.pointer = [view convertPoint:event.locationInWindow fromView:nil];
  scroll.time = ui::EventTimeFromNative(base::apple::OwnedNSEvent(event));
  return scroll;
}

bool Controller::HandleEvent(NSEvent* event) {
  if (event.type == NSEventTypeScrollWheel) return HandleScroll(ScrollFrom(event));
  if (!Current()) return false;
  if (event.type == NSEventTypeKeyDown && event.keyCode == 53) {
    ownership_.Cancel(*gesture_);
    UpdateOverlay();
    return true;
  }
  return false;
}

bool Controller::HandleScroll(const Scroll& scroll) {
  if (ScrollStartsGesture(scroll.phase, scroll.momentum, scroll.precise,
                          tracking_touches_))
    BeginFromScroll(scroll);
  if (!Current()) return false;
  if (scroll.phase == ScrollPhase::kBegan && !scroll.momentum) {
    if (wheel_began_ || !ownership_.SetInverted(*gesture_, scroll.inverted)) {
      ownership_.Cancel(*gesture_);
    }
    wheel_began_ = true;
  }
  if (!scroll_driven_ || scroll.momentum) return ownership_.consumes_wheel();
  // Without touches the scroll is the gesture: its deltas move it, and its end
  // releases it.
  if (!scroll.in_window || !NSPointInRect(scroll.pointer, view_.bounds)) {
    ownership_.Cancel(*gesture_);
    UpdateOverlay();
  } else if (scroll.phase == ScrollPhase::kBegan ||
             scroll.phase == ScrollPhase::kChanged) {
    const Travel travel = ScrollTravel(scroll.delta_x, scroll.delta_y, scroll.inverted);
    UpdatePoint(NSMakePoint(touch_current_.x + travel.x, touch_current_.y + travel.y));
    UpdateOverlay();
  }
  if (scroll.phase == ScrollPhase::kEnded || scroll.phase == ScrollPhase::kCancelled) {
    // The page still gets the end of the scroll it saw begin.
    Finish(scroll.phase == ScrollPhase::kCancelled);
    return false;
  }
  return ownership_.consumes_wheel();
}

// Swipes that come without touches: over a window that isn't key, or from a
// Magic Mouse.
void Controller::BeginFromScroll(const Scroll& scroll) {
  Invalidate();
  NSView* view = PageView();
  if (!view.window || !scroll.in_window) return;
  Begin(view, NSMakePoint(0.5, 0.5), scroll.pointer, scroll.inverted, scroll.time);
  scroll_driven_ = gesture_.has_value();
  if (!scroll_driven_) return;
  base::WeakPtr<Controller> controller = weak_factory_.GetWeakPtr();
  scroll_end_monitor_ = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                   handler:^NSEvent*(NSEvent* event) {
                                     if (controller)
                                       controller->ScrollEndedElsewhere(event);
                                     return event;
                                   }];
}

// The scroll ended outside the page, where the pointer left it: the gesture
// ends without a jump. An end over the page reaches HandleScroll instead.
void Controller::ScrollEndedElsewhere(NSEvent* event) {
  const Scroll scroll = ScrollFrom(event);
  if (scroll.momentum || (scroll.phase != ScrollPhase::kEnded &&
                          scroll.phase != ScrollPhase::kCancelled)) return;
  if (!Current()) return;
  if (scroll.in_window && NSPointInRect(scroll.pointer, view_.bounds)) return;
  ownership_.Cancel(*gesture_);
  Finish(true);
}

void Controller::DidStartNavigation(content::NavigationHandle* navigation) {
  if (navigation->IsInPrimaryMainFrame()) Invalidate();
}
void Controller::DidFinishNavigation(content::NavigationHandle* navigation) {
  if (navigation->IsInPrimaryMainFrame() && navigation->HasCommitted()) Invalidate();
}
void Controller::PrimaryPageWillBeDeactivated(content::Page&) { Invalidate(); }
void Controller::PrimaryMainFrameRenderProcessGone(base::TerminationStatus) { Invalidate(); }
void Controller::RenderWidgetHostDestroyed(content::RenderWidgetHost*) {
  Invalidate();
  tracking_touches_ = false;  // The replacement delegate has no old swiper state.
}
void Controller::NavigationEntryCommitted(const content::LoadCommittedDetails&) { Invalidate(); }
void Controller::NavigationListPruned(const content::PrunedDetails&) { Invalidate(); }
void Controller::NavigationEntriesDeleted() { Invalidate(); }
// Title, favicon and same-entry URL updates keep the entry's identity, which
// every selection step and the release recheck; they don't end a gesture.
void Controller::NavigationEntryChanged(const content::EntryChangedDetails&) {}
void Controller::OnVisibilityWillChange(content::Visibility visibility) {
  if (visibility != content::Visibility::VISIBLE) Invalidate();
}
void Controller::WebContentsDestroyed() { Invalidate(); }

}  // namespace arx::gestures
