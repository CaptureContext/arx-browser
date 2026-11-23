#include <cassert>
#include <string>

#include "pointer_policy.h"

using namespace arx::inspection;

int main() {
  PointerPayload value;
  // DEV-669: only hover keeps its snapshot.
  assert(!ConsumesSnapshot(kHoverKind));
  assert(ConsumesSnapshot(kPointerClickKind) && ConsumesSnapshot(kDragKind));
  assert(ConsumesSnapshot(0) && ConsumesSnapshot(1) && ConsumesSnapshot(3) && ConsumesSnapshot(4));
  assert(IsPointerKind(8) && IsPointerKind(16) && IsPointerKind(32) && !IsPointerKind(4));

  // Hover: empty (reference centre) or one point; no modifiers or repeats.
  assert(ParsePointerPayload(kHoverKind, "", &value) && !value.has_point);
  assert(ParsePointerPayload(kHoverKind, "x=12.5;y=40;", &value) && value.has_point &&
         value.x == 12.5 && value.y == 40);
  assert(!ParsePointerPayload(kHoverKind, "x=12.5;", &value));
  assert(!ParsePointerPayload(kHoverKind, "modifiers=1;", &value));
  assert(!ParsePointerPayload(kHoverKind, "clicks=1;", &value));
  assert(!ParsePointerPayload(kHoverKind, "steps=2;", &value));

  // Click: counts 1-3 and only shift/alt/meta; Control (2) would open a context menu.
  assert(ParsePointerPayload(kPointerClickKind, "clicks=2;modifiers=9;", &value) &&
         value.clicks == 2 && value.modifiers == 9);
  assert(!ParsePointerPayload(kPointerClickKind, "clicks=4;", &value));
  assert(!ParsePointerPayload(kPointerClickKind, "clicks=0;", &value));
  assert(!ParsePointerPayload(kPointerClickKind, "clicks=02;", &value));
  assert(!ParsePointerPayload(kPointerClickKind, "modifiers=2;", &value));
  assert(!ParsePointerPayload(kPointerClickKind, "modifiers=3;", &value));

  // Drag: exactly one destination, steps 1-32.
  const std::string token = "0123456789abcdef0123456789ABCDEF";
  assert(ParsePointerPayload(kDragKind, "to=" + token + ";modifiers=0;steps=8;", &value) &&
         value.destination == token && value.steps == 8);
  assert(ParsePointerPayload(kDragKind, "x=1;y=2;tx=3;ty=4;steps=1;", &value) &&
         value.has_point && value.has_destination_point && value.destination_x == 3);
  assert(!ParsePointerPayload(kDragKind, "steps=8;", &value));
  assert(!ParsePointerPayload(kDragKind, "tx=3;ty=4;to=" + token + ";", &value));
  assert(!ParsePointerPayload(kDragKind, "to=" + token + ";steps=33;", &value));
  assert(!ParsePointerPayload(kDragKind, "to=short;", &value));
  assert(!ParsePointerPayload(kPointerClickKind, "to=" + token + ";", &value));

  // Fixed order, no repeats, no stray bytes, finite in-range numbers.
  assert(!ParsePointerPayload(kHoverKind, "y=1;x=2;", &value));
  assert(!ParsePointerPayload(kHoverKind, "x=1;x=1;y=1;", &value));
  assert(!ParsePointerPayload(kHoverKind, "x=1;y=1", &value));
  assert(!ParsePointerPayload(kHoverKind, "x=-1;y=1;", &value));
  assert(!ParsePointerPayload(kHoverKind, "x=nan;y=1;", &value));
  assert(!ParsePointerPayload(kHoverKind, "x=1e9;y=1;", &value));
  assert(!ParsePointerPayload(kHoverKind, "x=1 ;y=1;", &value));
  assert(!ParsePointerPayload(kHoverKind, "z=1;", &value));
  assert(ParsePointerPayload(kHoverKind, "x=1e-05;y=100000;", &value));
  assert(!ParsePointerPayload(4, "", &value));
  assert(!ParsePointerPayload(kHoverKind, std::string(513, 'x'), &value));
  return 0;
}
