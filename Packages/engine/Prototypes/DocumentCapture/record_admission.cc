#include "components/paint_preview/arx/record_admission.h"

#include <cstdio>
#include <cmath>

#include "cc/paint/paint_image.h"
#include "cc/paint/paint_op.h"
#include "cc/paint/paint_op_buffer_iterator.h"
#include "cc/paint/paint_shader.h"
#include "third_party/skia/include/core/SkTextBlob.h"
#include "third_party/skia/include/core/SkTypeface.h"

namespace arx::document {

RecordAdmission::RecordAdmission(const mojom::Limits& limits,
                                 base::TimeTicks deadline)
    : budget_(limits.maximum_record_ops, limits.maximum_record_bytes,
              limits.maximum_decoded_image_bytes),
      conversion_operations_(limits.maximum_record_ops), deadline_(deadline),
      maximum_record_bytes_(limits.maximum_record_bytes),
      maximum_record_ops_(limits.maximum_record_ops) {}

bool RecordAdmission::Reject(mojom::Status status) {
  if (status_ == mojom::Status::kSuccess) status_ = status;
  return false;
}

bool RecordAdmission::Unsupported(UnsupportedReason reason, uint32_t detail) {
  if (status_ == mojom::Status::kSuccess) {
    unsupported_reason_ = reason;
    unsupported_detail_ = detail;
  }
  return Reject(mojom::Status::kUnsupported);
}

bool RecordAdmission::WithinDeadline() {
  if (status_ != mojom::Status::kSuccess) return false;
  return base::TimeTicks::Now() < deadline_ || Reject(mojom::Status::kTimeout);
}

mojom::Status RecordAdmission::Inspect(const cc::PaintRecord& record) {
  Record(record);
  return status_;
}

bool RecordAdmission::Image(const cc::PaintImage& image) {
  // Metadata access is documented not to read back a texture. Deferred/vector
  // images, animated sources and gainmaps need a separate resource policy.
  if (image.IsDeferredPaintRecord() || image.IsLazyGenerated() || image.ShouldAnimate() || image.HasGainmapInfo())
    return Unsupported(UnsupportedReason::kImageKind, image.IsDeferredPaintRecord() |
        (image.IsLazyGenerated() << 1) | (image.ShouldAnimate() << 2) | (image.HasGainmapInfo() << 3));
  const auto info = image.GetSkImageInfo();
  if (info.colorType() == kUnknown_SkColorType)
    return Unsupported(UnsupportedReason::kImageColor);
  if (!budget_.Image(info.width(), info.height(), info.bytesPerPixel()))
    return Reject(mojom::Status::kLimit);
  return true;
}

bool RecordAdmission::Typeface(const SkTypeface* typeface) {
  if (!typeface || !typeface->uniqueID()) return Unsupported(UnsupportedReason::kTypeface);
  for (size_t index = 0; index < typeface_count_; ++index)
    if (typefaces_[index] == typeface->uniqueID()) return true;
  if (typeface_count_ == typefaces_.size()) return Reject(mojom::Status::kLimit);
  const int count = typeface->countTables();
  if (count <= 0) return Unsupported(UnsupportedReason::kTypefaceTables);
  if (count > 256) return Reject(mojom::Status::kLimit);
  std::array<SkFontTableTag, 256> tags;
  if (typeface->readTableTags({tags.data(), static_cast<size_t>(count)}) != count)
    return Unsupported(UnsupportedReason::kTypefaceTags);
  // Admit the SFNT directory, per-table alignment and source table payload
  // before Paint Preview opens/subsets a font stream. No font data is copied.
  if (!budget_.ReferencedBytes(12 + static_cast<uint64_t>(count) * 20))
    return Reject(mojom::Status::kLimit);
  for (int index = 0; index < count; ++index) {
    if (!WithinDeadline()) return false;
    if (!budget_.ReferencedBytes(typeface->getTableSize(tags[index])))
      return Reject(mojom::Status::kLimit);
  }
  typefaces_[typeface_count_++] = typeface->uniqueID();
  return true;
}

bool RecordAdmission::Record(const cc::PaintRecord& record) {
  if (!WithinDeadline()) return false;
  if (record.bytes_used() > maximum_record_bytes_ ||
      record.total_op_count() > maximum_record_ops_ || !budget_.EnterRecord())
    return Reject(mojom::Status::kLimit);
  // Record nesting is capped before recursion. State depth is bounded per
  // record; each DrawRecord also contributes a SkAutoCanvasRestore on playback.
  int saves = 0;
  uint64_t operation_index = 0;
  for (const cc::PaintOp& op : record) {
    ++operation_index;
    if (!WithinDeadline()) return false;
    operation_type_ = static_cast<uint32_t>(op.GetType());
    if (!budget_.Operation()) return Reject(mojom::Status::kLimit);
    if (op.IsPaintOpWithFlags()) {
      const auto& flags = static_cast<const cc::PaintOpWithFlags&>(op).flags;
      // Solid and linear-gradient shaders match the renderer's recording
      // admission; image, record, SkSL and other gradient shaders do not.
      const bool shader = flags.HasShader() &&
          flags.getShader()->shader_type() != cc::PaintShader::Type::kColor &&
          flags.getShader()->shader_type() != cc::PaintShader::Type::kLinearGradient;
      if (shader || flags.getImageFilter() || flags.getPathEffect() ||
          flags.getColorFilter() || flags.getLooper())
        return Unsupported(UnsupportedReason::kFlags, shader |
            (!!flags.getImageFilter() << 1) | (!!flags.getPathEffect() << 2) |
            (!!flags.getColorFilter() << 3) | (!!flags.getLooper() << 4));
      if (flags.HasShader() && !budget_.ReferencedBytes(4096)) return Reject(mojom::Status::kLimit);
    }
    switch (op.GetType()) {
      case cc::PaintOpType::kDrawRecord:
        if (!Record(static_cast<const cc::DrawRecordOp&>(op).record)) return false;
        break;
      case cc::PaintOpType::kDrawImage:
        if (!Image(static_cast<const cc::DrawImageOp&>(op).image)) return false;
        break;
      case cc::PaintOpType::kDrawImageRect:
        if (!Image(static_cast<const cc::DrawImageRectOp&>(op).image)) return false;
        break;
      case cc::PaintOpType::kClipPath:
        if (!budget_.ReferencedBytes(static_cast<const cc::ClipPathOp&>(op).path.approximateBytesUsed()))
          return Reject(mojom::Status::kLimit);
        break;
      case cc::PaintOpType::kDrawPath:
        if (!budget_.ReferencedBytes(static_cast<const cc::DrawPathOp&>(op).path.approximateBytesUsed()))
          return Reject(mojom::Status::kLimit);
        break;
      case cc::PaintOpType::kDrawTextBlob: {
        const auto& blob = static_cast<const cc::DrawTextBlobOp&>(op).blob;
        if (!blob) return Unsupported(UnsupportedReason::kTextBlob);
        SkTextBlob::Iter iterator(*blob);
        SkTextBlob::Iter::Run run;
        while (iterator.next(&run)) {
          if (!WithinDeadline()) return false;
          if (!Typeface(run.fTypeface)) return false;
          if (run.fGlyphCount < 0 || !budget_.Glyphs(run.fGlyphCount))
            return Reject(mojom::Status::kLimit);
        }
        break;
      }
      case cc::PaintOpType::kSaveLayerAlpha: {
        // Preserve real group isolation. Actual N32 base/layer allocations
        // are fallible and bounded in the capture-only utility raster path.
        const auto& layer = static_cast<const cc::SaveLayerAlphaOp&>(op);
        if (!layer.IsValid() || !std::isfinite(layer.alpha) || layer.alpha < 0 || layer.alpha > 1) {
          std::fprintf(stderr,
              "ARX_DOCUMENT_CAPTURE_ALPHA_LAYER alpha=%g bounds=%g,%g,%g,%g unset=%u index=%llu saves=%d record_bytes=%zu record_ops=%zu\n",
              static_cast<double>(layer.alpha), static_cast<double>(layer.bounds.left()),
              static_cast<double>(layer.bounds.top()), static_cast<double>(layer.bounds.right()),
              static_cast<double>(layer.bounds.bottom()),
              layer.bounds.left() == SK_ScalarInfinity,
              static_cast<unsigned long long>(operation_index), saves,
              record.bytes_used(), record.total_op_count());
          return Unsupported(UnsupportedReason::kOperation, static_cast<uint32_t>(op.GetType()));
        }
        if (++saves > 64) return Reject(mojom::Status::kLimit);
        break;
      }
      case cc::PaintOpType::kSave:
        if (++saves > 64) return Reject(mojom::Status::kLimit);
        break;
      case cc::PaintOpType::kRestore:
        if (--saves < 0) return Unsupported(UnsupportedReason::kRestore);
        break;
      case cc::PaintOpType::kClipRect:
      case cc::PaintOpType::kClipRRect:
      case cc::PaintOpType::kConcat:
      case cc::PaintOpType::kDrawArc:
      case cc::PaintOpType::kDrawArcLite:
      case cc::PaintOpType::kDrawColor:
      case cc::PaintOpType::kDrawDRRect:
      case cc::PaintOpType::kDrawIRect:
      case cc::PaintOpType::kDrawLine:
      case cc::PaintOpType::kDrawLineLite:
      case cc::PaintOpType::kDrawOval:
      case cc::PaintOpType::kDrawRect:
      case cc::PaintOpType::kDrawRRect:
      case cc::PaintOpType::kNoop:
      case cc::PaintOpType::kRotate:
      case cc::PaintOpType::kScale:
      case cc::PaintOpType::kSetMatrix:
      case cc::PaintOpType::kSetNodeId:
      case cc::PaintOpType::kTranslate:
        break;
      // No implicit omission: filters/layers, arbitrary shaders, Skottie,
      // vertices, frame custom data and GPU text need explicit admission.
      default:
        return Unsupported(UnsupportedReason::kOperation, static_cast<uint32_t>(op.GetType()));
    }
  }
  budget_.LeaveRecord();
  return saves == 0 || Unsupported(UnsupportedReason::kSaves);
}

bool RecordAdmission::Continue(const cc::PaintOp&) {
  if (!WithinDeadline()) return false;
  return conversion_operations_.Consume(1) || Reject(mojom::Status::kLimit);
}

}  // namespace arx::document
