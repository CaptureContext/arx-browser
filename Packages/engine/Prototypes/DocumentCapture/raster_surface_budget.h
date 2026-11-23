#ifndef ARX_DOCUMENT_CAPTURE_RASTER_SURFACE_BUDGET_H_
#define ARX_DOCUMENT_CAPTURE_RASTER_SURFACE_BUDGET_H_

#include <cstdint>

namespace arx::document {

// Capture-owned N32 base + live layer pixel storage only. This is not a
// process-RSS bound. A layer's actual device allocation, not its bounds hint,
// must pass this policy before any pixel allocation is attempted.
class RasterSurfaceBudget {
 public:
  static constexpr uint64_t kMaximumPixels = 16 * 1024 * 1024;
  static constexpr uint64_t kMaximumLayerBytes = 64 * 1024 * 1024;
  static constexpr uint32_t kMaximumLayers = 8;

  RasterSurfaceBudget(int width, int height, uint64_t layer_bytes = kMaximumLayerBytes)
      : width_(width), height_(height), layer_bytes_(layer_bytes) {}

  bool Acquire(int width, int height, uint64_t* bytes) {
    if (failed_ || layer_bytes_ > kMaximumLayerBytes || width <= 0 || height <= 0 || width > 8192 || height > 8192 ||
        width > width_ || height > height_ ||
        static_cast<uint64_t>(width) * height > kMaximumPixels) return Fail();
    const uint64_t size = static_cast<uint64_t>(width) * height * 4;
    if (!base_admitted_) {
      if (width != width_ || height != height_) return Fail();
      base_bytes_ = size;
      base_admitted_ = true;
    } else if (live_allocations_ >= kMaximumLayers + 1 ||
               size > layer_bytes_ ||
               live_bytes_ > base_bytes_ + layer_bytes_ - size) {
      return Fail();
    }
    live_bytes_ += size;
    ++live_allocations_;
    if (live_bytes_ > peak_bytes_) peak_bytes_ = live_bytes_;
    *bytes = size;
    return true;
  }

  bool Release(uint64_t bytes) {
    if (!live_allocations_ || bytes > live_bytes_) return Fail();
    live_bytes_ -= bytes;
    --live_allocations_;
    return true;
  }
  bool failed() const { return failed_; }
  uint64_t live_bytes() const { return live_bytes_; }
  uint64_t peak_bytes() const { return peak_bytes_; }
  uint32_t live_allocations() const { return live_allocations_; }

 private:
  bool Fail() { failed_ = true; return false; }
  const int width_;
  const int height_;
  const uint64_t layer_bytes_;
  uint64_t base_bytes_ = 0;
  uint64_t live_bytes_ = 0;
  uint64_t peak_bytes_ = 0;
  uint32_t live_allocations_ = 0;
  bool base_admitted_ = false;
  bool failed_ = false;
};

}  // namespace arx::document
#endif
