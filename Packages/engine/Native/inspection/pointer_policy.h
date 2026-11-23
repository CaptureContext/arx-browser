#ifndef ARX_INSPECTION_POINTER_POLICY_H_
#define ARX_INSPECTION_POINTER_POLICY_H_

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <string_view>

namespace arx::inspection {
// ABI27 pointer kinds, equal to the FormActionKind values.
inline constexpr uint32_t kHoverKind = 8;
inline constexpr uint32_t kPointerClickKind = 16;
inline constexpr uint32_t kDragKind = 32;
inline constexpr size_t kMaximumPointerPayload = 512;
inline constexpr double kMaximumPointerCoordinate = 100000;

inline constexpr bool IsPointerKind(uint32_t kind) {
  return kind == kHoverKind || kind == kPointerClickKind || kind == kDragKind;
}

// DEV-669: hover is the only non-consuming action. A clean hover keeps its
// snapshot; the renderer still checks the DOM version before every action, so
// a mutation (including one the hover caused) retires its references.
inline constexpr bool ConsumesSnapshot(uint32_t kind) { return kind != kHoverKind; }

struct PointerPayload {
  bool has_point = false;
  double x = 0, y = 0;
  bool has_destination_point = false;
  double destination_x = 0, destination_y = 0;
  std::string destination;  // A reference of the same snapshot, drag only.
  uint32_t clicks = 1, modifiers = 0, steps = 1;
};

namespace pointer_detail {
inline bool Number(std::string_view text, double* output) {
  if (text.empty() || text.size() > 32) return false;
  for (const char character : text) {
    if (!((character >= '0' && character <= '9') || character == '.' || character == '-' ||
          character == 'e' || character == 'E' || character == '+')) return false;
  }
  const std::string owned(text);
  char* end = nullptr;
  const double value = std::strtod(owned.c_str(), &end);
  if (end != owned.c_str() + owned.size() || !std::isfinite(value) ||
      value < 0 || value > kMaximumPointerCoordinate) return false;
  *output = value;
  return true;
}
inline bool Integer(std::string_view text, uint32_t minimum, uint32_t maximum, uint32_t* output) {
  if (text.empty() || text.size() > 3) return false;
  uint32_t value = 0;
  for (const char character : text) {
    if (character < '0' || character > '9') return false;
    value = value * 10 + static_cast<uint32_t>(character - '0');
  }
  if (value < minimum || value > maximum || (text.size() > 1 && text[0] == '0')) return false;
  *output = value;
  return true;
}
inline bool Token(std::string_view text) {
  if (text.size() != 32) return false;
  for (const char character : text) {
    if (!((character >= '0' && character <= '9') || (character >= 'A' && character <= 'F') ||
          (character >= 'a' && character <= 'f'))) return false;
  }
  return true;
}
}  // namespace pointer_detail

// Canonical ASCII "key=value;" fields in this fixed order, each at most once:
// x, y, tx, ty, to, clicks, modifiers, steps. x/y come together; so do tx/ty.
// Modifiers are bits 1 shift, 4 alt, 8 meta; Control would open a context menu.
inline bool ParsePointerPayload(uint32_t kind, std::string_view text, PointerPayload* output) {
  using namespace pointer_detail;
  if (!IsPointerKind(kind) || text.size() > kMaximumPointerPayload || !output) return false;
  static constexpr std::string_view kOrder[] = {"x", "y", "tx", "ty", "to", "clicks", "modifiers", "steps"};
  PointerPayload value;
  size_t next = 0;
  bool seen[8] = {};
  while (!text.empty()) {
    const size_t end = text.find(';');
    if (end == std::string_view::npos) return false;
    const auto field = text.substr(0, end);
    text.remove_prefix(end + 1);
    const size_t equals = field.find('=');
    if (equals == std::string_view::npos) return false;
    const auto key = field.substr(0, equals), data = field.substr(equals + 1);
    size_t index = next;
    while (index < 8 && kOrder[index] != key) ++index;
    if (index == 8) return false;
    next = index + 1;
    seen[index] = true;
    bool valid = false;
    switch (index) {
      case 0: valid = Number(data, &value.x); break;
      case 1: valid = Number(data, &value.y); break;
      case 2: valid = Number(data, &value.destination_x); break;
      case 3: valid = Number(data, &value.destination_y); break;
      case 4: valid = Token(data); value.destination = std::string(data); break;
      case 5: valid = Integer(data, 1, 3, &value.clicks); break;
      case 6: valid = Integer(data, 0, 13, &value.modifiers) && !(value.modifiers & ~13u); break;
      case 7: valid = Integer(data, 1, 32, &value.steps); break;
    }
    if (!valid) return false;
  }
  if (seen[0] != seen[1] || seen[2] != seen[3]) return false;
  value.has_point = seen[0];
  value.has_destination_point = seen[2];
  const bool drag = kind == kDragKind;
  // Only a drag has a destination, and exactly one; only a click repeats.
  if (drag != (seen[2] || seen[4]) || (seen[2] && seen[4])) return false;
  if (seen[5] && kind != kPointerClickKind) return false;
  if (seen[7] && !drag) return false;
  if (kind == kHoverKind && seen[6]) return false;
  *output = value;
  return true;
}
}  // namespace arx::inspection
#endif
