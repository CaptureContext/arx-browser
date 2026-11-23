#ifndef ARX_INSPECTION_KEYBOARD_POLICY_H_
#define ARX_INSPECTION_KEYBOARD_POLICY_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace arx::inspection {
// ABI28 keyboard kinds, equal to the FormActionKind values. Both consume
// their snapshot.
inline constexpr uint32_t kTypeKind = 64;
inline constexpr uint32_t kKeyChordKind = 128;
inline constexpr size_t kMaximumTypedBytes = 1024;
inline constexpr size_t kMaximumKeyChordBytes = 40;

// ABI29 form state kinds. Select-values payload is a JSON array of strings;
// set-checked payload is "1" or "0". Both consume their snapshot.
inline constexpr uint32_t kSelectValuesKind = 256;
inline constexpr uint32_t kSetCheckedKind = 512;
inline constexpr size_t kMaximumSelectValuesBytes = 4096;

inline constexpr bool IsFormStateKind(uint32_t kind) {
  return kind == kSelectValuesKind || kind == kSetCheckedKind;
}

inline constexpr bool IsKeyboardKind(uint32_t kind) {
  return kind == kTypeKind || kind == kKeyChordKind;
}

// "<modifiers>:<key>", modifiers 0-15 in decimal without leading zeros (bits
// 1 shift, 2 control, 4 alt, 8 meta); key is one non-empty name or character
// that the renderer checks against its key table.
inline bool ParseKeyChord(std::string_view text, uint32_t* modifiers, std::string* key) {
  if (text.size() > kMaximumKeyChordBytes || !modifiers || !key) return false;
  const size_t colon = text.find(':');
  if (colon == std::string_view::npos || colon == 0 || colon > 2 || colon + 1 >= text.size())
    return false;
  uint32_t value = 0;
  for (size_t i = 0; i < colon; ++i) {
    if (text[i] < '0' || text[i] > '9') return false;
    value = value * 10 + static_cast<uint32_t>(text[i] - '0');
  }
  if (value > 15 || (colon == 2 && text[0] == '0')) return false;
  *modifiers = value;
  *key = std::string(text.substr(colon + 1));
  return true;
}
}  // namespace arx::inspection
#endif
