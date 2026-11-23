#include <cassert>
#include "components/paint_preview/arx/png_encoding.h"
#include "document_encoding_peers.h"
using namespace arx::document;
using Status = mojom::Status;
int main() {
  mojom::Limits limits;
  limits.maximum_png_bytes = 1024;
  SkBitmap bitmap;
  std::atomic<bool> cancelled(false);
  EncodingControl::Reset();
  auto result = EncodeDocumentPNG(bitmap, limits, base::TimeTicks(100), cancelled);
  assert(result.status == Status::kSuccess && result.bytes.size() == 35);
  assert(EncodingControl::rows == 4);
  EncodingControl::Reset(); limits.maximum_png_bytes = 10;
  result = EncodeDocumentPNG(bitmap, limits, base::TimeTicks(100), cancelled);
  assert(result.status == Status::kLimit && result.bytes.empty());
  assert(EncodingControl::rows == 1);  // rejected before retaining an oversized row
  EncodingControl::Reset(); limits.maximum_png_bytes = 2;
  result = EncodeDocumentPNG(bitmap, limits, base::TimeTicks(100), cancelled);
  assert(result.status == Status::kLimit && EncodingControl::rows == 0); // header write
  EncodingControl::Reset(); limits.maximum_png_bytes = 1024;
  EncodingControl::cancel_after_row = &cancelled;
  result = EncodeDocumentPNG(bitmap, limits, base::TimeTicks(100), cancelled);
  assert(result.status == Status::kCancelled && result.bytes.empty());
  assert(EncodingControl::rows == 1);
  EncodingControl::Reset(); cancelled = false; EncodingControl::timeout_after_row = true;
  result = EncodeDocumentPNG(bitmap, limits, base::TimeTicks(100), cancelled);
  assert(result.status == Status::kTimeout && result.bytes.empty());
  assert(EncodingControl::rows == 1);
  EncodingControl::Reset(); cancelled = true;
  result = EncodeDocumentPNG(bitmap, limits, base::TimeTicks(100), cancelled);
  assert(result.status == Status::kCancelled && EncodingControl::factories == 0);
  EncodingControl::Reset(); cancelled = false; bitmap.row_bytes = 4096;
  result = EncodeDocumentPNG(bitmap, limits, base::TimeTicks(100), cancelled);
  assert(result.status == Status::kLimit && EncodingControl::factories == 0);
  EncodingControl::Reset(); bitmap.row_bytes = 16; bitmap.pixels.width_value = 8193;
  result = EncodeDocumentPNG(bitmap, limits, base::TimeTicks(100), cancelled);
  assert(result.status == Status::kLimit && EncodingControl::factories == 0);
}
