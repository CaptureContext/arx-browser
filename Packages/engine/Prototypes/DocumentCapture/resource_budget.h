#ifndef ARX_DOCUMENT_PROTOTYPE_RESOURCE_BUDGET_H_
#define ARX_DOCUMENT_PROTOTYPE_RESOURCE_BUDGET_H_

#include <cstdint>
#include <limits>

#include "budget.h"

namespace arx::document {

// Metadata-only accounting before SkPicture playback/image readback. References
// are charged per use rather than deduplicated in an unbounded resource map.
class ResourceBudget {
 public:
  ResourceBudget(uint64_t operations, uint64_t referenced_bytes, uint64_t images)
      : operations_(operations), referenced_bytes_(referenced_bytes),
        glyphs_(operations), images_(images) {}

  bool Operation() { return operations_.Consume(1); }
  bool ReferencedBytes(uint64_t size) { return referenced_bytes_.Consume(size); }
  bool Glyphs(uint64_t count) { return glyphs_.Consume(count); }

  bool Image(int width, int height, uint64_t bytes_per_pixel) {
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192 ||
        bytes_per_pixel == 0 || bytes_per_pixel > 16) return false;
    const uint64_t pixels = static_cast<uint64_t>(width) * height;
    // The utility decoder normalizes serialized images to N32 even if a
    // resident source uses a smaller pixel format.
    const uint64_t retained_bpp = bytes_per_pixel < 4 ? 4 : bytes_per_pixel;
    return images_.Consume(pixels * retained_bpp);
  }

  bool EnterRecord() {
    if (depth_ >= 32) return false;
    ++depth_;
    return true;
  }
  void LeaveRecord() { if (depth_) --depth_; }

 private:
  Budget operations_;
  Budget referenced_bytes_;
  Budget glyphs_;
  Budget images_;
  uint32_t depth_ = 0;
};

}  // namespace arx::document
#endif
