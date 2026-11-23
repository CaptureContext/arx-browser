// Arx (DEV-825, DEV-852): the Picture in Picture window's motion math.
// Copied to chrome/browser/ui/views/overlay by Scripts/engine/pip_overlay.py.
//
// Pure C++ with no Chromium or AppKit dependency, so Scripts/tests compiles and
// tests it on its own. Units are points and seconds. The functions don't care
// which way y points, as long as every argument uses the same coordinates.

#ifndef CHROME_BROWSER_UI_VIEWS_OVERLAY_ARX_PIP_MOTION_H_
#define CHROME_BROWSER_UI_VIEWS_OVERLAY_ARX_PIP_MOTION_H_

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <span>

namespace arx_pip {

struct Point {
  double x = 0;
  double y = 0;
};

struct Size {
  double width = 0;
  double height = 0;
};

struct Rect {
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;

  double MaxX() const { return x + width; }
  double MaxY() const { return y + height; }
  Point Center() const { return {x + width / 2, y + height / 2}; }
  bool Contains(Point point) const {
    return point.x >= x && point.x < MaxX() && point.y >= y &&
           point.y < MaxY();
  }
};

// The window's continuous corner radius.
inline constexpr double kCornerRadius = 16;

// How far the resting positions sit from the screen's visible frame edges
// (16 points since DEV-848; DEV-825 had 24).
inline constexpr double kEdgeInset = 16;

// UIScrollView.DecelerationRate.normal: the share of velocity left after each
// millisecond of coasting.
inline constexpr double kDecelerationRate = 0.998;

// How far back release velocity looks, in seconds.
inline constexpr double kVelocityWindow = 0.1;

// The distance a value moving at `velocity` points per second coasts while it
// keeps `rate` of its velocity every millisecond, as UIKit's projection does.
inline double ProjectedDistance(double velocity,
                                double rate = kDecelerationRate) {
  if (rate <= 0 || rate >= 1) {
    return 0;
  }
  return velocity / 1000 * rate / (1 - rate);
}

// Where `position` comes to rest after coasting from `velocity`.
inline Point Project(Point position,
                     Point velocity,
                     double rate = kDecelerationRate) {
  return {
      position.x + ProjectedDistance(velocity.x, rate),
      position.y + ProjectedDistance(velocity.y, rate),
  };
}

// A position at a time, both from the input events.
struct Sample {
  double time = 0;
  Point position;
};

// The velocity at release, `now`, in points per second, from the samples of
// the last `window` seconds. When those hold only the newest sample, the one
// before it is used too, so sparse events still give a velocity. A pointer
// that rested longer than `window` before release has no velocity.
inline Point Velocity(std::span<const Sample> samples,
                      double now,
                      double window = kVelocityWindow) {
  if (samples.empty()) {
    return {};
  }
  const Sample& last = samples.back();
  if (now - last.time > window) {
    return {};
  }
  size_t first = samples.size() - 1;
  while (first > 0 && last.time - samples[first - 1].time <= window) {
    first -= 1;
  }
  if (first == samples.size() - 1 && first > 0) {
    first -= 1;
  }
  const double elapsed = last.time - samples[first].time;
  if (elapsed <= 0) {
    return {};
  }
  return {
      (last.position.x - samples[first].position.x) / elapsed,
      (last.position.y - samples[first].position.y) / elapsed,
  };
}

// The four resting origins for a window of `size` in `area`, each `inset` from
// the two nearest edges: low x and low y first, then high x and low y, low x
// and high y, high x and high y. On an axis where the window doesn't fit
// between the insets it's centred.
inline std::array<Point, 4> SnapOrigins(Rect area,
                                        Size size,
                                        double inset = kEdgeInset) {
  auto bounds = [inset](double start, double length, double extent) {
    const double low = start + inset;
    const double high = start + length - inset - extent;
    if (high < low) {
      const double centre = start + (length - extent) / 2;
      return std::array<double, 2>{centre, centre};
    }
    return std::array<double, 2>{low, high};
  };
  const auto xs = bounds(area.x, area.width, size.width);
  const auto ys = bounds(area.y, area.height, size.height);
  return {
      Point{xs[0], ys[0]},
      Point{xs[1], ys[0]},
      Point{xs[0], ys[1]},
      Point{xs[1], ys[1]},
  };
}

inline double DistanceSquared(Point a, Point b) {
  return (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y);
}

// The squared distance from `point` to the nearest point of `rect`; zero
// inside it.
inline double DistanceSquared(Rect rect, Point point) {
  const double dx = std::max({rect.x - point.x, 0.0, point.x - rect.MaxX()});
  const double dy = std::max({rect.y - point.y, 0.0, point.y - rect.MaxY()});
  return dx * dx + dy * dy;
}

// The index of the area holding `point`, else of the nearest one; -1 when
// there are no areas.
inline int AreaIndex(std::span<const Rect> areas, Point point) {
  int nearest = -1;
  double nearest_distance = std::numeric_limits<double>::infinity();
  for (size_t index = 0; index < areas.size(); ++index) {
    if (areas[index].Contains(point)) {
      return static_cast<int>(index);
    }
    const double distance = DistanceSquared(areas[index], point);
    if (distance < nearest_distance) {
      nearest = static_cast<int>(index);
      nearest_distance = distance;
    }
  }
  return nearest;
}

// The part of the segment from `from` to `to` inside `rect`, as the
// parameters where it enters and leaves (0 at `from`, 1 at `to`); false when
// it misses (Liang-Barsky).
inline bool ClipSegment(Rect rect, Point from, Point to, double& enter,
                        double& leave) {
  enter = 0;
  leave = 1;
  const double dx = to.x - from.x;
  const double dy = to.y - from.y;
  const double p[4] = {-dx, dx, -dy, dy};
  const double q[4] = {from.x - rect.x, rect.MaxX() - from.x, from.y - rect.y,
                       rect.MaxY() - from.y};
  for (int side = 0; side < 4; ++side) {
    if (p[side] == 0) {
      if (q[side] < 0) {
        return false;
      }
      continue;
    }
    const double r = q[side] / p[side];
    if (p[side] < 0) {
      enter = std::max(enter, r);
    } else {
      leave = std::min(leave, r);
    }
  }
  return enter <= leave;
}

// Where a window released with its centre at `position`, moving at
// `velocity`, is thrown to (DEV-852): UIKit's projection, but no farther on
// each axis than the width or height of the screen it's released over, and
// never past the first other display the throw crosses. A hard throw still
// reaches a neighbouring display, never one beyond it, and no throw lands so
// far off every screen that the nearest one is a guess.
inline Point BoundedProject(std::span<const Rect> areas,
                            Point position,
                            Point velocity,
                            double rate = kDecelerationRate) {
  double dx = ProjectedDistance(velocity.x, rate);
  double dy = ProjectedDistance(velocity.y, rate);
  const int index = AreaIndex(areas, position);
  if (index < 0) {
    return {position.x + dx, position.y + dy};
  }
  const Rect& source = areas[static_cast<size_t>(index)];
  dx = std::clamp(dx, -source.width, source.width);
  dy = std::clamp(dy, -source.height, source.height);
  const Point projected{position.x + dx, position.y + dy};
  // The first other display along the way.
  int first = -1;
  double first_enter = std::numeric_limits<double>::infinity();
  double first_leave = 0;
  for (size_t other = 0; other < areas.size(); ++other) {
    double enter = 0;
    double leave = 0;
    if (static_cast<int>(other) == index ||
        !ClipSegment(areas[other], position, projected, enter, leave) ||
        leave <= enter) {
      continue;
    }
    if (enter < first_enter) {
      first = static_cast<int>(other);
      first_enter = enter;
      first_leave = leave;
    }
  }
  if (first < 0 || areas[static_cast<size_t>(first)].Contains(projected) ||
      source.Contains(projected)) {
    return projected;
  }
  // It would carry on past that display: it stops inside it instead, just
  // before where it would leave.
  const double stop = std::max(first_enter, first_leave - 1e-6);
  return {position.x + dx * stop, position.y + dy * stop};
}

// The frame nearest `frame` that keeps at least `visible` points of it, on
// each axis, inside one of `areas` (DEV-852): a two-finger drag can push the
// window past a screen's edge, but never off every screen. With no areas, or
// a frame already that far on one, it's unchanged.
inline constexpr double kMinimumVisible = 48;

inline Rect KeptOnScreen(std::span<const Rect> areas,
                         Rect frame,
                         double visible = kMinimumVisible) {
  Rect best = frame;
  double best_distance = std::numeric_limits<double>::infinity();
  for (const Rect& area : areas) {
    const double vx = std::min(visible, std::min(frame.width, area.width));
    const double vy = std::min(visible, std::min(frame.height, area.height));
    const double x = std::clamp(frame.x, area.x - frame.width + vx,
                                area.MaxX() - vx);
    const double y = std::clamp(frame.y, area.y - frame.height + vy,
                                area.MaxY() - vy);
    const double distance = DistanceSquared(Point{x, y}, Point{frame.x, frame.y});
    if (distance < best_distance) {
      best_distance = distance;
      best = {x, y, frame.width, frame.height};
    }
  }
  return best;
}

// Chromium caps the window at this share of its screen's work area.
inline constexpr double kMaxScreenFraction = 0.8;

// The size a window of `size` settles at on `area`. Arx applies it itself,
// so Chromium never has to clamp it: it keeps the aspect ratio and fits
// within Chromium's cap for that screen (`fraction` of each side, whole
// points, as VideoOverlayWindowViews::UpdateMaxSize computes it) and between
// the insets. `min`, Chromium's minimum, grows the whole window rather than
// one side, so a portrait video under a landscape minimum keeps its shape
// instead of being widened (DEV-848); where the minimum and the shape can't
// both fit the cap, the cap wins.
inline Size DestinationSize(Size size,
                            Rect area,
                            Size min = {},
                            double fraction = kMaxScreenFraction,
                            double inset = kEdgeInset) {
  if (area.width <= 0 || area.height <= 0 || size.width <= 0 ||
      size.height <= 0) {
    return size;
  }
  const double max_width = std::max(
      std::min(std::floor(area.width * fraction), area.width - 2 * inset),
      min.width);
  const double max_height = std::max(
      std::min(std::floor(area.height * fraction), area.height - 2 * inset),
      min.height);
  const double cap = std::min(max_width / size.width, max_height / size.height);
  const double fit = std::min(1.0, cap);
  // Grown to the minimum as a whole, but never past the cap: where the
  // video's shape and the minimum disagree, the screen wins.
  const double scale = std::min(
      std::max({fit, min.width / size.width, min.height / size.height}), cap);
  if (scale == 1) {
    return size;
  }
  // Whole points; a side that rounding left under its minimum by at most a
  // point takes the minimum.
  const auto snap = [](double value, double minimum) {
    const double whole = std::floor(value);
    return whole < minimum && minimum - whole <= 1 ? minimum : whole;
  };
  return {snap(size.width * scale, min.width),
          snap(size.height * scale, min.height)};
}

// The size part way through a settle from `from` to `to`, where `remaining`
// is 1 at the start and 0 at the end (clamped to that range).
inline Size InterpolatedSize(Size from, Size to, double remaining) {
  const double t = std::clamp(remaining, 0.0, 1.0);
  return {
      to.width + (from.width - to.width) * t,
      to.height + (from.height - to.height) * t,
  };
}

// How far, in points, a settle from `from` to `to` resizes the window.
inline double SizeSpan(Size from, Size to) {
  return std::max(std::abs(from.width - to.width),
                  std::abs(from.height - to.height));
}

// The origin of resting position `corner` (an index into SnapOrigins) for a
// window of `size` in `area`.
inline Point CornerOrigin(Rect area,
                          Size size,
                          int corner,
                          double inset = kEdgeInset) {
  return SnapOrigins(area, size, inset)[static_cast<size_t>(
      std::clamp(corner, 0, 3))];
}

// The frame of a settling window: `offset` away from resting position
// `corner` of `area`, placed for the window's current `size`. The corner
// stays exact whatever the size, so a resize mid-settle, Arx's or
// Chromium's, never strands the window.
inline Rect CornerFrame(Rect area,
                        int corner,
                        Size size,
                        Point offset,
                        double inset = kEdgeInset) {
  const Point origin = CornerOrigin(area, size, corner, inset);
  return {origin.x + offset.x, origin.y + offset.y, size.width, size.height};
}

// A resting position: the visible frame it's in, which of its four corners,
// the window's size there and its origin. `area_index` is -1 when there are
// no screens, and then the origin is where the window already is.
struct SnapTarget {
  int area_index = -1;
  Rect area;
  int corner = 0;
  Size size;
  Point origin;
};

// Where a window released at `frame` and moving at `velocity` comes to rest:
// its centre is projected forward (BoundedProject), the screen that point
// lands on (or the nearest one) is chosen from the visible frames in `areas`,
// the window takes the size Chromium will give it there, and the snap
// position whose centre is nearest the projected point wins.
inline SnapTarget Snap(std::span<const Rect> areas,
                       Rect frame,
                       Point velocity,
                       Size min = {},
                       double rate = kDecelerationRate,
                       double inset = kEdgeInset) {
  SnapTarget target;
  target.size = {frame.width, frame.height};
  target.origin = {frame.x, frame.y};
  const Point projected = BoundedProject(areas, frame.Center(), velocity, rate);
  const int index = AreaIndex(areas, projected);
  if (index < 0) {
    return target;
  }
  target.area_index = index;
  target.area = areas[static_cast<size_t>(index)];
  target.size = DestinationSize(target.size, target.area, min);
  double best_distance = std::numeric_limits<double>::infinity();
  const auto origins = SnapOrigins(target.area, target.size, inset);
  for (int corner = 0; corner < 4; ++corner) {
    const Point origin = origins[static_cast<size_t>(corner)];
    const Point centre{origin.x + target.size.width / 2,
                       origin.y + target.size.height / 2};
    const double distance = DistanceSquared(centre, projected);
    if (distance < best_distance) {
      target.corner = corner;
      target.origin = origin;
      best_distance = distance;
    }
  }
  return target;
}

// Where a window goes when the screens change (DEV-852): corner `corner` of
// area `area_index` if that screen is still there, else the corner nearest
// the window on the nearest screen. Either way at the size Chromium allows
// there, and without velocity.
inline SnapTarget Resnap(std::span<const Rect> areas,
                         Rect frame,
                         int area_index,
                         int corner,
                         Size min = {},
                         double inset = kEdgeInset) {
  if (area_index < 0 || static_cast<size_t>(area_index) >= areas.size()) {
    return Snap(areas, frame, {}, min, kDecelerationRate, inset);
  }
  SnapTarget target;
  target.area_index = area_index;
  target.area = areas[static_cast<size_t>(area_index)];
  target.corner = std::clamp(corner, 0, 3);
  target.size = DestinationSize({frame.width, frame.height}, target.area, min);
  target.origin = CornerOrigin(target.area, target.size, target.corner, inset);
  return target;
}

// Snap's origin alone.
inline Point SnapOrigin(std::span<const Rect> areas,
                        Rect frame,
                        Point velocity,
                        double rate = kDecelerationRate,
                        double inset = kEdgeInset) {
  return Snap(areas, frame, velocity, {}, rate, inset).origin;
}

// `frame` scaled by `factor` about `anchor`, keeping its aspect ratio. The
// scale keeps the size within `min` and `max` on both axes, and `max` wins
// where the two disagree. A zero or negative limit is no limit. The anchor is
// clamped inside the frame, so the frame never slides away from it.
inline Rect ScaledFrame(Rect frame,
                        double factor,
                        Point anchor,
                        Size min,
                        Size max) {
  if (frame.width <= 0 || frame.height <= 0 || !(factor > 0)) {
    return frame;
  }
  double scale = factor;
  if (min.width > 0) {
    scale = std::max(scale, min.width / frame.width);
  }
  if (min.height > 0) {
    scale = std::max(scale, min.height / frame.height);
  }
  if (max.width > 0) {
    scale = std::min(scale, max.width / frame.width);
  }
  if (max.height > 0) {
    scale = std::min(scale, max.height / frame.height);
  }
  const double ax = std::clamp(anchor.x, frame.x, frame.MaxX());
  const double ay = std::clamp(anchor.y, frame.y, frame.MaxY());
  return {
      ax - (ax - frame.x) * scale,
      ay - (ay - frame.y) * scale,
      frame.width * scale,
      frame.height * scale,
  };
}

// `frame` shrunk, keeping its aspect ratio, until it fits `area`, then moved
// inside it. An empty area or frame is returned unchanged.
inline Rect ConstrainedFrame(Rect frame, Rect area) {
  if (area.width <= 0 || area.height <= 0 || frame.width <= 0 ||
      frame.height <= 0) {
    return frame;
  }
  const double scale = std::min(
      {1.0, area.width / frame.width, area.height / frame.height});
  frame.width *= scale;
  frame.height *= scale;
  frame.x = std::clamp(frame.x, area.x, area.MaxX() - frame.width);
  frame.y = std::clamp(frame.y, area.y, area.MaxY() - frame.height);
  return frame;
}

// A spring by its response (the period of the undamped oscillation, in
// seconds) and damping ratio (1 settles without overshoot, less bounces).
struct SpringParameters {
  double response = 0;
  double damping = 1;
};

// A thrown window settles with a little bounce.
inline constexpr SpringParameters kThrowSpring{0.42, 0.78};

// With Reduce Motion it glides in without bounce.
inline constexpr SpringParameters kReducedMotionSpring{0.3, 1};

// The window's size settles without overshoot, so it never dips below the
// destination size or Chromium's minimum, and faster than it moves, so a
// window thrown onto a smaller screen already fits that screen's cap when it
// crosses over and Chromium has no reason to resize it.
inline constexpr SpringParameters kResizeSpring{0.15, 1};

// How a released window settles on its resting position.
struct Settle {
  SpringParameters spring;
  // Whether the spring starts at the release velocity.
  bool carries_velocity = true;
};

// Reduce Motion keeps the destination a throw picked, but drops the bounce
// and the carried velocity.
inline Settle SettleFor(bool reduce_motion) {
  if (reduce_motion) {
    return {kReducedMotionSpring, false};
  }
  return {kThrowSpring, true};
}

// An offset from the spring's target and its velocity.
struct SpringState {
  double offset = 0;
  double velocity = 0;
};

// The state `time` seconds after a spring started at `start`. Ratios above 1
// are treated as critical damping.
inline SpringState Spring(SpringState start,
                          double time,
                          SpringParameters parameters) {
  if (parameters.response <= 0 || time <= 0) {
    return parameters.response <= 0 ? SpringState{} : start;
  }
  const double omega = 2 * M_PI / parameters.response;
  const double zeta = std::max(parameters.damping, 0.0);
  const double x0 = start.offset;
  const double v0 = start.velocity;
  if (zeta < 1) {
    const double damped = omega * std::sqrt(1 - zeta * zeta);
    const double decay = std::exp(-zeta * omega * time);
    const double a = x0;
    const double b = (v0 + zeta * omega * x0) / damped;
    const double cosine = std::cos(damped * time);
    const double sine = std::sin(damped * time);
    const double offset = decay * (a * cosine + b * sine);
    const double velocity =
        -zeta * omega * offset +
        decay * (-a * damped * sine + b * damped * cosine);
    return {offset, velocity};
  }
  const double decay = std::exp(-omega * time);
  const double b = v0 + omega * x0;
  const double offset = decay * (x0 + b * time);
  const double velocity = decay * (b - omega * (x0 + b * time));
  return {offset, velocity};
}

// Whether a spring is close enough to rest to jump to its target: within half
// a point and slower than 10 points per second.
inline bool Settled(SpringState state) {
  return std::abs(state.offset) < 0.5 && std::abs(state.velocity) < 10;
}

// How far past its target, in `direction` (+1 or -1), a spring from `start`
// swings at most. Sampled over four responses, long enough for any of Arx's
// springs to come to rest; never below zero.
inline double SpringExcess(SpringState start,
                           SpringParameters parameters,
                           double direction) {
  if (parameters.response <= 0) {
    return 0;
  }
  constexpr int kSamples = 480;
  const double horizon = 4 * parameters.response;
  double excess = 0;
  for (int sample = 1; sample <= kSamples; ++sample) {
    const double time = horizon * sample / kSamples;
    excess = std::max(excess,
                      direction * Spring(start, time, parameters).offset);
  }
  return excess;
}

// How much farther than at rest a carried release velocity may swing a
// window past its resting corner, toward the screen edge, before
// SoftOvershoot squeezes it (DEV-852).
inline constexpr double kOvershootAllowance = 2 * kEdgeInset;

// The share of `start.velocity` a settle carries: all of it, unless that
// swings the window more than kOvershootAllowance farther past its target in
// `direction` than starting at rest would. A hard throw then still lands
// with a bounce, but a 20,000-point-a-second fling no longer carries the
// window hundreds of points past the corner (DEV-852).
inline double CarriedVelocity(SpringState start,
                              SpringParameters parameters,
                              double direction,
                              double allowance = kOvershootAllowance) {
  if (start.velocity == 0 || direction == 0) {
    return start.velocity;
  }
  const double limit =
      SpringExcess({start.offset, 0}, parameters, direction) + allowance;
  if (SpringExcess(start, parameters, direction) <= limit) {
    return start.velocity;
  }
  double low = 0;
  double high = 1;
  for (int step = 0; step < 24; ++step) {
    const double middle = (low + high) / 2;
    if (SpringExcess({start.offset, start.velocity * middle}, parameters,
                     direction) <= limit) {
      low = middle;
    } else {
      high = middle;
    }
  }
  return start.velocity * low;
}

// `excess`, how far a window is past its resting corner toward the screen's
// edge, squeezed so it never reaches `limit` (DEV-852): unchanged near zero,
// with the same slope there, so a small bounce looks as it always did.
inline double SoftOvershoot(double excess, double limit = kEdgeInset) {
  if (excess <= 0 || limit <= 0) {
    return excess;
  }
  return limit * (1 - std::exp(-excess / limit));
}

// The excess SoftOvershoot squeezes to `squeezed`, for `squeezed` below
// `limit`.
inline double UnsqueezedOvershoot(double squeezed, double limit = kEdgeInset) {
  if (squeezed <= 0 || limit <= 0) {
    return squeezed;
  }
  return -limit * std::log(1 - std::min(squeezed / limit, 1 - 1e-9));
}

// Two frames match when they differ by less than half a point on every side.
inline bool SameOrigin(Rect a, Rect b) {
  return std::abs(a.x - b.x) < 0.5 && std::abs(a.y - b.y) < 0.5;
}

inline bool SameSize(Rect a, Rect b) {
  return std::abs(a.width - b.width) < 0.5 &&
         std::abs(a.height - b.height) < 0.5;
}

inline bool SameFrame(Rect a, Rect b) {
  return SameOrigin(a, b) && SameSize(a, b);
}

// A settle onto a resting position, frame by frame.
//
// Position springs as an offset from the resting corner placed for the
// window's current size, and size springs (without overshoot) from where it
// started to the destination size, so the corner stays exact through any
// resize. When Chromium resizes the window on its own (UpdateMaxSize, on
// reaching a smaller screen), the settle carries on from the size Chromium
// chose with the same position, velocity and resize speed, and never asks for
// more than Chromium allowed. Anything that moves the window without resizing
// it stops the settle. A settle that hasn't come to rest within
// kMaxSettleTime finishes at its resting frame.
//
// It never leaves the screen it settles on (DEV-852): the release velocity
// it carries is bounded (CarriedVelocity), the bounce past the resting corner
// is squeezed to less than the inset (SoftOvershoot), so the window stays in
// the visible frame, and no frame goes beyond the box around that frame and
// where the window started.
class Settler {
 public:
  enum class Action {
    // Set the window to `frame` and report the result with Applied().
    kApply,
    // Set the window to `frame` and report it with Finished(): the settle is
    // over.
    kFinish,
    // Something else moved the window: leave it where it is.
    kStop,
  };

  struct Step {
    Action action = Action::kStop;
    Rect frame;
  };

  // The longest a settle runs, in seconds, before it finishes at its resting
  // frame. Springs settle well within it; it bounds a fight with Chromium.
  static constexpr double kMaxSettleTime = 3;

  Settler() = default;

  // Settles `frame`, moving at `velocity`, onto `target` with `spring`,
  // starting at `now`.
  Settler(SnapTarget target,
          SpringParameters spring,
          Rect frame,
          Point velocity,
          double now)
      : area_(target.area),
        corner_(target.corner),
        to_size_(target.size),
        spring_(spring),
        began_(now),
        bounds_(Union(target.area, frame)) {
    Begin(frame, velocity, {1, 0}, now);
  }

  // The next frame for a window whose frame is `current` at `now`.
  Step Next(Rect current, double now) {
    if (!SameFrame(current, last_)) {
      if (SameSize(current, last_)) {
        return {Action::kStop, current};
      }
      Rebase(current, now);
    }
    if (now - began_ > kMaxSettleTime) {
      return {Action::kFinish, FinalFrame()};
    }
    const Moment moment = At(now - start_time_);
    if (moment.done) {
      return {Action::kFinish, FinalFrame()};
    }
    return {Action::kApply, moment.frame};
  }

  // Reports what the window became after a kApply frame.
  void Applied(Rect requested, Rect applied, double now) {
    if (!SameSize(applied, requested)) {
      // Chromium resized it inside that move.
      Rebase(applied, now);
      return;
    }
    last_ = applied;
  }

  // Where the window ends up after a kFinish frame came out as `applied`:
  // the corner for the size it has, if Chromium overrode the size.
  Rect Finished(Rect applied) const {
    if (SameSize(applied, FinalFrame())) {
      return FinalFrame();
    }
    return CornerFrame(area_, corner_, {applied.width, applied.height},
                       {0, 0});
  }

  // The frame at rest.
  Rect FinalFrame() const {
    return CornerFrame(area_, corner_, to_size_, {0, 0});
  }

  Size to_size() const { return to_size_; }
  int rebases() const { return rebases_; }
  // The velocity the settle started with, after CarriedVelocity.
  Point carried() const { return {x_.velocity, y_.velocity}; }
  // No frame of the settle leaves this box.
  Rect bounds() const { return bounds_; }

 private:
  struct Moment {
    Rect frame;
    Point velocity;
    // The resize's speed, in points per second along its longer side.
    double resize_speed = 0;
    bool done = false;
  };

  static Rect Union(Rect a, Rect b) {
    const double x = std::min(a.x, b.x);
    const double y = std::min(a.y, b.y);
    return {x, y, std::max(a.MaxX(), b.MaxX()) - x,
            std::max(a.MaxY(), b.MaxY()) - y};
  }

  // Which way is past the resting corner, toward the nearer edge, on each
  // axis: -1 for a low corner, +1 for a high one, 0 where the window doesn't
  // fit between the insets and is centred.
  Point Outward(Size size) const {
    const auto origins = SnapOrigins(area_, size);
    const bool centred_x = origins[0].x == origins[1].x;
    const bool centred_y = origins[0].y == origins[2].y;
    return {centred_x ? 0.0 : (corner_ % 2 == 0 ? -1.0 : 1.0),
            centred_y ? 0.0 : (corner_ < 2 ? -1.0 : 1.0)};
  }

  void Begin(Rect frame, Point velocity, SpringState remaining, double now) {
    from_size_ = {frame.width, frame.height};
    bounds_ = Union(bounds_, frame);
    const Point corner = CornerOrigin(area_, from_size_, corner_);
    const Point outward = Outward(to_size_);
    // A window starting past the edge's inset (dragged over the edge, or
    // coming from elsewhere) isn't squeezed on that axis; one starting in the
    // squeezed band picks up the spring where the squeeze put it.
    const auto start = [](double offset, double direction, bool& squeezes) {
      const double excess = direction * offset;
      squeezes = direction != 0 && excess < kEdgeInset;
      return squeezes && excess > 0
                 ? direction * UnsqueezedOvershoot(excess)
                 : offset;
    };
    x_ = {start(frame.x - corner.x, outward.x, squeezes_x_), 0};
    y_ = {start(frame.y - corner.y, outward.y, squeezes_y_), 0};
    x_.velocity =
        CarriedVelocity({x_.offset, velocity.x}, spring_, outward.x);
    y_.velocity =
        CarriedVelocity({y_.offset, velocity.y}, spring_, outward.y);
    remaining_ = remaining;
    start_time_ = now;
    last_ = frame;
  }

  Moment At(double time) const {
    const SpringState x = Spring(x_, time, spring_);
    const SpringState y = Spring(y_, time, spring_);
    const SpringState remaining = Spring(remaining_, time, kResizeSpring);
    const double span = SizeSpan(from_size_, to_size_);
    Moment moment;
    moment.done = Settled(x) && Settled(y) &&
                  Settled({remaining.offset * span, remaining.velocity * span});
    Size size = InterpolatedSize(from_size_, to_size_, remaining.offset);
    // Whole points, as Chromium sizes its widgets.
    size = {std::round(size.width), std::round(size.height)};
    // The bounce past the corner stays inside the visible frame.
    const Point outward = Outward(size);
    const double ox = outward.x == 0 || !squeezes_x_
                          ? x.offset
                          : outward.x * SoftOvershoot(outward.x * x.offset);
    const double oy = outward.y == 0 || !squeezes_y_
                          ? y.offset
                          : outward.y * SoftOvershoot(outward.y * y.offset);
    Rect frame = CornerFrame(area_, corner_, size, {ox, oy});
    // And nothing goes beyond where the window started or the screen.
    frame.x = std::clamp(frame.x, bounds_.x,
                         std::max(bounds_.x, bounds_.MaxX() - frame.width));
    frame.y = std::clamp(frame.y, bounds_.y,
                         std::max(bounds_.y, bounds_.MaxY() - frame.height));
    moment.frame = frame;
    moment.velocity = {x.velocity, y.velocity};
    moment.resize_speed = remaining.velocity * span;
    return moment;
  }

  // Carries on from `frame`, a size Chromium chose, at the same position,
  // velocity and resize speed.
  void Rebase(Rect frame, double now) {
    const Moment moment = At(now - start_time_);
    const double scale =
        std::min({1.0, frame.width / to_size_.width,
                  frame.height / to_size_.height});
    if (scale < 1) {
      to_size_ = {std::floor(to_size_.width * scale),
                  std::floor(to_size_.height * scale)};
    }
    rebases_ += 1;
    const double span = SizeSpan({frame.width, frame.height}, to_size_);
    const SpringState remaining =
        span < 0.5 ? SpringState{0, 0}
                   : SpringState{1, moment.resize_speed / span};
    Begin(frame, moment.velocity, remaining, now);
  }

  Rect area_;
  int corner_ = 0;
  Size from_size_;
  Size to_size_;
  SpringParameters spring_;
  SpringState x_;
  SpringState y_;
  // The share of the resize still to go: 1 at the start, 0 at rest.
  SpringState remaining_;
  double start_time_ = 0;
  // When the settle began, for kMaxSettleTime.
  double began_ = 0;
  int rebases_ = 0;
  // The frame the settle last saw the window at.
  Rect last_;
  // The target area and every frame the settle started from.
  Rect bounds_;
  // Whether the bounce past the corner is squeezed on each axis.
  bool squeezes_x_ = true;
  bool squeezes_y_ = true;
};

}  // namespace arx_pip

#endif  // CHROME_BROWSER_UI_VIEWS_OVERLAY_ARX_PIP_MOTION_H_
