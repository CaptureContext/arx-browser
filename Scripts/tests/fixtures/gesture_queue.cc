#include <cassert>
#include <functional>
#include <memory>
#include <optional>
#include "gestures/ownership.h"

namespace base { using TimeTicks = int; }
namespace blink {
struct WebInputEvent { enum class Type { kUpdate }; };
namespace mojom {
enum class InputEventResultSource { kBrowser, kRenderer };
enum class InputEventResultState { kConsumed, kNotConsumed };
}
}
namespace ui {
struct LatencyInfo { void set_coalesced() {} };
}
struct Callback {
  std::function<void(bool, bool, std::optional<bool>)> function;
  explicit operator bool() const { return bool(function); }
  void Run(bool renderer, bool consumed, std::optional<bool> css) const {
    function(renderer, consumed, css);
  }
};
struct HistoryGestureAck { int identity; Callback callback; };
struct Event {
  int timestamp = 0, delta = 0;
  int GetType() const { return 1; }
  bool CanCoalesce(const Event&) const { return true; }
  void Coalesce(const Event& other) { delta += other.delta; }
  int TimeStamp() const { return timestamp; }
  void SetTimeStamp(int stamp) { timestamp = stamp; }
};
// PRODUCTION_QUEUE
using GestureEventWithLatencyInfo = EventWithLatencyInfo<Event>;
struct GestureEventWithLatencyInfoAndCallback : GestureEventWithLatencyInfo {
  explicit GestureEventWithLatencyInfoAndCallback(const GestureEventWithLatencyInfo& event)
      : GestureEventWithLatencyInfo(event), dispatch_callback(std::make_unique<int>(1)) {}
  GestureEventWithLatencyInfoAndCallback(GestureEventWithLatencyInfoAndCallback&& event);
  std::unique_ptr<int> dispatch_callback;
};
// PRODUCTION_MOVE
struct CSS {
  bool allows = true;
  bool PropagatesXScroll() const { return allows; }
};
struct Overscroll { CSS overscroll_behavior; };
struct Router {
  bool weak_this_ = true, legacy_delivered = false;
  void DidOverscroll(std::unique_ptr<Overscroll> overscroll) {
    assert(overscroll);
    legacy_delivered = true;
  }
  void Ack(const EventWithLatencyInfo<Event>& gesture_event,
           blink::mojom::InputEventResultSource source,
           blink::mojom::InputEventResultState state,
           std::unique_ptr<Overscroll> overscroll) {
    // PRODUCTION_ACK
  }
};

int main() {
  using arx::gestures::Ownership;
  using arx::gestures::Owner;
  Ownership policy(9);
  const auto gesture = *policy.Begin(false, false, true, true);
  const auto proof = *policy.IssueUpdate(gesture);
  EventWithLatencyInfo<Event> first(Event{1, 2}), next(Event{2, 3}), foreign(Event{3, 4});
  int callbacks = 0;
  first.arx_history = HistoryGestureAck{10, Callback{[&](bool renderer, bool consumed, std::optional<bool> css) {
    ++callbacks;
    policy.Acknowledge(proof, renderer, consumed, css);
  }}};
  next.arx_history = HistoryGestureAck{10, {}};
  foreign.arx_history = HistoryGestureAck{11, {}};
  assert(first.CanCoalesceWith(next));
  assert(!first.CanCoalesceWith(foreign));
  assert(!first.CanCoalesceWith(EventWithLatencyInfo<Event>{}));
  first.CoalesceWith(next);
  assert(first.event.delta == 5 && first.event.timestamp == 2);
  assert(first.arx_history->callback && !next.arx_history->callback);
  GestureEventWithLatencyInfoAndCallback deferred(first);
  GestureEventWithLatencyInfoAndCallback moved(std::move(deferred));
  assert(moved.arx_history && moved.arx_history->identity == 10);
  assert(moved.arx_history->callback && moved.dispatch_callback && !deferred.dispatch_callback);
  Router router;
  auto css = std::make_unique<Overscroll>();
  css->overscroll_behavior.allows = false;
  router.Ack(first, blink::mojom::InputEventResultSource::kRenderer,
             blink::mojom::InputEventResultState::kNotConsumed, std::move(css));
  assert(callbacks == 1 && router.legacy_delivered);
  assert(policy.owner() == Owner::kContent);
  assert(!policy.Release(gesture));
  const auto replacement = *policy.Begin(false, false, true, true);
  policy.IssueUpdate(replacement);
  // A queued old reply retains its old proof instead of consulting current state.
  router.Ack(first, blink::mojom::InputEventResultSource::kRenderer,
             blink::mojom::InputEventResultState::kNotConsumed,
             std::make_unique<Overscroll>());
  assert(callbacks == 2 && policy.owner() == Owner::kPending);
  assert(!policy.Release(replacement));
  // A current positive reply must admit before the legacy path moves its CSS.
  const auto current = *policy.Begin(false, false, true, true);
  const auto current_proof = *policy.IssueUpdate(current);
  first.arx_history = HistoryGestureAck{12, Callback{[&](bool renderer, bool consumed, std::optional<bool> css) {
    policy.Acknowledge(current_proof, renderer, consumed, css);
  }}};
  policy.Update(current, 0.01, 0);
  router.Ack(first, blink::mojom::InputEventResultSource::kRenderer,
             blink::mojom::InputEventResultState::kNotConsumed,
             std::make_unique<Overscroll>());
  assert(policy.owner() == Owner::kHistory);
  policy.Update(current, 0.19, 0);
  assert(policy.Release(current) == arx::gestures::Direction::kForward);
}
