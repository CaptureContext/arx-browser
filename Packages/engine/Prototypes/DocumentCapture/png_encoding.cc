#include "components/paint_preview/arx/png_encoding.h"

#include "components/paint_preview/arx/bounded_stream.h"
#include "third_party/skia/include/encode/SkEncoder.h"
#include "third_party/skia/include/encode/SkPngRustEncoder.h"

namespace arx::document {

EncodedPNG EncodeDocumentPNG(const SkBitmap& bitmap, const mojom::Limits& limits,
                            base::TimeTicks deadline, const std::atomic<bool>& cancelled) {
  if (!ValidLimits(limits) || !FitsRaster(bitmap.width(), bitmap.height(), limits) ||
      bitmap.colorType() != kN32_SkColorType ||
      bitmap.rowBytes() != static_cast<size_t>(bitmap.width()) * 4)
    return {mojom::Status::kLimit, {}};
  SkPixmap pixmap;
  if (!bitmap.peekPixels(&pixmap)) return {mojom::Status::kFailed, {}};
  return EncodePixmapPNG(pixmap, limits.maximum_png_bytes, deadline, cancelled);
}

EncodedPNG EncodePixmapPNG(const SkPixmap& pixmap, uint64_t maximum_bytes,
                          base::TimeTicks deadline, const std::atomic<bool>& cancelled) {
  if (!maximum_bytes || maximum_bytes > kMaximumPNGBytes ||
      pixmap.width() <= 0 || pixmap.height() <= 0 || pixmap.width() > 8192 || pixmap.height() > 8192 ||
      static_cast<uint64_t>(pixmap.width()) * pixmap.height() > kMaximumPixels)
    return {mojom::Status::kLimit, {}};
  if (cancelled.load()) return {mojom::Status::kCancelled, {}};
  if (base::TimeTicks::Now() >= deadline) return {mojom::Status::kTimeout, {}};
  BoundedStream stream(maximum_bytes);
  auto encoder = SkPngRustEncoder::Make(&stream, pixmap, {});
  if (!encoder) return {stream.failed() ? mojom::Status::kLimit : mojom::Status::kFailed, {}};
  // The same Chromium PNG backend, with transparency retained. Each row is a
  // cooperative deadline/cancellation boundary; every encoded write is capped.
  for (int row = 0; row < pixmap.height(); ++row) {
    if (cancelled.load()) return {mojom::Status::kCancelled, {}};
    if (base::TimeTicks::Now() >= deadline) return {mojom::Status::kTimeout, {}};
    if (!encoder->encodeRows(1))
      return {stream.failed() ? mojom::Status::kLimit : mojom::Status::kFailed, {}};
  }
  encoder.reset();
  if (stream.failed()) return {mojom::Status::kLimit, {}};
  if (cancelled.load()) return {mojom::Status::kCancelled, {}};
  if (base::TimeTicks::Now() >= deadline) return {mojom::Status::kTimeout, {}};
  if (!stream.bytesWritten()) return {mojom::Status::kFailed, {}};
  return {mojom::Status::kSuccess, {stream.bytes().begin(), stream.bytes().end()}};
}

}  // namespace arx::document
