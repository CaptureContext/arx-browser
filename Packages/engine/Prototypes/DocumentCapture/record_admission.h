#ifndef ARX_DOCUMENT_PROTOTYPE_RECORD_ADMISSION_H_
#define ARX_DOCUMENT_PROTOTYPE_RECORD_ADMISSION_H_

#include <array>

#include "base/time/time.h"
#include "cc/paint/paint_record.h"
#include "components/paint_preview/arx/document_capture.mojom.h"
#include "components/paint_preview/arx/resource_budget.h"

class SkTypeface;
namespace cc { class PaintImage; }

namespace arx::document {

// Fail closed for resources whose capture-specific allocation cannot yet be
// admitted. Inspect never decodes, reads pixels or converts accelerated images.
class RecordAdmission {
 public:
  RecordAdmission(const mojom::Limits& limits, base::TimeTicks deadline);
  mojom::Status Inspect(const cc::PaintRecord& record);
  bool Continue(const cc::PaintOp& op);
  mojom::Status status() const { return status_; }
  // Stable diagnostic categories; op/flag details are native enum/bit values.
  enum class UnsupportedReason : uint32_t {
    kNone, kImageKind, kImageColor, kTypeface, kTypefaceTables,
    kTypefaceTags, kFlags, kTextBlob, kRestore, kOperation, kSaves,
  };
  UnsupportedReason unsupported_reason() const { return unsupported_reason_; }
  uint32_t unsupported_detail() const { return unsupported_detail_; }
  uint32_t operation_type() const { return operation_type_; }

 private:
  bool Record(const cc::PaintRecord& record);
  bool Image(const cc::PaintImage& image);
  bool Typeface(const SkTypeface* typeface);
  bool Reject(mojom::Status status);
  bool Unsupported(UnsupportedReason reason, uint32_t detail = 0);
  bool WithinDeadline();

  ResourceBudget budget_;
  Budget conversion_operations_;
  const base::TimeTicks deadline_;
  const uint64_t maximum_record_bytes_;
  const uint64_t maximum_record_ops_;
  std::array<uint32_t, 256> typefaces_{};
  size_t typeface_count_ = 0;
  mojom::Status status_ = mojom::Status::kSuccess;
  UnsupportedReason unsupported_reason_ = UnsupportedReason::kNone;
  uint32_t unsupported_detail_ = 0;
  uint32_t operation_type_ = UINT32_MAX;
};

}  // namespace arx::document
#endif
