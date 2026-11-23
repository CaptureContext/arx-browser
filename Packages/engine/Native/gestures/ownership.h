#ifndef ARX_GESTURES_OWNERSHIP_H_
#define ARX_GESTURES_OWNERSHIP_H_

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>

namespace arx::gestures {

struct Identity {
  uint64_t page = 0;
  uint64_t epoch = 0;
  uint64_t sequence = 0;
  bool operator==(const Identity&) const = default;
};

struct Proof {
  Identity gesture;
  uint64_t update = 0;
};

enum class Owner {
  kPending, kContent, kHistory, kEdgeReserved, kScrubber, kCancelled
};
enum class Direction { kBack, kForward };

// Focus when a gesture began. AppKit sends scroll events to the window under
// the pointer whether or not it is key, so a swipe over an inactive window, or
// over a page without keyboard focus, is a gesture like any other. Only losing
// the focus it began with cancels it.
struct Focus {
  bool key = false;
  // The window's first responder is the page's view or inside it.
  bool responder = false;
  bool Keeps(Focus now) const {
    return (!key || now.key) && (!responder || now.responder);
  }
};

// A swipe can come without touches: AppKit sends NSTouch only to the key
// window, and a Magic Mouse sends none. Its precise scroll deltas then stand in
// for finger travel, in NSTouch's normalized, y-up units. Like the thresholds,
// the scale needs device tuning.
constexpr double kScrollPointsPerUnit = 800;
struct Travel {
  double x = 0, y = 0;
};
// Natural scrolling (`inverted`) moves the content with the fingers: scroll
// deltas follow the fingers horizontally and oppose them vertically, as
// Cocoa's y axis points down.
inline Travel ScrollTravel(double delta_x, double delta_y, bool inverted) {
  const double sign = inverted ? 1 : -1;
  return {sign * delta_x / kScrollPointsPerUnit,
          -sign * delta_y / kScrollPointsPerUnit};
}

enum class ScrollPhase { kNone, kBegan, kChanged, kEnded, kCancelled };
// The first non-momentum event of a precise scroll starts a touchless gesture
// when no two-finger touches are being tracked.
inline bool ScrollStartsGesture(ScrollPhase phase, bool momentum, bool precise,
                                bool touches) {
  return phase == ScrollPhase::kBegan && !momentum && precise && !touches;
}

// One instance belongs to one native Page. A proof is issued before each input
// enters Chromium's queue, copied with that input and acknowledged by its exact
// reply closure. Untagged ACK/overscroll callbacks cannot grant ownership.
class Ownership {
 public:
  explicit Ownership(uint64_t page) : page_(page) {}

  std::optional<Identity> Begin(bool edge, bool inverted,
                                bool can_back, bool can_forward) {
    active_ = false;
    if (!page_ || !epoch_ || sequence_ == std::numeric_limits<uint64_t>::max())
      return std::nullopt;
    ++sequence_;
    active_ = true;
    edge_ = edge;
    inverted_ = inverted;
    can_back_ = can_back;
    can_forward_ = can_forward;
    updates_ = 0;
    first_acknowledged_ = first_unconsumed_ = css_allowed_ = admitted_ = false;
    was_armed_ = false;
    horizontal_ = vertical_ = origin_ = 0;
    direction_.reset();
    owner_ = edge ? Owner::kEdgeReserved : Owner::kPending;
    return identity();
  }

  bool SetInverted(Identity gesture, bool inverted) {
    if (!Current(gesture) || updates_ || direction_) return false;
    inverted_ = inverted;
    return true;
  }

  void Invalidate() {
    active_ = false;
    owner_ = Owner::kCancelled;
    if (epoch_) ++epoch_;  // Zero is a permanent exhausted epoch.
  }

  std::optional<Proof> IssueUpdate(Identity gesture) {
    if (!Current(gesture)) return std::nullopt;
    if (updates_ == std::numeric_limits<uint64_t>::max()) {
      Cancel(gesture);
      return std::nullopt;
    }
    return Proof{gesture, ++updates_};
  }

  void Acknowledge(Proof proof, bool renderer_reply, bool consumed,
                   std::optional<bool> propagates_x) {
    if (!Current(proof.gesture) || !proof.update || proof.update > updates_ ||
        owner_ == Owner::kContent || owner_ == Owner::kCancelled) return;
    if (proof.update == 1 && !first_acknowledged_) {
      first_acknowledged_ = true;
      first_unconsumed_ = renderer_reply && !consumed;
      if (!first_unconsumed_) owner_ = Owner::kContent;
    }
    // An explicit containment report or a later consumer takes precedence over
    // prior admission. Absence of overscroll is unknown, never permission.
    if ((propagates_x && !*propagates_x) || consumed) owner_ = Owner::kContent;
    if (renderer_reply && !consumed && propagates_x.value_or(false))
      css_allowed_ = true;
    admitted_ = first_unconsumed_ && css_allowed_ && owner_ != Owner::kContent;
    Reconcile();
  }

  // Touch displacement uses the same normalized trackpad coordinates as pinned
  // HistorySwiper. Initial viewport-edge detection is a separate AppKit point.
  void Update(Identity gesture, double horizontal, double total_vertical) {
    if (!Current(gesture) || owner_ == Owner::kCancelled ||
        owner_ == Owner::kContent) return;
    if (!std::isfinite(horizontal) || !std::isfinite(total_vertical) ||
        total_vertical < vertical_) {
      Cancel(gesture);
      return;
    }
    horizontal_ = horizontal;
    vertical_ = total_vertical;
    const double x = std::abs(horizontal_);
    // Once the list has been open, vertical travel is selection, not a reason
    // to give the gesture back to the page.
    if (owner_ != Owner::kScrubber && !was_armed_ &&
        (vertical_ > 2 * x || (vertical_ * 1.3 > x && vertical_ > 0.01) ||
         vertical_ > 0.24)) {
      Cancel(gesture);
      return;
    }
    Reconcile();
  }

  // Arms the history list half a commit distance past the commit itself, so a
  // closed ring can still be released as a single step. The caller adds the
  // hold delay.
  bool RevealScrubber(Identity gesture) {
    if (!Current(gesture) ||
        (owner_ != Owner::kEdgeReserved && owner_ != Owner::kHistory) ||
        !reveal_reached()) return false;
    owner_ = Owner::kScrubber;
    was_armed_ = true;
    return true;
  }

  // A scrubber consumes the same one-use release as ordinary navigation.
  // Its direct-entry target is validated separately against native history.
  bool ReleaseScrubber(Identity gesture) {
    if (!Current(gesture) || owner_ != Owner::kScrubber) return false;
    const bool commit = admitted() && displacement() >= threshold();
    active_ = false;
    return commit;
  }

  void Cancel(Identity gesture) {
    if (Current(gesture)) owner_ = Owner::kCancelled;
  }

  // Consume before calling navigation: observer reentry cannot commit twice.
  // An edge-origin candidate never falls back to ordinary history navigation,
  // even when the future scrubber has not accepted or presented it.
  std::optional<Direction> Release(Identity gesture) {
    if (!Current(gesture)) return std::nullopt;
    const auto result = owner_ == Owner::kHistory && progress() >= 1
                            ? direction_
                            : std::nullopt;
    active_ = false;
    return result;
  }

  bool Current(Identity gesture) const {
    return active_ && gesture == identity();
  }
  Identity identity() const { return {page_, epoch_, sequence_}; }
  Owner owner() const { return owner_; }
  bool blocks_chrome_history() const { return active_; }
  bool consumes_wheel() const {
    return active_ && admitted() &&
           (owner_ == Owner::kHistory || owner_ == Owner::kEdgeReserved ||
            owner_ == Owner::kScrubber) &&
           std::abs(horizontal_) > 0.01;
  }
  bool admitted() const {
    return active_ && admitted_ &&
           (owner_ == Owner::kHistory || owner_ == Owner::kEdgeReserved ||
            owner_ == Owner::kScrubber);
  }
  std::optional<Direction> direction() const { return direction_; }
  bool reveal_reached() const {
    return admitted() && direction_ && displacement() >= threshold() * 1.5;
  }
  double progress() const {
    if (!direction_ || !admitted()) return 0;
    return std::clamp(displacement() / threshold(), 0.0, 1.0);
  }

 private:
  double threshold() const { return edge_ ? 0.32 : 0.16; }

  // Measured from where history took the gesture, so travel while the renderer
  // was still deciding never pre-fills the indicator or shortens the commit.
  double displacement() const {
    if (!direction_) return 0;
    double value = (horizontal_ - origin_) * (inverted_ ? -1 : 1);
    return *direction_ == Direction::kBack ? -value : value;
  }

  void Reconcile() {
    if (!active_ || !admitted_ || owner_ == Owner::kCancelled ||
        owner_ == Owner::kContent || std::abs(horizontal_) < 0.001) return;
    if (!direction_) {
      const bool forward = (horizontal_ > 0) != inverted_;
      direction_ = forward ? Direction::kForward : Direction::kBack;
      origin_ = horizontal_;
      if (!(forward ? can_forward_ : can_back_)) {
        owner_ = Owner::kContent;
        return;
      }
    }
    if (owner_ == Owner::kScrubber) {
      // Retreating well under the threshold folds the list back into the
      // indicator; sideways drift while selecting doesn't. Going past the
      // threshold again re-arms it.
      if (displacement() < threshold() / 2)
        owner_ = edge_ ? Owner::kEdgeReserved : Owner::kHistory;
    } else {
      owner_ = edge_ ? Owner::kEdgeReserved : Owner::kHistory;
    }
  }

  const uint64_t page_;
  uint64_t epoch_ = 1;
  uint64_t sequence_ = 0;
  bool active_ = false, edge_ = false, inverted_ = false;
  bool can_back_ = false, can_forward_ = false;
  uint64_t updates_ = 0;
  bool first_acknowledged_ = false, first_unconsumed_ = false;
  bool css_allowed_ = false, admitted_ = false, was_armed_ = false;
  double horizontal_ = 0, vertical_ = 0, origin_ = 0;
  Owner owner_ = Owner::kCancelled;
  std::optional<Direction> direction_;
};

}  // namespace arx::gestures
#endif  // ARX_GESTURES_OWNERSHIP_H_
