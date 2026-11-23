#ifndef ARX_DOCUMENT_PROTOTYPE_PNG_ENCODING_H_
#define ARX_DOCUMENT_PROTOTYPE_PNG_ENCODING_H_

#include <atomic>
#include <cstdint>
#include <vector>

#include "base/time/time.h"
#include "components/paint_preview/arx/document_capture.mojom.h"
#include "third_party/skia/include/core/SkBitmap.h"

namespace arx::document {

struct EncodedPNG {
  mojom::Status status;
  std::vector<uint8_t> bytes;
};

EncodedPNG EncodePixmapPNG(const SkPixmap& pixmap, uint64_t maximum_bytes,
                          base::TimeTicks deadline, const std::atomic<bool>& cancelled);

EncodedPNG EncodeDocumentPNG(const SkBitmap& bitmap, const mojom::Limits& limits,
                            base::TimeTicks deadline, const std::atomic<bool>& cancelled);

}  // namespace arx::document
#endif
