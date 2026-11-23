#include <cassert>
#include <cmath>
#include <limits>
#include <string>
#include "gestures/ownership.h"
#include "gestures/selection.h"

using arx::gestures::Direction;
using arx::gestures::Identity;
using arx::gestures::Owner;
using arx::gestures::Proof;
using arx::gestures::Ownership;
using arx::gestures::Focus;
using arx::gestures::ScrollPhase;
using arx::gestures::ScrollStartsGesture;
using arx::gestures::ScrollTravel;

int main(int argc, char** argv) {
  assert(argc == 2);
  const std::string scenario = argv[1];
  Ownership policy(7);
  auto gesture = *policy.Begin(false, false, true, true);
  policy.Update(gesture, 0.01, 0);
  assert(policy.owner() == Owner::kPending);
  assert(policy.progress() == 0);
  if (scenario == "unissued") {
    policy.Acknowledge(Proof{gesture, 1}, true, false, true);
    assert(policy.owner() == Owner::kPending);
    assert(!policy.Release(gesture));
    return 0;
  }
  auto proof = *policy.IssueUpdate(gesture);
  if (scenario == "complete-once") {
    policy.Acknowledge(proof, true, false, true);
    assert(policy.owner() == Owner::kHistory && policy.progress() == 0);
    policy.Update(gesture, 0.19, 0);
    assert(policy.progress() == 1);
    assert(policy.Release(gesture) == Direction::kForward);
    assert(!policy.Release(gesture));
    assert(!policy.blocks_chrome_history());
  } else if (scenario == "consumed") {
    policy.Acknowledge(proof, true, true, true);
    policy.Acknowledge(proof, true, false, true);
    assert(policy.owner() == Owner::kContent);
    assert(!policy.Release(gesture));
  } else if (scenario == "css") {
    policy.Acknowledge(proof, true, false, false);
    assert(!policy.Release(gesture));
    gesture = *policy.Begin(false, false, true, true);
    proof = *policy.IssueUpdate(gesture);
    policy.Update(gesture, 0.4, 0);
    policy.Acknowledge(proof, true, false, std::nullopt);
    assert(!policy.Release(gesture));
  } else if (scenario == "browser-filter") {
    policy.Acknowledge(proof, false, false, true);
    assert(!policy.Release(gesture));
  } else if (scenario == "old-gesture") {
    const auto old = gesture;
    gesture = *policy.Begin(false, false, true, true);
    policy.IssueUpdate(gesture);
    policy.Update(gesture, 0.4, 0);
    policy.Acknowledge(proof, true, false, true);
    assert(!policy.Current(old));
    assert(!policy.Release(old));
    assert(policy.Current(gesture));
    assert(!policy.Release(gesture));
  } else if (scenario == "epoch") {
    policy.Invalidate();
    gesture = *policy.Begin(false, false, true, true);
    assert(gesture.epoch != proof.gesture.epoch);
    policy.IssueUpdate(gesture);
    policy.Acknowledge(proof, true, false, true);
    assert(policy.owner() == Owner::kPending);
    assert(!policy.Release(gesture));
  } else if (scenario == "late-css") {
    policy.Acknowledge(proof, true, false, std::nullopt);
    assert(policy.owner() == Owner::kPending && !policy.admitted());
    const auto later = *policy.IssueUpdate(gesture);
    policy.Acknowledge(later, true, false, true);
    policy.Update(gesture, 0.19, 0);
    assert(policy.Release(gesture) == Direction::kForward);
  } else if (scenario == "out-of-order-css") {
    const auto later = *policy.IssueUpdate(gesture);
    policy.Acknowledge(later, true, false, true);
    assert(policy.owner() == Owner::kPending);
    policy.Acknowledge(proof, true, false, std::nullopt);
    policy.Update(gesture, 0.19, 0);
    assert(policy.Release(gesture) == Direction::kForward);
  } else if (scenario == "later-consumer") {
    policy.Acknowledge(proof, true, false, true);
    const auto later = *policy.IssueUpdate(gesture);
    policy.Acknowledge(later, true, true, std::nullopt);
    assert(policy.owner() == Owner::kContent);
    assert(!policy.Release(gesture));
  } else if (scenario == "foreign-page") {
    Ownership foreign(8);
    auto other = *foreign.Begin(false, false, true, true);
    foreign.IssueUpdate(other);
    foreign.Acknowledge(proof, true, false, true);
    assert(foreign.owner() == Owner::kPending);
    assert(!foreign.Release(other));
  } else if (scenario == "reversal") {
    policy.Acknowledge(proof, true, false, true);
    policy.Update(gesture, 0.19, 0);
    assert(policy.progress() == 1);
    policy.Update(gesture, 0.09, 0);
    assert(std::abs(policy.progress() - 0.5) < 1e-9);
    policy.Update(gesture, -0.18, 0);
    assert(policy.progress() == 0 && policy.direction() == Direction::kForward);
    assert(!policy.Release(gesture));
  } else if (scenario == "inversion") {
    gesture = *policy.Begin(false, false, true, true);
    assert(policy.SetInverted(gesture, true));
    proof = *policy.IssueUpdate(gesture);
    assert(!policy.SetInverted(gesture, false));
    policy.Update(gesture, 0.01, 0);
    policy.Acknowledge(proof, true, false, true);
    policy.Update(gesture, 0.19, 0);
    assert(policy.Release(gesture) == Direction::kBack);
  } else if (scenario == "vertical") {
    policy.Update(gesture, 0.18, 0.2);
    policy.Acknowledge(proof, true, false, true);
    assert(policy.owner() == Owner::kCancelled);
    assert(policy.blocks_chrome_history() && !policy.consumes_wheel());
    assert(!policy.Release(gesture));
  } else if (scenario == "edge-reservation") {
    gesture = *policy.Begin(true, false, true, true);
    assert(policy.owner() == Owner::kEdgeReserved && policy.blocks_chrome_history());
    policy.Update(gesture, 0.4, 0);
    assert(!policy.consumes_wheel());
    proof = *policy.IssueUpdate(gesture);
    policy.Acknowledge(proof, true, false, true);
    assert(policy.admitted() && policy.owner() == Owner::kEdgeReserved);
    assert(!policy.Release(gesture));
  } else if (scenario == "edge-scrubber") {
    gesture = *policy.Begin(true, false, true, true);
    proof = *policy.IssueUpdate(gesture);
    policy.Update(gesture, -0.34, 0);
    assert(!policy.RevealScrubber(gesture));
    policy.Acknowledge(proof, true, false, true);
    assert(!policy.RevealScrubber(gesture));  // Pre-admission travel doesn't count.
    policy.Update(gesture, -0.67, 0);
    assert(!policy.RevealScrubber(gesture));  // Closed ring: a single step.
    policy.Update(gesture, -0.83, 0);
    assert(policy.RevealScrubber(gesture));
    assert(policy.owner() == Owner::kScrubber && policy.consumes_wheel());
    policy.Update(gesture, -0.83, 0.5);
    assert(policy.owner() == Owner::kScrubber);
    assert(policy.ReleaseScrubber(gesture));
    assert(!policy.ReleaseScrubber(gesture) && !policy.Release(gesture));
  } else if (scenario == "edge-retreat") {
    gesture = *policy.Begin(true, false, true, true);
    proof = *policy.IssueUpdate(gesture);
    policy.Update(gesture, -0.01, 0);
    policy.Acknowledge(proof, true, false, true);
    policy.Update(gesture, -0.5, 0);
    assert(policy.RevealScrubber(gesture));
    policy.Update(gesture, -0.34, 0.1);
    assert(policy.owner() == Owner::kScrubber && policy.admitted());
    policy.Update(gesture, -0.18, 0.12);
    assert(policy.owner() == Owner::kScrubber);
    policy.Update(gesture, -0.14, 0.12);
    assert(policy.owner() == Owner::kEdgeReserved && policy.admitted());
    policy.Update(gesture, -0.5, 0.12);
    assert(policy.RevealScrubber(gesture));
    policy.Update(gesture, -0.14, 0.12);
    assert(!policy.ReleaseScrubber(gesture) && !policy.Release(gesture));
  } else if (scenario == "edge-reversal") {
    gesture = *policy.Begin(true, false, true, true);
    proof = *policy.IssueUpdate(gesture);
    policy.Update(gesture, 0.01, 0);
    policy.Acknowledge(proof, true, false, true);
    policy.Update(gesture, 0.5, 0);
    assert(policy.RevealScrubber(gesture));
    policy.Update(gesture, -0.02, 0.1);
    assert(policy.owner() == Owner::kEdgeReserved && policy.progress() == 0);
    assert(!policy.ReleaseScrubber(gesture) && !policy.Release(gesture));
  } else if (scenario == "edge-containment-after-reveal") {
    gesture = *policy.Begin(true, false, true, true);
    proof = *policy.IssueUpdate(gesture);
    policy.Update(gesture, 0.01, 0);
    policy.Acknowledge(proof, true, false, true);
    policy.Update(gesture, 0.5, 0);
    assert(policy.RevealScrubber(gesture));
    policy.Acknowledge(*policy.IssueUpdate(gesture), true, false, false);
    assert(policy.owner() == Owner::kContent && !policy.ReleaseScrubber(gesture));
  } else if (scenario == "history-list") {
    policy.Acknowledge(proof, true, false, true);
    policy.Update(gesture, 0.19, 0);
    assert(policy.owner() == Owner::kHistory && policy.progress() == 1);
    assert(!policy.RevealScrubber(gesture));  // Closed ring: a single step.
    policy.Update(gesture, 0.26, 0);
    assert(policy.RevealScrubber(gesture) && policy.owner() == Owner::kScrubber);
    policy.Update(gesture, 0.18, 0.4);
    assert(policy.owner() == Owner::kScrubber);
    policy.Update(gesture, 0.1, 0.4);  // Sideways drift while selecting.
    assert(policy.owner() == Owner::kScrubber);
    policy.Update(gesture, 0.06, 0.4);
    assert(policy.owner() == Owner::kHistory && !policy.RevealScrubber(gesture));
    assert(policy.progress() < 1);
    policy.Update(gesture, 0.26, 0.6);  // Vertical travel no longer cancels.
    assert(policy.owner() == Owner::kHistory);
    assert(policy.RevealScrubber(gesture) && policy.ReleaseScrubber(gesture));
    gesture = *policy.Begin(false, false, true, true);
    proof = *policy.IssueUpdate(gesture);
    policy.Update(gesture, 0.01, 0);
    policy.Acknowledge(proof, true, false, true);
    policy.Update(gesture, 0.1, 0);
    assert(!policy.RevealScrubber(gesture));
    policy.Update(gesture, 0.19, 0);
    assert(!policy.RevealScrubber(gesture));
    policy.Update(gesture, 0.26, 0);
    assert(policy.RevealScrubber(gesture) && policy.ReleaseScrubber(gesture));
  } else if (scenario == "selection") {
    arx::gestures::Selection selection;
    std::vector<arx::gestures::HistoryEntry> entries;
    for (int index = 0; index < 200; ++index)
      entries.push_back({200 - index, index + 1, "Title", "https://example.test/"});
    assert(selection.Begin(gesture, entries));
    assert(selection.Update(gesture, 20.7) && selection.selected() == 21);
    assert(selection.Target(gesture)->index == 179);
    assert(selection.Step(gesture, 1) && selection.selected() == 22);
    assert(selection.Update(gesture, 10000) && selection.selected() == 199);
    assert(selection.Update(gesture, -10000) && selection.selected() == 0);
    assert(!selection.Update(Identity{8, 1, 1}, 5));
    assert(!selection.Update(gesture, std::numeric_limits<double>::infinity()));
    selection.Reset();
    assert(!selection.Target(gesture));
    entries[1].identity = entries[0].identity;
    assert(!selection.Begin(gesture, entries));
    assert(!selection.Target(gesture));
    assert(!selection.Begin(gesture, {}));
  } else if (scenario == "boundary") {
    gesture = *policy.Begin(false, false, true, false);
    proof = *policy.IssueUpdate(gesture);
    policy.Acknowledge(proof, true, false, true);
    policy.Update(gesture, 0.4, 0);
    assert(policy.owner() == Owner::kContent && !policy.consumes_wheel());
    assert(!policy.Release(gesture));
  } else if (scenario == "cancel") {
    policy.Acknowledge(proof, true, false, true);
    policy.Cancel(gesture);
    assert(policy.owner() == Owner::kCancelled);
    assert(!policy.Release(gesture));
  } else if (scenario == "invalid-motion") {
    policy.Acknowledge(proof, true, false, true);
    policy.Update(gesture, std::numeric_limits<double>::quiet_NaN(), 0);
    assert(!policy.Release(gesture));
    gesture = *policy.Begin(false, false, true, true);
    policy.Update(gesture, 0.2, 0.01);
    policy.Update(gesture, 0.2, 0);
    assert(policy.owner() == Owner::kCancelled);
  } else if (scenario == "partial") {
    policy.Acknowledge(proof, true, false, true);
    policy.Update(gesture, 0.158, 0);
    assert(!policy.Release(gesture));
  } else if (scenario == "unfocused-start") {
    // DEV-1232: a swipe over a window that isn't key, or a page without
    // keyboard focus, is a gesture; only losing the focus it began with ends it.
    const Focus inactive{false, true};
    assert(inactive.Keeps({false, true}));
    assert(inactive.Keeps({true, true}));
    assert(!inactive.Keeps({false, false}));
    const Focus elsewhere{true, false};
    assert(elsewhere.Keeps({true, false}));
    assert(!elsewhere.Keeps({false, false}));
    const Focus focused{true, true};
    assert(focused.Keeps({true, true}));
    assert(!focused.Keeps({false, true}));
    assert(!focused.Keeps({true, false}));
  } else if (scenario == "scroll-start") {
    // Without touches the scroll starts the gesture; with them, touches do.
    assert(ScrollStartsGesture(ScrollPhase::kBegan, false, true, false));
    assert(!ScrollStartsGesture(ScrollPhase::kBegan, false, true, true));
    assert(!ScrollStartsGesture(ScrollPhase::kBegan, true, true, false));
    assert(!ScrollStartsGesture(ScrollPhase::kBegan, false, false, false));
    assert(!ScrollStartsGesture(ScrollPhase::kChanged, false, true, false));
    assert(!ScrollStartsGesture(ScrollPhase::kNone, false, true, false));
  } else if (scenario == "scroll-travel") {
    // Fingers moving right and up: content follows them with natural scrolling.
    const auto natural = ScrollTravel(80, -40, true);
    assert(natural.x == 0.1 && natural.y == 0.05);
    const auto classic = ScrollTravel(-80, 40, false);
    assert(classic.x == 0.1 && classic.y == 0.05);
    // Back swipes either way, and scroll travel commits like touch travel.
    for (const bool inverted : {true, false}) {
      gesture = *policy.Begin(false, inverted, true, true);
      proof = *policy.IssueUpdate(gesture);
      // Back is fingers right with natural scrolling, left without it: a
      // positive horizontal scroll delta either way, as a Magic Mouse's is.
      double x = ScrollTravel(8, 0, inverted).x;
      policy.Update(gesture, x, 0);
      policy.Acknowledge(proof, true, false, true);
      assert(policy.owner() == Owner::kHistory);
      assert(policy.direction() == Direction::kBack);
      x += ScrollTravel(0.17 * arx::gestures::kScrollPointsPerUnit, 0, inverted).x;
      policy.Update(gesture, x, 0);
      assert(policy.consumes_wheel() && policy.progress() == 1);
      assert(policy.Release(gesture) == Direction::kBack);
    }
  } else {
    assert(false);
  }
}
