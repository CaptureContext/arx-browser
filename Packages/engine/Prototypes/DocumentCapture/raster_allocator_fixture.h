#ifndef ARX_DOCUMENT_CAPTURE_RASTER_ALLOCATOR_FIXTURE_H_
#define ARX_DOCUMENT_CAPTURE_RASTER_ALLOCATOR_FIXTURE_H_

#include <array>
#include <cmath>

#include "components/services/paint_preview_compositor/arx_raster_allocator.h"
#include "third_party/skia/include/core/SkPaint.h"
#include "third_party/skia/include/core/SkPictureRecorder.h"

namespace arx::document::testing {

// Runs only from the explicit fresh-root owned capture host. These tests call
// the actual allocator and Skia playback, including refusal after base pixels
// exist; a NoPixels fallback must never turn rejection into a successful image.
inline bool VerifyRasterAllocator() {
  const auto deadline = base::TimeTicks::Now() + base::Seconds(5);
  SkPictureRecorder recorder;
  auto* recording = recorder.beginRecording(8, 8);
  recording->saveLayerAlphaf(nullptr, 0.5f);
  SkPaint paint;
  paint.setColor(SK_ColorRED);
  recording->drawRect(SkRect::MakeWH(6, 8), paint);
  recording->drawRect(SkRect::MakeXYWH(2, 0, 6, 8), paint);
  recording->restore();
  auto picture = recorder.finishRecordingAsPicture();
  SkMatrix identity;
  identity.setIdentity();
  auto state = std::make_shared<RasterState>(8, 8, deadline);
  auto bitmap = RasterPicture(*picture, identity, state, nullptr);
  if (!bitmap || state->status.load() != RasterStatus::kSuccess ||
      std::abs(static_cast<int>(SkColorGetA(bitmap->getColor(4, 4))) - 128) > 1 ||
      SkColorGetR(bitmap->getColor(4, 4)) != 255 ||
      state->budget.live_bytes() != 256 || state->budget.live_allocations() != 1 ||
      state->budget.peak_bytes() != 512) return false;
  bitmap.reset();
  if (state->budget.live_bytes() || state->budget.live_allocations()) return false;

  auto limited = std::make_shared<RasterState>(8, 8, deadline, 0);
  if (RasterPicture(*picture, identity, limited, nullptr) ||
      limited->status.load() != RasterStatus::kLimit ||
      limited->budget.live_bytes() || limited->budget.live_allocations()) return false;

  auto failed = std::make_shared<RasterState>(8, 8, deadline);
  RasterAllocator allocator(failed);
  SkRasterHandleAllocator::Rec base{};
  if (!allocator.allocHandle(SkImageInfo::MakeN32Premul(8, 8), &base)) return false;
  RasterAllocator refusing(failed, [](size_t, size_t, void** result) { *result = nullptr; return false; });
  SkRasterHandleAllocator::Rec layer{};
  const bool unexpectedly_allocated = refusing.allocHandle(SkImageInfo::MakeN32Premul(8, 8), &layer);
  base.fReleaseProc(base.fPixels, base.fReleaseCtx);
  if (unexpectedly_allocated || failed->status.load() != RasterStatus::kAllocation ||
      failed->budget.live_bytes() || failed->budget.live_allocations()) return false;

  auto expired = std::make_shared<RasterState>(8, 8, base::TimeTicks::Now() - base::Seconds(1));
  if (RasterPicture(*picture, identity, expired, nullptr) ||
      expired->status.load() != RasterStatus::kTimeout || expired->budget.live_bytes()) return false;

  // Actual allocator admission, not Skia layer optimization, controls depth.
  auto nested = std::make_shared<RasterState>(1, 1, deadline);
  RasterAllocator layers(nested);
  std::array<SkRasterHandleAllocator::Rec, 9> allocations{};
  for (auto& allocation : allocations)
    if (!layers.allocHandle(SkImageInfo::MakeN32Premul(1, 1), &allocation)) return false;
  SkRasterHandleAllocator::Rec ninth_layer{};
  const bool depth_accepted = layers.allocHandle(SkImageInfo::MakeN32Premul(1, 1), &ninth_layer);
  for (auto& allocation : allocations) allocation.fReleaseProc(allocation.fPixels, allocation.fReleaseCtx);
  return !depth_accepted && nested->status.load() == RasterStatus::kLimit &&
         nested->budget.live_bytes() == 0 && nested->budget.live_allocations() == 0;
}

}  // namespace arx::document::testing
#endif
