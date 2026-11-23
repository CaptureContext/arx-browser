#ifndef THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_FORM_STATE_ACTIONS_H_
#define THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_FORM_STATE_ACTIONS_H_

#include <cstdint>
#include <vector>

#include "third_party/blink/public/platform/web_common.h"
#include "third_party/blink/public/platform/web_string.h"

namespace blink {
class WebDocument;
class WebElement;

enum class ArxFormStateResult {
  kDispatched,
  kUnchanged,
  kStale,
  kNotInteractable,
  kUnsupported,
  kInvalidValue,
  kOptionNotFound,
  kAmbiguousOption,
};

// Sets a checkbox or radio to an explicit state with input and change events,
// like a user toggling it. A radio can't be unchecked. An already equal state
// is kUnchanged and fires nothing.
BLINK_EXPORT ArxFormStateResult SetCheckedForArxInspection(
    const WebElement& target, const WebDocument& expected_document,
    uint64_t expected_version, int32_t expected_node, bool checked,
    bool (*is_current)(void*), void* context);

// Makes the selection of a native multiple select exactly the options with
// these values: each value must match one enabled option exactly. An already
// equal selection is kUnchanged and fires nothing.
BLINK_EXPORT ArxFormStateResult SelectValuesForArxInspection(
    const WebElement& target, const WebDocument& expected_document,
    uint64_t expected_version, int32_t expected_node,
    const std::vector<WebString>& values, bool (*is_current)(void*), void* context);
}  // namespace blink
#endif
