// DEV-825: the Picture in Picture window's projection, snapping, pinch and
// spring math, with DEV-848's 16-point inset and aspect-keeping minimum, and
// DEV-852's bounded throws, display changes and on-screen drags. Compiled and
// run by Scripts/tests/test_pip_motion.py.

#include "pip/arx_pip_motion.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <span>
#include <vector>

namespace {

int failures = 0;

void Check(bool condition, const char* what, int line) {
  if (!condition) {
    std::fprintf(stderr, "line %d: %s\n", line, what);
    failures += 1;
  }
}

#define CHECK(condition) Check((condition), #condition, __LINE__)

bool Near(double a, double b, double tolerance = 1e-6) {
  return std::abs(a - b) <= tolerance;
}

bool Same(arx_pip::Point a, arx_pip::Point b, double tolerance = 1e-6) {
  return Near(a.x, b.x, tolerance) && Near(a.y, b.y, tolerance);
}

using arx_pip::Point;
using arx_pip::Rect;
using arx_pip::Sample;
using arx_pip::Size;

// The resting inset, 16 points since DEV-848.
constexpr double kI = arx_pip::kEdgeInset;

void TestProjection() {
  // UIKit's normal rate coasts about half a second's worth of velocity.
  CHECK(Near(arx_pip::ProjectedDistance(1000), 499));
  CHECK(Near(arx_pip::ProjectedDistance(-1000), -499));
  CHECK(Near(arx_pip::ProjectedDistance(0), 0));
  // A faster deceleration coasts less.
  CHECK(Near(arx_pip::ProjectedDistance(1000, 0.99), 99));
  CHECK(std::abs(arx_pip::ProjectedDistance(1000, 0.99)) <
        std::abs(arx_pip::ProjectedDistance(1000)));
  // Rates outside (0, 1) don't coast.
  CHECK(Near(arx_pip::ProjectedDistance(1000, 1), 0));
  CHECK(Near(arx_pip::ProjectedDistance(1000, 0), 0));
  CHECK(Same(arx_pip::Project({10, 20}, {1000, -2000}), {509, -978}));
}

void TestVelocity() {
  CHECK(Same(arx_pip::Velocity({}, 1), {0, 0}));

  // Steady movement at 500 points per second to the right, 250 down.
  std::vector<Sample> steady;
  for (int step = 0; step <= 20; ++step) {
    const double time = step * 0.01;
    steady.push_back({time, {500 * time, -250 * time}});
  }
  CHECK(Same(arx_pip::Velocity(steady, 0.2), {500, -250}, 1e-6));

  // Only the last tenth of a second counts: a slow start doesn't dilute a
  // fast finish.
  std::vector<Sample> accelerating = {
      {0.0, {0, 0}}, {0.5, {10, 0}}, {0.55, {60, 0}}, {0.6, {110, 0}}};
  CHECK(Same(arx_pip::Velocity(accelerating, 0.6), {1000, 0}, 1e-6));

  // Holding still before release throws nothing.
  CHECK(Same(arx_pip::Velocity(steady, 0.5), {0, 0}));

  // Sparse events still give a velocity from the sample before the window.
  std::vector<Sample> sparse = {{0.0, {0, 0}}, {0.15, {300, 0}}};
  CHECK(Same(arx_pip::Velocity(sparse, 0.15), {2000, 0}, 1e-6));

  // A single sample, or samples at one instant, have no velocity.
  CHECK(Same(arx_pip::Velocity(std::vector<Sample>{{1, {5, 5}}}, 1), {0, 0}));
  std::vector<Sample> instant = {{1, {0, 0}}, {1, {50, 0}}};
  CHECK(Same(arx_pip::Velocity(instant, 1), {0, 0}));
}

void TestSnapOrigins() {
  const Rect screen{0, 0, 1440, 900};
  const auto origins = arx_pip::SnapOrigins(screen, {400, 225});
  // The inset from the visible frame's edges.
  CHECK(Same(origins[0], {kI, kI}));
  CHECK(Same(origins[1], {1440 - kI - 400, kI}));
  CHECK(Same(origins[2], {kI, 900 - kI - 225}));
  CHECK(Same(origins[3], {1440 - kI - 400, 900 - kI - 225}));

  // A visible frame that doesn't start at zero (menu bar, Dock, a second
  // screen to the left).
  const auto offset =
      arx_pip::SnapOrigins({-1920, 40, 1920, 1000}, {300, 200}, 24);
  CHECK(Same(offset[0], {-1896, 64}));
  CHECK(Same(offset[3], {-324, 816}));

  // Too wide to fit between the insets: centred on that axis only.
  const auto wide = arx_pip::SnapOrigins({0, 0, 400, 900}, {380, 200});
  CHECK(Same(wide[0], {10, kI}));
  CHECK(Same(wide[1], {10, kI}));
  CHECK(Same(wide[2], {10, 900 - kI - 200}));
}

void TestSnapping() {
  const std::vector<Rect> one = {{0, 0, 1440, 900}};
  const Point bottom_left{kI, kI};
  const Point bottom_right{1440 - kI - 400, kI};
  const Point top_left{kI, 900 - kI - 225};
  const Point top_right{1440 - kI - 400, 900 - kI - 225};

  // Released at rest: the nearest corner.
  CHECK(Same(arx_pip::SnapOrigin(one, {900, 500, 400, 225}, {0, 0}),
             top_right));
  CHECK(Same(arx_pip::SnapOrigin(one, {100, 120, 400, 225}, {0, 0}),
             bottom_left));

  // Released just right of centre, at rest, stays right; a modest throw to
  // the left carries it to the left corner.
  const Rect middle{560, 600, 400, 225};
  CHECK(Same(arx_pip::SnapOrigin(one, middle, {0, 0}), top_right));
  CHECK(Same(arx_pip::SnapOrigin(one, middle, {-400, 0}), top_left));

  // A throw down from the top right lands bottom right.
  CHECK(Same(arx_pip::SnapOrigin(one, {1016, 651, 400, 225}, {0, -1500}),
             bottom_right));

  // A diagonal throw crosses to the opposite corner.
  CHECK(Same(arx_pip::SnapOrigin(one, {1016, 651, 400, 225}, {-3000, -2000}),
             bottom_left));

  // Thrown past the screen edge it still rests inside, at the inset.
  CHECK(Same(arx_pip::SnapOrigin(one, {1016, 24, 400, 225}, {8000, -8000}),
             bottom_right));

  // Partly off screen at release, it comes back to the corner.
  CHECK(Same(arx_pip::SnapOrigin(one, {1300, -100, 400, 225}, {0, 0}),
             bottom_right));

  // No screens: stays put.
  CHECK(Same(arx_pip::SnapOrigin({}, {7, 8, 400, 225}, {1000, 0}), {7, 8}));
}

void TestMultipleScreens() {
  // A laptop at the origin, an external screen to its right that sits higher.
  const std::vector<Rect> screens = {{0, 0, 1440, 875}, {1440, 0, 2560, 1415}};

  // Released over the second screen: its corners.
  CHECK(Same(arx_pip::SnapOrigin(screens, {2000, 900, 400, 225}, {0, 0}),
             {1440 + kI, 1415 - kI - 225}));

  // Thrown right from the laptop's right edge, it carries onto the second
  // screen; at rest it stays on the laptop.
  const Rect edge{1016, 24, 400, 225};
  CHECK(Same(arx_pip::SnapOrigin(screens, edge, {0, 0}), {1440 - kI - 400, kI}));
  CHECK(Same(arx_pip::SnapOrigin(screens, edge, {1500, 0}), {1440 + kI, kI}));

  // Thrown far beyond every screen, the projection stops a laptop's width
  // away (DEV-852): onto the neighbouring screen, at its near corner.
  CHECK(Same(arx_pip::SnapOrigin(screens, edge, {40000, 0}),
             {1440 + kI, kI}));
  CHECK(Same(arx_pip::SnapOrigin(screens, {kI, kI, 400, 225}, {-40000, 0}),
             {kI, kI}));

  // Into the gap above the laptop: the nearest screen is the laptop.
  CHECK(arx_pip::AreaIndex(screens, {700, 1200}) == 0);
  CHECK(arx_pip::AreaIndex(screens, {1500, 1200}) == 1);
  CHECK(arx_pip::AreaIndex({}, {0, 0}) == -1);
}

void TestScaling() {
  const Rect frame{100, 100, 400, 225};
  const Size min{284, 160};
  const Size max{1152, 720};

  // Doubles about the centre, keeping 16:9.
  const Rect doubled =
      arx_pip::ScaledFrame(frame, 2, frame.Center(), min, max);
  CHECK(Near(doubled.width, 800) && Near(doubled.height, 450));
  CHECK(Same(doubled.Center(), frame.Center()));

  // About a corner, that corner stays put.
  const Rect anchored = arx_pip::ScaledFrame(frame, 1.5, {100, 100}, min, max);
  CHECK(Same({anchored.x, anchored.y}, {100, 100}));
  CHECK(Near(anchored.width / anchored.height, 400.0 / 225));

  // The maximum caps the scale on the tighter axis; the ratio holds.
  const Rect capped = arx_pip::ScaledFrame(frame, 10, frame.Center(), min, max);
  CHECK(Near(capped.width, 1152));
  CHECK(Near(capped.height, 648));

  // The minimum floors it the same way.
  const Rect floored =
      arx_pip::ScaledFrame(frame, 0.1, frame.Center(), min, max);
  CHECK(Near(floored.height, 160));
  CHECK(Near(floored.width, 160 * 400.0 / 225));

  // An anchor outside the frame is clamped to its edge.
  const Rect outside = arx_pip::ScaledFrame(frame, 2, {-500, 0}, min, max);
  CHECK(Same({outside.x, outside.y}, {100, 100}));

  // No limits, and nonsense factors.
  CHECK(Near(arx_pip::ScaledFrame(frame, 3, frame.Center(), {}, {}).width,
             1200));
  CHECK(Near(arx_pip::ScaledFrame(frame, 0, frame.Center(), {}, {}).width,
             400));
  CHECK(Near(arx_pip::ScaledFrame(frame, NAN, frame.Center(), {}, {}).width,
             400));
}

void TestConstraining() {
  const Rect area{0, 0, 1440, 900};
  // Inside already: unchanged.
  const Rect inside = arx_pip::ConstrainedFrame({10, 10, 400, 225}, area);
  CHECK(Same({inside.x, inside.y}, {10, 10}) && Near(inside.width, 400));
  // Off the right edge: moved back in.
  const Rect moved = arx_pip::ConstrainedFrame({1300, 10, 400, 225}, area);
  CHECK(Near(moved.x, 1040));
  // Too big: shrunk to fit, aspect kept.
  const Rect shrunk = arx_pip::ConstrainedFrame({0, 0, 2000, 1125}, area);
  CHECK(Near(shrunk.height, 810) && Near(shrunk.width, 1440));
}

void TestSpring() {
  const arx_pip::SpringState start{100, 0};

  // At the start nothing has moved.
  const auto initial = arx_pip::Spring(start, 0, arx_pip::kThrowSpring);
  CHECK(Near(initial.offset, 100) && Near(initial.velocity, 0));

  // It settles within a second either way.
  CHECK(arx_pip::Settled(arx_pip::Spring(start, 1.5, arx_pip::kThrowSpring)));
  CHECK(arx_pip::Settled(
      arx_pip::Spring(start, 1.5, arx_pip::kReducedMotionSpring)));

  // The throw spring overshoots a little; critical damping never does.
  double throw_min = 0;
  double reduced_min = 0;
  for (int step = 1; step <= 300; ++step) {
    const double time = step / 120.0;
    throw_min = std::min(
        throw_min, arx_pip::Spring(start, time, arx_pip::kThrowSpring).offset);
    reduced_min = std::min(
        reduced_min,
        arx_pip::Spring(start, time, arx_pip::kReducedMotionSpring).offset);
  }
  CHECK(throw_min < -0.5);
  CHECK(throw_min > -20);
  CHECK(reduced_min > -1e-9);

  // The velocity handed over carries the window past its start first.
  const auto carried =
      arx_pip::Spring({0, 2000}, 0.02, arx_pip::kThrowSpring);
  CHECK(carried.offset > 0);

  // The reported velocity is the derivative of the offset.
  for (const auto parameters :
       {arx_pip::kThrowSpring, arx_pip::kReducedMotionSpring}) {
    const double t = 0.1;
    const double h = 1e-6;
    const auto state = arx_pip::Spring({80, -600}, t, parameters);
    const double slope = (arx_pip::Spring({80, -600}, t + h, parameters).offset -
                          arx_pip::Spring({80, -600}, t - h, parameters).offset) /
                         (2 * h);
    CHECK(Near(state.velocity, slope, 1e-3));
  }

  // Overdamped ratios behave as critical damping.
  const arx_pip::SpringParameters stiff{0.3, 2};
  CHECK(Near(arx_pip::Spring(start, 0.2, stiff).offset,
             arx_pip::Spring(start, 0.2, arx_pip::kReducedMotionSpring).offset));

  // No response: already there.
  CHECK(Near(arx_pip::Spring(start, 0.1, {0, 1}).offset, 0));
}

void TestReduceMotion() {
  const auto normal = arx_pip::SettleFor(false);
  CHECK(normal.carries_velocity);
  CHECK(normal.spring.damping < 1);
  const auto reduced = arx_pip::SettleFor(true);
  CHECK(!reduced.carries_velocity);
  CHECK(Near(reduced.spring.damping, 1));
}


void TestDestinationSize() {
  const Rect laptop{0, 0, 1440, 875};
  // Small enough already: unchanged.
  const Size small = arx_pip::DestinationSize({400, 225}, laptop);
  CHECK(Near(small.width, 400) && Near(small.height, 225));
  // Too big for Chromium's 80% cap: scaled down with its aspect ratio, to
  // whole points, within the cap on both axes.
  const Size big = arx_pip::DestinationSize({1600, 900}, laptop);
  CHECK(Near(big.width, 1152) && Near(big.height, 648));
  CHECK(big.width <= std::floor(1440 * 0.8) && big.height <= std::floor(875 * 0.8));
  // Codex's case: 2048 x 1132 onto the laptop.
  const Size large = arx_pip::DestinationSize({2048, 1132}, laptop);
  CHECK(large.width <= 1152 && large.height <= 700);
  CHECK(Near(large.width / large.height, 2048.0 / 1132, 0.01));
  // A tall window is limited by height instead.
  const Size tall = arx_pip::DestinationSize({600, 1200}, laptop);
  CHECK(Near(tall.height, 700) && Near(tall.width, 350));
  // Never below the minimum.
  const Size floored =
      arx_pip::DestinationSize({1600, 900}, {0, 0, 300, 200}, {284, 160});
  CHECK(Near(floored.width, 284) && Near(floored.height, 160));
  // A portrait video under a landscape minimum grows as a whole, keeping its
  // shape, instead of being widened on one axis (DEV-848).
  const Size portrait = arx_pip::DestinationSize({180, 320}, laptop, {260, 146});
  CHECK(portrait.width >= 260 - 1 && portrait.height >= 146);
  CHECK(Near(portrait.width / portrait.height, 180.0 / 320, 0.01));
  // Shrinking a portrait video past the cap keeps its shape too.
  const Size tall_portrait = arx_pip::DestinationSize({720, 1280}, laptop, {260, 146});
  CHECK(tall_portrait.height <= 700);
  CHECK(Near(tall_portrait.width / tall_portrait.height, 720.0 / 1280, 0.01));
  // Codex's case: a tall, thin window whose minimum width would push its
  // height past the cap stays inside the cap with its shape kept.
  const Size thin = arx_pip::DestinationSize({284, 1000}, laptop, {284, 160});
  CHECK(thin.height <= 700 && thin.width <= 1152);
  CHECK(Near(thin.width / thin.height, 284.0 / 1000, 0.01));
  // No area or no size: unchanged.
  CHECK(Near(arx_pip::DestinationSize({1600, 900}, {}).width, 1600));
  CHECK(Near(arx_pip::DestinationSize({0, 0}, laptop).width, 0));
}

void TestInterpolatedSize() {
  const Size from{2048, 1132};
  const Size to{1152, 637};
  const Size start = arx_pip::InterpolatedSize(from, to, 1);
  const Size end = arx_pip::InterpolatedSize(from, to, 0);
  const Size half = arx_pip::InterpolatedSize(from, to, 0.5);
  CHECK(Near(start.width, 2048) && Near(end.width, 1152));
  CHECK(Near(half.width, 1600) && Near(half.height, 884.5));
  // Clamped: an overshooting spring never goes past either end.
  CHECK(Near(arx_pip::InterpolatedSize(from, to, -0.2).width, 1152));
  CHECK(Near(arx_pip::InterpolatedSize(from, to, 1.3).width, 2048));
  CHECK(Near(arx_pip::SizeSpan(from, to), 896));
  CHECK(Near(arx_pip::SizeSpan(to, to), 0));
}

void TestThrowOntoSmallerScreen() {
  // Codex's case: a large window on an external display, thrown toward the
  // laptop's top-right corner.
  const std::vector<Rect> screens = {{0, 0, 1440, 875}, {1440, 0, 2560, 1415}};
  const Rect large{1500, 200, 2048, 1132};
  const arx_pip::SnapTarget target =
      arx_pip::Snap(screens, large, {-2700, 100}, {284, 160});
  CHECK(target.area_index == 0);
  CHECK(target.corner == 3);
  CHECK(target.size.width <= 1152 && target.size.height <= 700);
  // At rest, every edge it's near sits exactly at the inset, on screen.
  const Rect rest = arx_pip::CornerFrame(target.area, target.corner,
                                         target.size, {0, 0});
  CHECK(Near(rest.MaxX(), 1440 - kI) && Near(rest.MaxY(), 875 - kI));
  CHECK(rest.x >= kI && rest.y >= kI);
  CHECK(Same({rest.x, rest.y}, target.origin));

  // All the way through the settle, the size heads for the destination and,
  // with no offset left, the corner stays at the inset for whatever size the
  // window has.
  for (int step = 0; step <= 10; ++step) {
    const Size size = arx_pip::InterpolatedSize(
        {large.width, large.height}, target.size, 1 - step / 10.0);
    const Rect frame =
        arx_pip::CornerFrame(target.area, target.corner, size, {0, 0});
    CHECK(Near(frame.MaxX(), 1440 - kI) || frame.width > 1440 - 2 * kI);
  }
  // A size Chromium chose instead still lands at the corner.
  const Rect chromium =
      arx_pip::CornerFrame(target.area, target.corner, {1100, 650}, {0, 0});
  CHECK(Near(chromium.MaxX(), 1440 - kI) && Near(chromium.MaxY(), 875 - kI));
  // The offset is relative to that corner.
  const Rect offset =
      arx_pip::CornerFrame(target.area, target.corner, target.size, {-30, 12});
  CHECK(Near(offset.x, rest.x - 30) && Near(offset.y, rest.y + 12));

  // The corner index names the same position for any size.
  CHECK(Same(arx_pip::CornerOrigin(target.area, target.size, target.corner),
             target.origin));
  CHECK(Same(arx_pip::CornerOrigin(target.area, {400, 225}, 9),
             arx_pip::SnapOrigins(target.area, {400, 225})[3]));

  // No screens: stays put at its own size.
  const arx_pip::SnapTarget none = arx_pip::Snap({}, large, {0, 0});
  CHECK(none.area_index == -1 && Same(none.origin, {1500, 200}));
  CHECK(Near(none.size.width, 2048));
}

// A fake Chromium for whole settles: what the window becomes when Arx sets
// `requested`. `mode` 0 never resizes; 1 clamps each side to 80% of the
// screen it overlaps most, keeping the top edge, on every move (stricter than
// UpdateMaxSize, which only does so when the screen changes); 2 is
// adversarial and shrinks every resize by a point more than asked.
Rect Chromium(std::span<const Rect> screens,
              Rect current,
              Rect requested,
              int mode) {
  if (mode == 0) {
    return requested;
  }
  if (mode == 2) {
    if (arx_pip::SameSize(current, requested)) {
      return requested;
    }
    return {requested.x, requested.MaxY() - (requested.height - 1),
            requested.width - 1, requested.height - 1};
  }
  const Rect* best = nullptr;
  double best_overlap = -1;
  for (const Rect& screen : screens) {
    const double w = std::max(
        0.0, std::min(screen.MaxX(), requested.MaxX()) -
                 std::max(screen.x, requested.x));
    const double h = std::max(
        0.0, std::min(screen.MaxY(), requested.MaxY()) -
                 std::max(screen.y, requested.y));
    if (w * h > best_overlap) {
      best_overlap = w * h;
      best = &screen;
    }
  }
  const double max_width = std::max(std::floor(best->width * 0.8), 284.0);
  const double max_height = std::max(std::floor(best->height * 0.8), 160.0);
  Rect result = requested;
  result.width = std::min(requested.width, max_width);
  result.height = std::min(requested.height, max_height);
  result.y = requested.MaxY() - result.height;
  return result;
}

struct Outcome {
  Rect frame;
  bool finished = false;
  bool stopped = false;
  double time = 0;
  // The largest change in per-frame movement: a discontinuity, not speed.
  double largest_jump = 0;
};

// Runs a settle at 120 frames a second, as ArxPiPWindowMotion's step does.
Outcome Simulate(std::span<const Rect> screens,
                 Rect start,
                 Point velocity,
                 int mode,
                 bool reduce_motion = false,
                 double interfere_at = -1) {
  const arx_pip::SnapTarget target =
      arx_pip::Snap(screens, start, velocity, {284, 160});
  const arx_pip::Settle settle = arx_pip::SettleFor(reduce_motion);
  arx_pip::Settler settler(target, settle.spring, start,
                           settle.carries_velocity ? velocity : Point(), 0);
  Outcome outcome;
  Rect window = start;
  Point last_step{settle.carries_velocity ? velocity.x / 120 : 0,
                  settle.carries_velocity ? velocity.y / 120 : 0};
  for (int frame = 1; frame <= 600; ++frame) {
    const double now = frame / 120.0;
    if (interfere_at > 0 && now >= interfere_at && now < interfere_at + 0.005) {
      window.x += 40;  // Something else moves it.
    }
    const Point before = window.Center();
    const arx_pip::Settler::Step step = settler.Next(window, now);
    outcome.time = now;
    if (step.action == arx_pip::Settler::Action::kStop) {
      outcome.stopped = true;
      break;
    }
    window = Chromium(screens, window, step.frame, mode);
    if (step.action == arx_pip::Settler::Action::kFinish) {
      window = Chromium(screens, window, settler.Finished(window), mode);
      outcome.finished = true;
    } else {
      settler.Applied(step.frame, window, now);
    }
    const Point moved{window.Center().x - before.x,
                      window.Center().y - before.y};
    outcome.largest_jump = std::max(
        outcome.largest_jump, std::sqrt(arx_pip::DistanceSquared(moved, last_step)));
    last_step = moved;
    if (outcome.finished) {
      break;
    }
  }
  outcome.frame = window;
  return outcome;
}

bool RestsAtCorner(Rect frame, Rect area) {
  const double inset = arx_pip::kEdgeInset;
  const bool x = Near(frame.x, area.x + inset, 0.5) ||
                 Near(frame.MaxX(), area.MaxX() - inset, 0.5);
  const bool y = Near(frame.y, area.y + inset, 0.5) ||
                 Near(frame.MaxY(), area.MaxY() - inset, 0.5);
  const bool inside = frame.x >= area.x + inset - 0.5 &&
                      frame.MaxX() <= area.MaxX() - inset + 0.5 &&
                      frame.y >= area.y + inset - 0.5 &&
                      frame.MaxY() <= area.MaxY() - inset + 0.5;
  return x && y && inside;
}

void TestSettleOntoSmallerScreen() {
  const std::vector<Rect> screens = {{0, 0, 1440, 875}, {1440, 0, 2560, 1415}};
  const Rect laptop = screens[0];
  // Codex's case: 2048 x 1132 on the external display, thrown toward the
  // laptop's top-right corner, against each kind of Chromium.
  const Rect large{1500, 200, 2048, 1132};
  for (const bool reduce : {false, true}) {
    const Outcome alone = Simulate(screens, large, {-2700, 100}, 0, reduce);
    for (int mode = 0; mode <= 1; ++mode) {
      const Outcome outcome =
          Simulate(screens, large, {-2700, 100}, mode, reduce);
      CHECK(outcome.finished);
      CHECK(outcome.time < 1.5);
      CHECK(RestsAtCorner(outcome.frame, laptop));
      CHECK(Near(outcome.frame.MaxX(), 1440 - kI, 0.5));
      CHECK(Near(outcome.frame.MaxY(), 875 - kI, 0.5));
      // Arx applied the size itself, keeping the aspect ratio.
      CHECK(outcome.frame.width <= 1152 && outcome.frame.height <= 700);
      CHECK(Near(outcome.frame.width / outcome.frame.height, 2048.0 / 1132,
                 0.01));
      // Even a Chromium that clamps on every move adds no jump: the window
      // already fits the laptop when it crosses over.
      CHECK(outcome.largest_jump <= alone.largest_jump + 1);
    }
  }
}

void TestSettleOnSameScreen() {
  const std::vector<Rect> one = {{0, 0, 1440, 900}};
  // An ordinary throw keeps its size and rests at the corner.
  for (int mode = 0; mode <= 1; ++mode) {
    const Outcome outcome =
        Simulate(one, {560, 600, 400, 225}, {-400, 0}, mode);
    CHECK(outcome.finished);
    CHECK(RestsAtCorner(outcome.frame, one[0]));
    CHECK(Same({outcome.frame.x, outcome.frame.y}, {kI, 900 - kI - 225}, 0.5));
    CHECK(Near(outcome.frame.width, 400) && Near(outcome.frame.height, 225));
  }
  // Already at rest: finishes at once, unchanged.
  const Outcome rest = Simulate(one, {kI, kI, 400, 225}, {0, 0}, 1);
  CHECK(rest.finished && rest.time < 0.02);
  CHECK(Same({rest.frame.x, rest.frame.y}, {kI, kI}));
  // A window bigger than the cap on its own screen shrinks into the corner.
  const Outcome big = Simulate(one, {100, 100, 1300, 760}, {0, 0}, 0);
  CHECK(big.finished && RestsAtCorner(big.frame, one[0]));
  CHECK(big.frame.width <= 1152 && big.frame.height <= 720);
}

void TestSettleStopsWhenMovedElsewhere() {
  const std::vector<Rect> one = {{0, 0, 1440, 900}};
  const Outcome outcome =
      Simulate(one, {560, 600, 400, 225}, {-400, 0}, 0, false, 0.1);
  CHECK(outcome.stopped);
  CHECK(!outcome.finished);
}

void TestSettleEndsDespiteEndlessResizes() {
  // An adversarial Chromium that shrinks every resize: the settle still ends
  // by its deadline, exactly at the corner for the size the window has.
  const std::vector<Rect> screens = {{0, 0, 1440, 875}, {1440, 0, 2560, 1415}};
  const Outcome outcome =
      Simulate(screens, {1500, 200, 2048, 1132}, {-2700, 100}, 2);
  CHECK(outcome.finished);
  CHECK(outcome.time <= arx_pip::Settler::kMaxSettleTime + 0.02);
  CHECK(RestsAtCorner(outcome.frame, screens[0]));
  CHECK(Near(outcome.frame.MaxX(), 1440 - kI, 0.5));
  CHECK(Near(outcome.frame.MaxY(), 875 - kI, 0.5));
}

void TestThrowSpringBouncesAndReduceMotionDoesNot() {
  // A throw to the bottom-left overshoots the corner a little; with Reduce
  // Motion it never passes it.
  const std::vector<Rect> one = {{0, 0, 1440, 900}};
  for (const bool reduce : {false, true}) {
    const arx_pip::SnapTarget target =
        arx_pip::Snap(one, {300, 300, 400, 225}, {-1500, -1500});
    const arx_pip::Settle settle = arx_pip::SettleFor(reduce);
    arx_pip::Settler settler(target, settle.spring, {300, 300, 400, 225},
                             settle.carries_velocity ? Point{-1500, -1500}
                                                     : Point(),
                             0);
    Rect window{300, 300, 400, 225};
    double lowest = window.x;
    for (int frame = 1; frame <= 600; ++frame) {
      const auto step = settler.Next(window, frame / 120.0);
      if (step.action != arx_pip::Settler::Action::kApply) {
        window = step.frame;
        break;
      }
      window = step.frame;
      settler.Applied(step.frame, window, frame / 120.0);
      lowest = std::min(lowest, window.x);
    }
    CHECK(Same({window.x, window.y}, {kI, kI}, 0.5));
    if (reduce) {
      CHECK(lowest >= kI - 0.5);
    } else {
      CHECK(lowest < kI - 0.5);
      CHECK(lowest > kI - 40);
    }
  }
}

// Every frame of a settle, at 120 frames a second, with a Chromium that never
// resizes, until it finishes, stops or three seconds pass.
struct Trace {
  std::vector<Rect> frames;
  bool finished = false;
  arx_pip::SnapTarget target;
};

Trace Run(std::span<const Rect> screens,
          Rect start,
          Point velocity,
          bool reduce_motion = false) {
  Trace trace;
  trace.target = arx_pip::Snap(screens, start, velocity, {284, 160});
  const arx_pip::Settle settle = arx_pip::SettleFor(reduce_motion);
  arx_pip::Settler settler(trace.target, settle.spring, start,
                           settle.carries_velocity ? velocity : Point(), 0);
  Rect window = start;
  for (int frame = 1; frame <= 360; ++frame) {
    const double now = frame / 120.0;
    const auto step = settler.Next(window, now);
    if (step.action == arx_pip::Settler::Action::kStop) {
      break;
    }
    window = step.frame;
    trace.frames.push_back(window);
    if (step.action == arx_pip::Settler::Action::kFinish) {
      window = settler.Finished(window);
      trace.frames.push_back(window);
      trace.finished = true;
      break;
    }
    settler.Applied(step.frame, window, now);
  }
  return trace;
}

bool Inside(Rect frame, Rect area, double slack = 0.5) {
  return frame.x >= area.x - slack && frame.MaxX() <= area.MaxX() + slack &&
         frame.y >= area.y - slack && frame.MaxY() <= area.MaxY() + slack;
}

void TestSoftOvershoot() {
  // Small bounces look as they did; large ones never reach the inset.
  CHECK(Near(arx_pip::SoftOvershoot(0), 0));
  CHECK(Near(arx_pip::SoftOvershoot(-30), -30));
  CHECK(Near(arx_pip::SoftOvershoot(0.01), 0.01, 1e-4));
  CHECK(arx_pip::SoftOvershoot(1e9) <= kI);
  CHECK(arx_pip::SoftOvershoot(40) < kI && arx_pip::SoftOvershoot(40) > 14);
  // Monotonic.
  double last = 0;
  for (int step = 1; step <= 1000; ++step) {
    const double value = arx_pip::SoftOvershoot(step * 0.5);
    CHECK(value >= last);
    last = value;
  }
  // The inverse undoes it inside the band.
  for (const double excess : {0.5, 3.0, 10.0, 40.0}) {
    CHECK(Near(arx_pip::UnsqueezedOvershoot(arx_pip::SoftOvershoot(excess)),
               excess, 1e-6));
  }
}

void TestCarriedVelocityIsBounded() {
  // Toward the corner from 600 points out, any release velocity swings the
  // window at most the allowance past what a release at rest would.
  for (const double speed : {0.0, 500.0, 2000.0, 20000.0, 1e5, 1e6}) {
    const arx_pip::SpringState start{-600, speed};
    const double carried =
        arx_pip::CarriedVelocity(start, arx_pip::kThrowSpring, 1);
    CHECK(carried >= 0 && carried <= speed);
    const double rest =
        arx_pip::SpringExcess({-600, 0}, arx_pip::kThrowSpring, 1);
    const double excess =
        arx_pip::SpringExcess({-600, carried}, arx_pip::kThrowSpring, 1);
    CHECK(excess <= rest + arx_pip::kOvershootAllowance + 1e-6);
  }
  // A gentle throw keeps all of its velocity.
  CHECK(Near(arx_pip::CarriedVelocity({-600, 300}, arx_pip::kThrowSpring, 1),
             300));
  // Away from the edge, or with no edge, nothing changes.
  CHECK(Near(arx_pip::CarriedVelocity({-600, -9000}, arx_pip::kThrowSpring, 1),
             -9000));
  CHECK(Near(arx_pip::CarriedVelocity({-600, 9000}, arx_pip::kThrowSpring, 0),
             9000));
}

void TestOvershootBoundedForAnyVelocity() {
  // DEV-852: a release inside the screen, at any speed in any direction,
  // settles without a single frame leaving the visible frame, and ends at a
  // corner inside it.
  const std::vector<Rect> one = {{0, 0, 1440, 875}};
  const std::vector<Rect> starts = {{520, 325, 400, 225},
                                    {kI, kI, 400, 225},
                                    {1024, 634, 400, 225},
                                    {1, 1, 284, 160}};
  for (const Rect& start : starts) {
    for (const double speed : {0.0, 800.0, 5000.0, 20000.0, 1e5, 1e6}) {
      for (int direction = 0; direction < 16; ++direction) {
        const double angle = direction * M_PI / 8;
        const Point velocity{speed * std::cos(angle), speed * std::sin(angle)};
        for (const bool reduce : {false, true}) {
          const Trace trace = Run(one, start, velocity, reduce);
          CHECK(trace.finished);
          for (const Rect& frame : trace.frames) {
            CHECK(Inside(frame, one[0]));
          }
          CHECK(RestsAtCorner(trace.frames.back(), one[0]));
        }
      }
    }
  }
}

void TestFlingToEachEdge() {
  // The overnight smoke's case: 20,000 points a second toward each edge from
  // the middle ends at a corner of that edge, on screen all the way.
  const std::vector<Rect> one = {{0, 0, 1512, 945}};
  const Rect middle{556, 360, 400, 225};
  const Point flings[] = {{20000, 0}, {-20000, 0}, {0, 20000}, {0, -20000}};
  for (const Point fling : flings) {
    const Trace trace = Run(one, middle, fling);
    CHECK(trace.finished);
    for (const Rect& frame : trace.frames) {
      CHECK(Inside(frame, one[0]));
    }
    const Rect rest = trace.frames.back();
    CHECK(RestsAtCorner(rest, one[0]));
    if (fling.x > 0) CHECK(Near(rest.MaxX(), 1512 - kI, 0.5));
    if (fling.x < 0) CHECK(Near(rest.x, kI, 0.5));
    if (fling.y > 0) CHECK(Near(rest.MaxY(), 945 - kI, 0.5));
    if (fling.y < 0) CHECK(Near(rest.y, kI, 0.5));
  }
}

void TestStartingOffScreenComesBackSmoothly() {
  // Dragged half off the right edge and released: no jump on the first
  // frame, and nothing beyond where it started.
  const std::vector<Rect> one = {{0, 0, 1440, 875}};
  const Rect start{1300, 300, 400, 225};
  for (const double speed : {0.0, 3000.0, 20000.0}) {
    const Trace trace = Run(one, start, {speed, 0});
    CHECK(trace.finished);
    CHECK(std::abs(trace.frames.front().x - start.x) < 200);
    for (const Rect& frame : trace.frames) {
      CHECK(frame.MaxX() <= start.MaxX() + 0.5);
    }
    CHECK(RestsAtCorner(trace.frames.back(), one[0]));
  }
}

void TestBoundedProjection() {
  // Three screens side by side: the hardest throw from the first reaches the
  // second, never the third.
  const std::vector<Rect> row = {
      {0, 0, 1440, 875}, {1440, 0, 1920, 1055}, {3360, 0, 1920, 1055}};
  const Rect laptop{520, 325, 400, 225};
  for (const double speed : {20000.0, 1e5, 1e7}) {
    const auto target = arx_pip::Snap(row, laptop, {speed, 0}, {284, 160});
    CHECK(target.area_index == 1);
  }
  // A gentle throw stays home; a throw from near the shared edge crosses.
  CHECK(arx_pip::Snap(row, laptop, {600, 0}).area_index == 0);
  CHECK(arx_pip::Snap(row, {1030, 325, 400, 225}, {1500, 0}).area_index == 1);
  // Codex's case: a wide source, a narrow middle display and a third one.
  // The throw would project past the middle one; it stops there.
  const std::vector<Rect> uneven = {
      {0, 0, 3000, 1600}, {3000, 0, 1000, 800}, {4000, 0, 2000, 1100}};
  CHECK(arx_pip::Snap(uneven, {2500, 300, 400, 225}, {20000, 0}).area_index == 1);
  CHECK(arx_pip::Snap(uneven, {2500, 300, 400, 225}, {1e6, 0}).area_index == 1);
  // Thrown back from the third, the middle one takes it too.
  CHECK(arx_pip::Snap(uneven, {4100, 300, 400, 225}, {-20000, 0}).area_index == 1);
  // Clipping a segment.
  double enter = 0;
  double leave = 0;
  CHECK(arx_pip::ClipSegment({10, 0, 10, 10}, {0, 5}, {40, 5}, enter, leave));
  CHECK(Near(enter, 0.25) && Near(leave, 0.5));
  CHECK(!arx_pip::ClipSegment({10, 20, 10, 10}, {0, 5}, {40, 5}, enter, leave));
  // Projection with no screens is UIKit's.
  CHECK(Same(arx_pip::BoundedProject({}, {0, 0}, {1000, 0}), {499, 0}));
}

void TestMultipleDisplayLayouts() {
  // Side by side, stacked, and offset: a hard throw toward the other display
  // lands on it, at a corner inside its visible frame, and every frame stays
  // within that display and where the window started.
  struct Layout {
    std::vector<Rect> screens;
    Rect start;
    Point velocity;
    int display;
  };
  const std::vector<Layout> layouts = {
      // Side by side, the external one taller.
      {{{0, 0, 1440, 875}, {1440, 0, 2560, 1415}},
       {1000, 300, 400, 225}, {20000, 0}, 1},
      // Side by side, the external one on the left and lower.
      {{{0, 0, 1440, 875}, {-1920, -300, 1920, 1055}},
       {40, 300, 400, 225}, {-20000, 0}, 1},
      // Stacked: the external display above the laptop, offset to the right.
      {{{0, 0, 1440, 875}, {300, 900, 1920, 1055}},
       {520, 600, 400, 225}, {0, 20000}, 1},
      // Stacked: the laptop above, offset left, with a menu bar gap.
      {{{0, 0, 2560, 1415}, {-400, -900, 1440, 875}},
       {300, 40, 400, 225}, {-3000, -20000}, 1},
  };
  for (const Layout& layout : layouts) {
    const Trace trace = Run(layout.screens, layout.start, layout.velocity);
    CHECK(trace.target.area_index == layout.display);
    CHECK(trace.finished);
    const Rect area = layout.screens[static_cast<size_t>(layout.display)];
    const Rect last = trace.frames.back();
    CHECK(RestsAtCorner(last, area));
    // The box around the target display and the start.
    const double x = std::min(area.x, layout.start.x);
    const double y = std::min(area.y, layout.start.y);
    const Rect box{x, y,
                   std::max(area.MaxX(), layout.start.MaxX()) - x,
                   std::max(area.MaxY(), layout.start.MaxY()) - y};
    for (const Rect& frame : trace.frames) {
      CHECK(Inside(frame, box));
    }
  }
}

void TestResnap() {
  const std::vector<Rect> two = {{0, 0, 1440, 875}, {1440, 0, 2560, 1415}};
  const Rect resting{1440 + 2560 - kI - 400, 1415 - kI - 225, 400, 225};
  // The display is still there: same display, same corner.
  const auto kept = arx_pip::Resnap(two, resting, 1, 3, {284, 160});
  CHECK(kept.area_index == 1 && kept.corner == 3);
  CHECK(Same(kept.origin, {resting.x, resting.y}));
  // The display changed resolution: same corner of its new visible frame.
  const std::vector<Rect> smaller = {{0, 0, 1440, 875}, {1440, 0, 1920, 1055}};
  const auto moved = arx_pip::Resnap(smaller, resting, 1, 3, {284, 160});
  CHECK(Same(moved.origin, {1440 + 1920 - kI - 400, 1055 - kI - 225}));
  // Unplugged: the nearest display, the corner nearest the window.
  const std::vector<Rect> laptop = {{0, 0, 1440, 875}};
  const auto fallback = arx_pip::Resnap(laptop, resting, -1, 3, {284, 160});
  CHECK(fallback.area_index == 0);
  CHECK(Same(fallback.origin, {1440 - kI - 400, 875 - kI - 225}));
  // An index past the end counts as gone.
  CHECK(arx_pip::Resnap(laptop, resting, 1, 0, {284, 160}).area_index == 0);
  // A big window shrinks to the new display's cap.
  const auto shrunk = arx_pip::Resnap(laptop, {0, 0, 1600, 900}, 0, 0, {284, 160});
  CHECK(shrunk.size.width <= 1152 && shrunk.size.height <= 700);
  // A settle onto it, without velocity, ends inside.
  arx_pip::Settler settler(moved, arx_pip::kThrowSpring, resting, {}, 0);
  Rect window = resting;
  for (int frame = 1; frame <= 600; ++frame) {
    const auto step = settler.Next(window, frame / 120.0);
    window = step.frame;
    CHECK(Inside(window, {0, 0, 4000, 1415}));
    if (step.action != arx_pip::Settler::Action::kApply) break;
    settler.Applied(step.frame, window, frame / 120.0);
  }
  CHECK(RestsAtCorner(window, smaller[1]));
}

void TestKeptOnScreen() {
  const std::vector<Rect> two = {{0, 0, 1440, 875}, {1440, 0, 2560, 1415}};
  const double m = arx_pip::kMinimumVisible;
  // On a screen: unchanged.
  const Rect on{100, 100, 400, 225};
  CHECK(Same({arx_pip::KeptOnScreen(two, on).x, arx_pip::KeptOnScreen(two, on).y},
             {100, 100}));
  // Partly over an edge, still showing enough: unchanged.
  const Rect over{-300, 100, 400, 225};
  CHECK(Near(arx_pip::KeptOnScreen(two, over).x, -300));
  // Pushed off the left edge: held with the minimum showing.
  const Rect gone = arx_pip::KeptOnScreen(two, {-2000, 100, 400, 225});
  CHECK(Near(gone.MaxX(), m) && Near(gone.y, 100));
  // Off the bottom of both: the nearest screen holds it.
  const Rect below = arx_pip::KeptOnScreen(two, {2000, -5000, 400, 225});
  CHECK(Near(below.MaxY(), m) && Near(below.x, 2000));
  // In the gap above the laptop, beside the taller screen: onto the laptop's
  // top edge or the external screen's side, whichever is nearer.
  const Rect gap = arx_pip::KeptOnScreen(two, {1100, 1200, 400, 225});
  CHECK(Near(gap.x, 1100) || Near(gap.y, 1200));
  // No screens: unchanged.
  CHECK(Near(arx_pip::KeptOnScreen({}, {-9000, 0, 10, 10}).x, -9000));
}

}  // namespace

int main() {
  TestProjection();
  TestVelocity();
  TestSnapOrigins();
  TestSnapping();
  TestMultipleScreens();
  TestScaling();
  TestConstraining();
  TestSpring();
  TestReduceMotion();
  TestDestinationSize();
  TestInterpolatedSize();
  TestThrowOntoSmallerScreen();
  TestSettleOntoSmallerScreen();
  TestSettleOnSameScreen();
  TestSettleStopsWhenMovedElsewhere();
  TestSettleEndsDespiteEndlessResizes();
  TestThrowSpringBouncesAndReduceMotionDoesNot();
  TestSoftOvershoot();
  TestCarriedVelocityIsBounded();
  TestOvershootBoundedForAnyVelocity();
  TestFlingToEachEdge();
  TestStartingOffScreenComesBackSmoothly();
  TestBoundedProjection();
  TestMultipleDisplayLayouts();
  TestResnap();
  TestKeptOnScreen();
  CHECK(Near(arx_pip::kCornerRadius, 16));
  CHECK(Near(arx_pip::kEdgeInset, 16));
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
