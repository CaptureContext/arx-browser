#ifndef THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_KEYBOARD_ACTIONS_H_
#define THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_KEYBOARD_ACTIONS_H_

#include <cstdint>

#include "third_party/blink/public/platform/web_common.h"
#include "third_party/blink/public/platform/web_string.h"

namespace blink {
class WebDocument;
class WebElement;

enum ArxKeyModifier : uint32_t {
  kArxKeyShift = 1u << 0,
  kArxKeyControl = 1u << 1,
  kArxKeyAlt = 1u << 2,
  kArxKeyMeta = 1u << 3,
};

enum class ArxKeyboardResult {
  kDispatched,
  kPossiblyDispatched,
  kStale,
  kNotInteractable,
  kUnsupported,
  kInvalidKey,
  kBusy,
};

// Focuses an input, textarea or contenteditable reference, puts the caret at
// the end and types each character as a guarded key sequence. Editing stops
// as soon as focus or the selection leaves the reference or reaches password
// ancestry, including when author listeners redirect it.
BLINK_EXPORT ArxKeyboardResult TypeTextForArxInspection(
    const WebElement& target, const WebDocument& expected_document,
    uint64_t expected_version, int32_t expected_node, const WebString& text,
    bool (*is_current)(void*), void* context);

// Focuses the reference and dispatches one key with modifiers. Text editing
// keys on an editable reference are guarded like typing; navigation keys keep
// their defaults; chords with Control, Alt or Meta reach page listeners only,
// with every default (clipboard, undo, editing) suppressed.
BLINK_EXPORT ArxKeyboardResult PressKeyForArxInspection(
    const WebElement& target, const WebDocument& expected_document,
    uint64_t expected_version, int32_t expected_node, const WebString& key,
    uint32_t modifiers, bool (*is_current)(void*), void* context);
}  // namespace blink
#endif
