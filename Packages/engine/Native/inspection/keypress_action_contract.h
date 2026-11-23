#ifndef THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_KEYPRESS_ACTIONS_H_
#define THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_KEYPRESS_ACTIONS_H_

#include <cstdint>
#include "third_party/blink/public/web/arx_form_actions.h"

namespace blink {
// Renderer-only baseline; no value, selection positions or hashes cross IPC.
struct ArxKeypressBaseline {
  ArxFormBaseline control;
  int32_t anchor_node = 0, focus_node = 0;
  uint32_t anchor_type = 0, focus_type = 0;
  uint32_t anchor_offset = 0, focus_offset = 0;
  uint32_t affinity = 0;
  bool directional = false;
  bool operator==(const ArxKeypressBaseline&) const = default;
};
enum class ArxKeypressResult { kDispatched, kPossiblyDispatched, kStale,
  kNotInteractable, kUnsupported, kInvalidKey, kBusy };
BLINK_EXPORT ArxFormBaselineStatus CaptureKeypressBaselineForArxInspection(
    const WebElement&, ArxKeypressBaseline*);
BLINK_EXPORT ArxKeypressResult PerformKeypressForArxInspection(
    const WebElement&, const WebDocument&, uint64_t expected_version,
    int32_t expected_node, const ArxKeypressBaseline&, const WebString& key,
    bool (*is_current)(void*), void* context);
}  // namespace blink
#endif
