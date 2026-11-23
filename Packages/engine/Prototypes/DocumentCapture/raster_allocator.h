#ifndef ARX_DOCUMENT_CAPTURE_RASTER_ALLOCATOR_H_
#define ARX_DOCUMENT_CAPTURE_RASTER_ALLOCATOR_H_

#include <atomic>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <new>
#include <optional>

#include "base/time/time.h"
#include "base/process/memory.h"
#include "components/services/paint_preview_compositor/arx_raster_surface_budget.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkCanvas.h"
#include "third_party/skia/include/core/SkPicture.h"
#include "third_party/skia/include/core/SkRasterHandleAllocator.h"

namespace arx::document {

enum class RasterStatus { kSuccess, kLimit, kAllocation, kTimeout };

struct RasterState {
  RasterState(int width, int height, base::TimeTicks deadline,
              uint64_t layer_bytes = RasterSurfaceBudget::kMaximumLayerBytes)
      : budget(width, height, layer_bytes), width(width), height(height), deadline(deadline) {}

  bool Continue() {
    if (status.load() != RasterStatus::kSuccess) return false;
    if (base::TimeTicks::Now() >= deadline) Fail(RasterStatus::kTimeout);
    return status.load() == RasterStatus::kSuccess;
  }
  void Fail(RasterStatus failure) {
    auto expected = RasterStatus::kSuccess;
    status.compare_exchange_strong(expected, failure);
  }

  std::mutex lock;
  RasterSurfaceBudget budget;
  const int width;
  const int height;
  const base::TimeTicks deadline;
  std::atomic<RasterStatus> status{RasterStatus::kSuccess};
};

// Canvas and returned bitmap independently retain the same base allocation.
// Layer release runs on restore/destruction; base release may run on the Mojo
// reply thread. Each allocation keeps state alive and updates it under lock.
class RasterAllocator final : public SkRasterHandleAllocator {
 public:
  using Allocate = bool (*)(size_t, size_t, void**);
  explicit RasterAllocator(std::shared_ptr<RasterState> state, Allocate allocate = &base::UncheckedCalloc)
      : state_(std::move(state)), allocate_(allocate) {}

  bool allocHandle(const SkImageInfo& info, Rec* rec) override {
    if (!state_->Continue()) return false;
    uint64_t bytes = 0;
    {
      std::lock_guard guard(state_->lock);
      if (info.colorType() != kN32_SkColorType || info.alphaType() != kPremul_SkAlphaType ||
          !state_->budget.Acquire(info.width(), info.height(), &bytes)) {
        state_->Fail(RasterStatus::kLimit);
        return false;
      }
    }
    void* allocation_memory = nullptr;
    if (!base::UncheckedMalloc(sizeof(Allocation), &allocation_memory)) {
      std::lock_guard guard(state_->lock);
      state_->budget.Release(bytes);
      state_->Fail(RasterStatus::kAllocation);
      return false;
    }
    auto* allocation = new (allocation_memory) Allocation(state_, bytes);
    if (!allocate_(1, static_cast<size_t>(bytes), &allocation->pixels)) {
      state_->Fail(RasterStatus::kAllocation);
      Release(nullptr, allocation);
      return false;
    }
    *rec = {&Release, allocation, allocation->pixels,
            static_cast<size_t>(info.width()) * 4, allocation};
    return true;
  }

  void updateHandle(Handle, const SkMatrix&, const SkIRect&) override {}

  static bool RetainBase(SkCanvas& canvas, SkBitmap* bitmap) {
    SkPixmap pixmap;
    auto* base = static_cast<Allocation*>(canvas.accessTopRasterHandle());
    if (!base || !canvas.peekPixels(&pixmap)) return false;
    base->references.fetch_add(1);
    // installPixels invokes Release on failure too (pinned SkBitmap.cpp).
    return bitmap->installPixels(pixmap.info(), base->pixels, pixmap.rowBytes(), &Release, base);
  }

 private:
  struct Allocation {
    Allocation(std::shared_ptr<RasterState> state, uint64_t bytes)
        : state(std::move(state)), bytes(bytes) {}
    std::shared_ptr<RasterState> state;
    const uint64_t bytes;
    std::atomic<uint32_t> references{1};
    void* pixels = nullptr;
  };

  static void Release(void*, void* context) {
    auto* allocation = static_cast<Allocation*>(context);
    if (allocation->references.fetch_sub(1) != 1) return;
    base::UncheckedFree(allocation->pixels);
    {
      std::lock_guard guard(allocation->state->lock);
      if (!allocation->state->budget.Release(allocation->bytes))
        allocation->state->Fail(RasterStatus::kLimit);
    }
    allocation->~Allocation();
    base::UncheckedFree(allocation);
  }

  const std::shared_ptr<RasterState> state_;
  const Allocate allocate_;
};

class RasterAbort final : public SkPicture::AbortCallback {
 public:
  explicit RasterAbort(RasterState& state) : state_(state) {}
  bool abort() override { return !state_.Continue(); }
 private:
  RasterState& state_;
};

inline std::optional<SkBitmap> RasterPicture(
    const SkPicture& picture, const SkMatrix& matrix,
    const std::shared_ptr<RasterState>& state, const SkSurfaceProps* props) {
  if (!state->Continue()) return std::nullopt;
  auto canvas = SkRasterHandleAllocator::MakeCanvas(
      std::make_unique<RasterAllocator>(state),
      SkImageInfo::MakeN32Premul(state->width, state->height), nullptr, props);
  if (!canvas) {
    state->Fail(RasterStatus::kAllocation);
    return std::nullopt;
  }
  canvas->clear(SK_ColorTRANSPARENT);
  canvas->concat(matrix);
  RasterAbort abort(*state);
  picture.playback(canvas.get(), &abort);
  // Aborted playback may leave saves open. Restore releases every layer before
  // inspecting sticky status and exposing the base bitmap.
  canvas->restoreToCount(1);
  if (!state->Continue()) return std::nullopt;
  SkBitmap bitmap;
  if (!RasterAllocator::RetainBase(*canvas, &bitmap)) {
    state->Fail(RasterStatus::kAllocation);
    return std::nullopt;
  }
  return bitmap;
}

}  // namespace arx::document
#endif
