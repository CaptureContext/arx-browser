#include <cassert>
#include <algorithm>
#include <cstdint>
#include <limits>

#include "budget.h"

struct Limits {
  uint32_t maximum_dimension = 8192;
  uint64_t maximum_pixels = arx::document::kMaximumPixels;
  uint64_t maximum_record_bytes = arx::document::kMaximumRecordBytes;
  uint64_t maximum_record_ops = arx::document::kMaximumRecordOps;
  uint64_t maximum_decoded_image_bytes = arx::document::kMaximumDecodedImageBytes;
  uint64_t maximum_serialized_bytes = arx::document::kMaximumSerializedBytes;
  uint64_t maximum_png_bytes = arx::document::kMaximumPNGBytes;
  uint32_t timeout_ms = 3000;
};

int main() {
  using namespace arx::document;
  Limits limits;
  assert(ValidLimits(limits));
  assert(FitsRaster(4096, 4096, limits));
  assert(!FitsRaster(4096, 4097, limits));
  assert(!FitsRaster(1, 8193, limits));
  assert(!FitsRaster(0, 100, limits));
  assert(!FitsRaster(-1, 100, limits));
  assert(!FitsRaster(INT32_MAX, INT32_MAX, limits));
  assert(FitsExtent(-100, -50, 800, 600, limits));
  assert(!FitsExtent(INT32_MIN, 0, 1, 1, limits));
  assert(!FitsExtent(INT32_MAX, 0, 1, 1, limits));
  assert(!FitsExtent(8192, 0, 1, 1, limits));

  limits.maximum_serialized_bytes = 0;
  assert(!ValidLimits(limits));
  limits = Limits();
  limits.maximum_record_ops = kMaximumRecordOps + 1;
  assert(!ValidLimits(limits));
  limits = Limits();
  limits.maximum_decoded_image_bytes = kMaximumDecodedImageBytes + 1;
  assert(!ValidLimits(limits));
  limits = Limits();
  limits.timeout_ms = 10001;
  assert(!ValidLimits(limits));

  // An oversized producer cannot allocate, truncate to fit, then continue with
  // a misleading successful record. Failure is sticky and old bytes survive.
  const uint8_t pixels[] = {1, 2, 3, 4};
  BoundedBytes bytes(5);
  assert(bytes.Append(pixels, 4));
  assert(!bytes.Append(pixels, 2));
  assert(bytes.failed());
  assert(std::ranges::equal(bytes.bytes(), pixels));
  assert(!bytes.Append(pixels, 1));
  assert(!bytes.Append(nullptr, 0));
  assert(bytes.bytes().size() == 4);

  BoundedBytes exact(4);
  assert(exact.Append(nullptr, 0));
  assert(exact.Append(pixels, 4));
  assert(!exact.failed());
  assert(!exact.Append(pixels, SIZE_MAX));
  assert(exact.bytes().size() == 4);

  // Aggregate decoded-image accounting does not reset between images. Even a
  // later zero-size write cannot turn exhausted accounting into success.
  Budget images(8);
  assert(images.Consume(4));
  assert(images.Consume(4));
  assert(!images.Consume(1));
  assert(!images.Consume(0));
  Budget overflow(8);
  assert(!overflow.Consume(UINT64_MAX));
}
