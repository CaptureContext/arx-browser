#ifndef ARX_DOCUMENT_PROTOTYPE_BUDGET_H_
#define ARX_DOCUMENT_PROTOTYPE_BUDGET_H_

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <span>

namespace arx::document {

// Shared with the renderer and exercised without a Chromium build. These caps
// bound owned output, not Blink's earlier construction of its paint record.
inline constexpr uint64_t kMaximumPixels = 16 * 1024 * 1024;
inline constexpr uint64_t kMaximumRecordBytes = 16 * 1024 * 1024;
inline constexpr uint64_t kMaximumRecordOps = 100000;
inline constexpr uint64_t kMaximumDecodedImageBytes = 32 * 1024 * 1024;
inline constexpr uint64_t kMaximumSerializedBytes = 32 * 1024 * 1024;
inline constexpr uint64_t kMaximumPNGBytes = 64 * 1024 * 1024;

template <typename Limits>
bool ValidLimits(const Limits& limits) {
  return limits.maximum_dimension > 0 && limits.maximum_dimension <= 8192 &&
         limits.maximum_pixels > 0 && limits.maximum_pixels <= kMaximumPixels &&
         limits.maximum_record_bytes > 0 &&
         limits.maximum_record_bytes <= kMaximumRecordBytes &&
         limits.maximum_record_ops > 0 && limits.maximum_record_ops <= kMaximumRecordOps &&
         limits.maximum_decoded_image_bytes > 0 &&
         limits.maximum_decoded_image_bytes <= kMaximumDecodedImageBytes &&
         limits.maximum_serialized_bytes > 0 &&
         limits.maximum_serialized_bytes <= kMaximumSerializedBytes &&
         limits.maximum_png_bytes > 0 && limits.maximum_png_bytes <= kMaximumPNGBytes &&
         limits.timeout_ms > 0 && limits.timeout_ms <= 10000;
}

template <typename Limits>
bool FitsRaster(int width, int height, const Limits& limits) {
  return width > 0 && height > 0 &&
         static_cast<uint32_t>(width) <= limits.maximum_dimension &&
         static_cast<uint32_t>(height) <= limits.maximum_dimension &&
         static_cast<uint64_t>(width) * static_cast<uint64_t>(height) <=
             limits.maximum_pixels;
}

template <typename Limits>
bool FitsExtent(int x, int y, int width, int height, const Limits& limits) {
  const int64_t cap = limits.maximum_dimension;
  return FitsRaster(width, height, limits) && x >= -cap && y >= -cap &&
         static_cast<int64_t>(x) + width <= cap &&
         static_cast<int64_t>(y) + height <= cap;
}

class Budget {
 public:
  explicit Budget(uint64_t limit) : remaining_(limit) {}

  bool Consume(uint64_t count) {
    if (failed_ || count > remaining_) {
      failed_ = true;
      return false;
    }
    remaining_ -= count;
    return true;
  }

  bool failed() const { return failed_; }

 private:
  uint64_t remaining_;
  bool failed_ = false;
};

class BoundedBytes {
 public:
  explicit BoundedBytes(size_t limit)
      : budget_(limit), bytes_(std::make_unique<uint8_t[]>(limit)) {}

  bool Append(const void* data, size_t size) {
    if (!budget_.Consume(size)) return false;
    if (size) std::memcpy(bytes_.get() + size_, data, size);
    size_ += size;
    return true;
  }

  bool failed() const { return budget_.failed(); }
  std::span<const uint8_t> bytes() const { return {bytes_.get(), size_}; }

 private:
  Budget budget_;
  std::unique_ptr<uint8_t[]> bytes_;
  size_t size_ = 0;
};

}  // namespace arx::document

#endif
