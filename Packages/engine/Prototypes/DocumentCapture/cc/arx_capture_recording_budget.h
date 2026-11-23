#ifndef CC_PAINT_ARX_CAPTURE_RECORDING_BUDGET_H_
#define CC_PAINT_ARX_CAPTURE_RECORDING_BUDGET_H_

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace cc {
// Applies only while the fresh, transient Paint Preview builder is painting.
// Pending configuration does not alter page lifecycle/persistent-cache painting.
class ArxCaptureRecordingBudget final {
 public:
  enum class Status { kSuccess, kLimit, kTimeout, kUnsupported };
  using Clock = std::chrono::steady_clock;
  using Now = Clock::time_point (*)();
  ArxCaptureRecordingBudget(uint64_t bytes, uint64_t operations,
                           uint64_t image_bytes, uint32_t milliseconds,
                           Now now = Clock::now)
      : bytes_(bytes), references_(bytes), operations_(operations), images_(image_bytes),
        now_(now), deadline_(now() + std::chrono::milliseconds(milliseconds)),
        previous_pending_(Pending()) { Pending() = this; }
  ~ArxCaptureRecordingBudget() { Pending() = previous_pending_; }
  ArxCaptureRecordingBudget(const ArxCaptureRecordingBudget&) = delete;
  ArxCaptureRecordingBudget& operator=(const ArxCaptureRecordingBudget&) = delete;

  class PaintingScope final {
   public:
    PaintingScope() : previous_(Active()) { Active() = Pending(); }
    ~PaintingScope() { Active() = previous_; }
    PaintingScope(const PaintingScope&) = delete;
    PaintingScope& operator=(const PaintingScope&) = delete;
   private:
    ArxCaptureRecordingBudget* const previous_;
  };

  static ArxCaptureRecordingBudget*& Active() {
    static thread_local ArxCaptureRecordingBudget* active = nullptr;
    return active;
  }
  static bool Good() { return !Active() || Active()->Continue(); }
  static bool Entry(size_t size) {
    if (!Active()) return true;
    // Conservatively charge every retained entry for a separate initial cc
    // buffer plus growth/release-copy slack. This deliberately overcounts shared
    // buffers; it bounds container capacities before retention rather than RSS.
    auto& budget = *Active();
    if (size > (std::numeric_limits<uint64_t>::max() - 4096) / 4)
      return budget.Reject(Status::kLimit);
    return budget.Continue() && budget.Take(budget.operations_, 1) &&
           budget.Take(budget.bytes_, 4096 + static_cast<uint64_t>(size) * 4);
  }
  static bool Reference(uint64_t bytes, uint64_t nested_ops = 0) {
    return !Active() || (Active()->Continue() && Active()->Take(Active()->references_, bytes) &&
                        Active()->Take(Active()->operations_, nested_ops));
  }
  static bool Image(uint64_t width, uint64_t height, uint64_t bpp) {
    if (!Active()) return true;
    if (!width || !height || bpp < 1 || bpp > 16 ||
        width > std::numeric_limits<uint64_t>::max() / height)
      return Active()->Reject(Status::kLimit);
    const auto pixels = width * height;
    const auto charged_bpp = bpp < 4 ? 4 : bpp;
    if (pixels > std::numeric_limits<uint64_t>::max() / charged_bpp)
      return Active()->Reject(Status::kLimit);
    return Active()->Continue() && Active()->Take(Active()->images_, pixels * charged_bpp);
  }
  static bool Layout(uint64_t text, uint64_t fragments, uint64_t depth) {
    if (!Active()) return true;
    if (depth > 64) return Active()->Reject(Status::kLimit);
    return Active()->Continue() && Active()->Take(Active()->layout_nodes_, 1) &&
           Active()->Take(Active()->layout_text_, text) &&
           Active()->Take(Active()->layout_fragments_, fragments);
  }
  // Fixed numeric diagnostics only; neither document data nor paint payloads.
  enum class UnsupportedReason : uint32_t {
    kUnspecified, kOperation, kFlags, kImageKind, kImageColor, kTextBlob,
    kForeignLayer, kMoveChunk, kLayoutContent, kRegionCapture, kTrackedElement,
  };
  static bool Unsupported(UnsupportedReason reason = UnsupportedReason::kUnspecified,
                          uint32_t detail = 0) {
    if (!Active()) return true;
    if (Active()->status_ == Status::kSuccess) {
      Active()->unsupported_reason_ = reason;
      Active()->unsupported_detail_ = detail;
    }
    return Active()->Reject(Status::kUnsupported);
  }
  static void Operation(uint32_t type) {
    if (Active() && Active()->status_ == Status::kSuccess) Active()->operation_type_ = type;
  }
  Status status() const { return status_; }
  UnsupportedReason unsupported_reason() const { return unsupported_reason_; }
  uint32_t unsupported_detail() const { return unsupported_detail_; }
  uint32_t operation_type() const { return operation_type_; }

 private:
  static ArxCaptureRecordingBudget*& Pending() {
    static thread_local ArxCaptureRecordingBudget* pending = nullptr;
    return pending;
  }
  bool Reject(Status status) {
    if (status_ == Status::kSuccess) status_ = status;
    return false;
  }
  bool Continue() {
    if (status_ != Status::kSuccess) return false;
    return now_() < deadline_ || Reject(Status::kTimeout);
  }
  bool Take(uint64_t& remaining, uint64_t amount) {
    if (amount > remaining) return Reject(Status::kLimit);
    remaining -= amount;
    return true;
  }
  uint64_t bytes_, references_, operations_, images_;
  uint64_t layout_nodes_ = 4096, layout_text_ = 100000, layout_fragments_ = 10000;
  Now const now_;
  const Clock::time_point deadline_;
  ArxCaptureRecordingBudget* const previous_pending_;
  Status status_ = Status::kSuccess;
  UnsupportedReason unsupported_reason_ = UnsupportedReason::kUnspecified;
  uint32_t unsupported_detail_ = 0;
  uint32_t operation_type_ = UINT32_MAX;
};
}  // namespace cc
#endif
