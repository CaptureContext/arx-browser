#ifndef THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_FORM_ACTIONS_H_
#define THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_FORM_ACTIONS_H_

#include <array>
#include <cstdint>
#include "third_party/blink/public/platform/web_common.h"

namespace blink {
class WebDocument;
class WebElement;
class WebString;

enum class ArxFormBaselineStatus { kAvailable, kUnsupported, kLimit, kInvalid };
enum class ArxFormActionKind { kReplaceText = 1, kSelectValue = 2 };
enum class ArxFormActionResult {
  kDispatched, kUnchanged, kStale, kNotInteractable, kUnsupported,
  kInvalidValue, kOptionNotFound, kAmbiguousOption, kLimit, kInvalid,
};
// Retained only in the renderer. No values or hashes cross the inspection IPC.
// The digest covers a length-prefixed, domain-separated bounded control state.
struct ArxFormBaseline {
  std::array<uint8_t, 32> digest{};
  uint32_t kind = 0;
  uint32_t value_length = 0;
  uint32_t selection_start = 0;
  uint32_t selection_end = 0;
  int32_t maximum_length = -1;
  bool readonly = false;
  bool disabled = false;
  bool operator==(const ArxFormBaseline&) const = default;
};
BLINK_EXPORT ArxFormBaselineStatus CaptureFormBaselineForArxInspection(
    const WebElement&, ArxFormBaseline*);
BLINK_EXPORT ArxFormActionResult PerformFormActionForArxInspection(
    const WebElement&, const WebDocument&, uint64_t expected_version,
    int32_t expected_node, const ArxFormBaseline&, ArxFormActionKind,
    const WebString& payload, bool (*is_current)(void*), void* context);
}  // namespace blink
#endif
