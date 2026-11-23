#ifndef ARX_INSPECTION_POLICY_H_
#define ARX_INSPECTION_POLICY_H_

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace arx::inspection {
inline constexpr size_t kMaximumSnapshots = 16;
inline constexpr size_t kMaximumPageSnapshots = 4;
inline constexpr size_t kMaximumRequests = 16;
inline constexpr size_t kMaximumReferences = 256;
inline constexpr size_t kMaximumHandles = 4096;
inline constexpr size_t kMaximumNodes = 512;
// ABI25 windows project at most this many nodes per document; each window
// still emits at most kMaximumNodes.
inline constexpr size_t kMaximumTreeNodes = 16384;
inline constexpr size_t kMaximumTextBytes = 65536;
inline constexpr size_t kMaximumOutputBytes = 262144;
inline constexpr size_t kMaximumStringBytes = 4096;
inline constexpr uint32_t kMaximumTimeout = 2000;
inline constexpr int kReferenceSeconds = 30;

template <typename Limits>
bool ValidLimits(const Limits& limits) {
  return limits.nodes > 0 && limits.nodes <= kMaximumNodes &&
      limits.text_bytes > 0 && limits.text_bytes <= kMaximumTextBytes &&
      limits.references > 0 && limits.references <= kMaximumReferences &&
      limits.output_bytes >= 1024 && limits.output_bytes <= kMaximumOutputBytes &&
      limits.timeout_ms > 0 && limits.timeout_ms <= kMaximumTimeout &&
      limits.window_start < kMaximumTreeNodes;
}

// Values that autofill classifies as payment or one-time secrets stay omitted
// even when form values are requested.
inline bool SensitiveAutocomplete(std::string_view value) {
  for (std::string_view token : {"cc-number", "cc-csc", "cc-exp", "cc-exp-month", "cc-exp-year",
                                 "one-time-code", "new-password", "current-password"}) {
    if (value.find(token) != std::string_view::npos) return true;
  }
  return false;
}

// Both trusted scope UUIDs and native random tokens have bounded ASCII spelling.
inline bool ValidToken(std::string_view token) {
  if (token.size() != 32 && token.size() != 36) return false;
  for (char character : token) {
    if (!((character >= '0' && character <= '9') ||
          (character >= 'a' && character <= 'f') ||
          (character >= 'A' && character <= 'F') || character == '-')) return false;
  }
  return true;
}

// Fail closed instead of truncating a string or returning a misleading tree.
class Budget final {
 public:
  explicit Budget(size_t limit) : remaining_(limit) {}
  bool Consume(size_t count) {
    if (count > remaining_) return false;
    remaining_ -= count;
    return true;
  }
 private:
  size_t remaining_;
};

// The retained handle defeats DOM-ID reuse. Both version reads happen in the
// same renderer task; validation is deliberately not a permit for later work.
template <typename Node, typename Document, typename Resolve, typename Safe, typename Version>
bool ReferenceMatches(const Node& retained, int id,
                      std::string_view expected_document, uint64_t expected_version,
                      const Document& document, Resolve resolve, Safe safe, Version version) {
  return document && document.IsActive() &&
      document.Token().ToString() == expected_document &&
      version(document) == expected_version &&
      retained.IsConnected() && retained.GetDocument() == document &&
      resolve(id) == retained && safe(retained) &&
      version(document) == expected_version;
}
}  // namespace arx::inspection
#endif
