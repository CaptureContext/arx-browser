#ifndef THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_POINTER_ACTIONS_H_
#define THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_POINTER_ACTIONS_H_

#include <cstdint>

#include "third_party/blink/public/platform/web_common.h"
#include "ui/gfx/geometry/point_f.h"

namespace blink {
class WebDocument;
class WebElement;

enum class ArxPointerKind : uint32_t { kHover = 1, kClick = 2, kDrag = 3 };
enum ArxPointerModifier : uint32_t {
  kArxPointerShift = 1u << 0,
  kArxPointerAlt = 1u << 2,
  kArxPointerMeta = 1u << 3,
};

// Points are viewport points (DIPs) of the main frame's widget, the space of
// inspection bounds and screenshots. Without a point the element's visible
// centre is used.
struct ArxPointerRequest {
  ArxPointerKind kind = ArxPointerKind::kHover;
  bool has_point = false;
  gfx::PointF point;
  bool has_destination_point = false;
  gfx::PointF destination_point;
  uint32_t click_count = 1;  // 1...3, click only.
  uint32_t modifiers = 0;    // ArxPointerModifier bits.
  uint32_t steps = 1;        // 1...32 intermediate moves, drag only.
};

enum class ArxPointerResult {
  kDispatched,
  kPossiblyDispatched,
  kStale,
  kNotInteractable,
  kObscured,
  kUnsupported,
  kBusy,
  kInvalid,
};

// Real mouse input through the frame's own widget, in the same task as the
// authority check. The target (or the point, when target is null) must be hit
// by Blink's own hit test. HTML drag and drop completes inside the renderer;
// no platform drag session is started. The callback validates retained
// authority only and must not run script.
BLINK_EXPORT ArxPointerResult PerformPointerForArxInspection(
    const WebDocument& expected_document, uint64_t expected_version,
    const WebElement& target, int32_t target_node,
    const WebElement& destination, int32_t destination_node,
    const ArxPointerRequest& request, bool (*is_current)(void*), void* context);
}  // namespace blink
#endif
