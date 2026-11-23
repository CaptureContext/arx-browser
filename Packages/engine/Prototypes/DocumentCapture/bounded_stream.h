#ifndef ARX_DOCUMENT_PROTOTYPE_BOUNDED_STREAM_H_
#define ARX_DOCUMENT_PROTOTYPE_BOUNDED_STREAM_H_

#include "components/paint_preview/arx/budget.h"
#include "third_party/skia/include/core/SkStream.h"

namespace arx::document {

// Fixed retained capacity, allocated only after the caller's geometry/limits
// admission. A failed producer cannot truncate and then report success.
class BoundedStream final : public SkWStream {
 public:
  explicit BoundedStream(size_t limit) : bytes_(limit) {}
  bool write(const void* data, size_t size) override { return bytes_.Append(data, size); }
  size_t bytesWritten() const override { return bytes_.bytes().size(); }
  bool failed() const { return bytes_.failed(); }
  std::span<const uint8_t> bytes() const { return bytes_.bytes(); }

 private:
  BoundedBytes bytes_;
};

}  // namespace arx::document
#endif
