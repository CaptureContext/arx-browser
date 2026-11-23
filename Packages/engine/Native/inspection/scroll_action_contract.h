#ifndef THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_SCROLL_ACTIONS_H_
#define THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_SCROLL_ACTIONS_H_
#include <cstdint>
#include "third_party/blink/public/platform/web_common.h"
namespace blink {
class WebDocument;
class WebElement;
enum class ArxScrollAxis { kHorizontal = 0, kVertical = 1 };
enum class ArxScrollResult {
  kDispatched, kUnchanged, kStale, kNotInteractable, kNoContainer, kInvalidDelta, kLimit,
};
// Resolves one current containing scroll box; never chains to another box.
// The authority callback is read-only and cannot run script or flush layout.
BLINK_EXPORT ArxScrollResult ScrollReferenceForArxInspection(
    const WebElement&, const WebDocument&, uint64_t expected_version,
    int32_t expected_node, ArxScrollAxis axis, double delta_css_pixels,
    bool (*is_current)(void*), void* context);
}  // namespace blink
#endif
