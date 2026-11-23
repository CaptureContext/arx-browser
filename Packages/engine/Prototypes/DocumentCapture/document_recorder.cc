#include "components/paint_preview/arx/document_recorder.h"

#include <atomic>
#include <cmath>
#include <cstdio>
#include <limits>
#include <utility>
#include <vector>

#include "base/auto_reset.h"
#include "base/functional/bind.h"
#include "base/task/single_thread_task_runner.h"
#include "cc/paint/paint_recorder.h"
#include "cc/paint/arx_capture_recording_budget.h"
#include "components/paint_preview/arx/budget.h"
#include "components/paint_preview/arx/bounded_stream.h"
#include "components/paint_preview/arx/record_admission.h"
#include "components/paint_preview/arx/png_encoding.h"
#include "components/paint_preview/common/paint_preview_tracker.h"
#include "components/paint_preview/common/serial_utils.h"
#include "components/paint_preview/renderer/paint_preview_recorder_utils.h"
#include "content/public/renderer/render_frame.h"
#include "skia/ext/skia_utils_base.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_registry.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_element.h"
#include "third_party/blink/public/web/web_frame_widget.h"
#include "third_party/blink/public/web/web_local_frame.h"
#include "third_party/blink/public/web/web_view.h"
#include "third_party/skia/include/core/SkData.h"
#include "third_party/skia/include/core/SkImage.h"
#include "third_party/skia/include/core/SkStream.h"

namespace arx::document {
namespace {

struct Images {
  Budget decoded;
  uint64_t serialized_remaining;
  base::TimeTicks deadline;
  mojom::Status status = mojom::Status::kSuccess;
  uint32_t failure = 0;
};

SkSerialReturnType SerializeImage(SkImage* image, void* context) {
  auto& images = *static_cast<Images*>(context);
  if (images.status != mojom::Status::kSuccess) return SkData::MakeEmpty();
  const auto bytes = image->imageInfo().computeMinByteSize();
  if (bytes == SIZE_MAX || !images.decoded.Consume(bytes)) {
    images.failure = 1;
    images.status = mojom::Status::kLimit;
    return SkData::MakeEmpty();
  }
  SkPixmap pixmap;
  // Preflight allows resident raster/texture images only. After conversion,
  // a source that cannot expose resident pixels fails rather than disappearing.
  if (image->isTextureBacked() || !image->peekPixels(&pixmap)) {
    images.failure = image->isTextureBacked() ? 2 : 3;
    images.status = mojom::Status::kUnsupported;
    return SkData::MakeEmpty();
  }
  const std::atomic<bool> not_cancelled(false);
  auto encoded = EncodePixmapPNG(pixmap, images.serialized_remaining, images.deadline, not_cancelled);
  if (encoded.status != mojom::Status::kSuccess) {
    images.failure = 4;
    images.status = encoded.status;
    return SkData::MakeEmpty();
  }
  images.serialized_remaining -= encoded.bytes.size();
  return SkData::MakeWithCopy(encoded.bytes.data(), encoded.bytes.size());
}

}  // namespace

DocumentRecorder::DocumentRecorder(content::RenderFrame* frame)
    : RenderFrameObserver(frame) {
  frame->GetAssociatedInterfaceRegistry()->AddInterface<mojom::DocumentRecorder>(
      base::BindRepeating(&DocumentRecorder::Bind, weak_factory_.GetWeakPtr()));
}

DocumentRecorder::~DocumentRecorder() = default;

void DocumentRecorder::Bind(
    mojo::PendingAssociatedReceiver<mojom::DocumentRecorder> receiver) {
  receiver_.reset();
  receiver_.Bind(std::move(receiver));
}

void DocumentRecorder::OnDestruct() {
  receiver_.reset();
  base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE, this);
}

mojom::GeometryPtr DocumentRecorder::Geometry() const {
  auto fail = [](uint32_t reason) -> mojom::GeometryPtr {
    std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_RENDERER_GEOMETRY_NULL reason=%u\n", reason);
    return nullptr;
  };
  auto* frame = render_frame()->GetWebFrame();
  if (!frame) return fail(1);
  if (!frame->FrameWidget()) return fail(2);
  if (!frame->View()) return fail(3);
  if (frame->FirstChild()) return fail(4);
  if (frame->Parent()) return fail(5);

  const auto document = frame->GetDocument();
  if (document.IsNull()) return fail(6);
  auto geometry = mojom::Geometry::New();
  geometry->document = document.Token().value();
  geometry->document_rect = frame->DocumentRectForArxCapture();
  geometry->visible_rect = frame->VisibleContentRect();
  geometry->scroll = frame->GetScrollOffset();
  geometry->zoom_level = frame->FrameWidget()->GetZoomLevel();
  geometry->page_scale = frame->View()->PageScaleFactor();
  const auto focused = document.FocusedElement();
  geometry->focused_node = focused.IsNull() ? 0 : focused.GetDomNodeId();
  if (geometry->document_rect.IsEmpty()) return fail(7);
  if (geometry->visible_rect.IsEmpty()) return fail(8);
  if (!std::isfinite(geometry->zoom_level)) return fail(9);
  if (geometry->page_scale != 1.0f) return fail(10);
  if (!std::isfinite(geometry->scroll.x()) || !std::isfinite(geometry->scroll.y())) return fail(11);
  return geometry;
}

void DocumentRecorder::Inspect(InspectCallback callback) {
  std::move(callback).Run(Geometry());
}

void DocumentRecorder::Record(mojom::GeometryPtr expected,
                              mojom::LimitsPtr limits,
                              RecordCallback callback) {
  // 1: input/geometry, 2: fresh paint, 3: admission, 4: SkPicture conversion,
  // 5: embedded content, 6: font/image serialization and final geometry.
  uint32_t stage = 1;
  auto fail = [&callback, &stage](mojom::Status status) {
    std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_RENDERER_FAILED stage=%u status=%u\n",
                 stage, static_cast<unsigned>(status));
    std::move(callback).Run(status, std::nullopt);
  };
  if (recording_) { fail(mojom::Status::kBusy); return; }
  if (!limits || !ValidLimits(*limits)) { fail(mojom::Status::kLimit); return; }
  const auto deadline = base::TimeTicks::Now() + base::Milliseconds(limits->timeout_ms);
  auto current = Geometry();
  if (!current) { fail(mojom::Status::kUnsupported); return; }
  if (!expected || !current->Equals(*expected)) { fail(mojom::Status::kChanged); return; }
  const auto bounds = expected->document_rect;
  if (!FitsExtent(bounds.x(), bounds.y(), bounds.width(), bounds.height(), *limits)) {
    fail(mojom::Status::kLimit);
    return;
  }

  const base::AutoReset<bool> recording(&recording_, true);
  stage = 2;
  auto* frame = render_frame()->GetWebFrame();
  paint_preview::PaintPreviewTracker tracker(
      base::UnguessableToken::Create(), frame->GetEmbeddingToken(), true);
  cc::ArxCaptureRecordingBudget recording_budget(limits->maximum_record_bytes,
      limits->maximum_record_ops, limits->maximum_decoded_image_bytes, limits->timeout_ms);
  cc::PaintRecorder recorder;
  auto* canvas = recorder.beginRecording();
  canvas->SetPaintPreviewTracker(&tracker);
  canvas->save();
  canvas->translate(-static_cast<float>(bounds.x()), -static_cast<float>(bounds.y()));
  // Preserve scrollbars: removing layout-affecting scrollbars forces relayout.
  const bool painted = frame->CapturePaintPreview(
      bounds, canvas, false, false, true);
  canvas->restore();
  canvas->SetPaintPreviewTracker(nullptr);
  if (recording_budget.status() != cc::ArxCaptureRecordingBudget::Status::kSuccess) {
    std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_RECORDING_BUDGET status=%u reason=%u detail=%u op=%u\n",
        static_cast<unsigned>(recording_budget.status()),
        static_cast<unsigned>(recording_budget.unsupported_reason()), recording_budget.unsupported_detail(),
        recording_budget.operation_type());
  }
  switch (recording_budget.status()) {
    case cc::ArxCaptureRecordingBudget::Status::kLimit: fail(mojom::Status::kLimit); return;
    case cc::ArxCaptureRecordingBudget::Status::kTimeout: fail(mojom::Status::kTimeout); return;
    case cc::ArxCaptureRecordingBudget::Status::kUnsupported: fail(mojom::Status::kUnsupported); return;
    case cc::ArxCaptureRecordingBudget::Status::kSuccess: break;
  }
  current = Geometry();
  if (!painted || !current || !current->Equals(*expected)) {
    fail(mojom::Status::kChanged);
    return;
  }
  if (base::TimeTicks::Now() >= deadline) { fail(mojom::Status::kTimeout); return; }
  auto record = recorder.finishRecordingAsPicture();
  stage = 3;
  // Capture-scoped seams admitted transient container retention during fresh
  // painting. This second pass bounds referenced resources before conversion;
  // neither policy claims a whole-renderer allocator or lifecycle-time bound.
  if (record.bytes_used() > limits->maximum_record_bytes ||
      record.total_op_count() > limits->maximum_record_ops) {
    fail(mojom::Status::kLimit);
    return;
  }
  RecordAdmission admission(*limits, deadline);
  const auto admitted = admission.Inspect(record);
  if (admitted != mojom::Status::kSuccess) {
    std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_RECORD_ADMISSION status=%u reason=%u detail=%u op=%u\n",
        static_cast<unsigned>(admitted), static_cast<unsigned>(admission.unsupported_reason()),
        admission.unsupported_detail(), admission.operation_type());
    fail(admitted); return;
  }
  stage = 4;
  auto picture = paint_preview::PaintRecordToSkPicture(
      record, &tracker, bounds, base::BindRepeating(
          &RecordAdmission::Continue, base::Unretained(&admission)));
  if (admission.status() != mojom::Status::kSuccess) {
    fail(admission.status());
    return;
  }
  if (!picture) { fail(mojom::Status::kFailed); return; }
  if (!tracker.GetPictureSerializationContext()->content_id_to_embedding_token.empty()) {
    stage = 5;
    fail(mojom::Status::kUnsupported);
    return;
  }

  paint_preview::TypefaceSerializationContext typefaces(tracker.GetTypefaceUsageMap());
  stage = 6;
  auto* image_context = tracker.GetImageSerializationContext();
  image_context->remaining_image_size = limits->maximum_serialized_bytes;
  // Finite max_decoded_image_size would allow Chromium to discard images.
  // The wrapper below instead rejects the complete result on any omission.
  auto procs = paint_preview::MakeSerialProcs(
      tracker.GetPictureSerializationContext(), &typefaces, image_context);
  Images images{Budget(limits->maximum_decoded_image_bytes),
                limits->maximum_serialized_bytes, deadline};
  procs.fImageProc = SerializeImage;
  procs.fImageCtx = &images;
  BoundedStream stream(limits->maximum_serialized_bytes);
  picture->serialize(&stream, &procs);
  if (images.status != mojom::Status::kSuccess) {
    std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_IMAGE_SERIALIZATION status=%u reason=%u\n",
        static_cast<unsigned>(images.status), images.failure);
    fail(images.status); return;
  }
  if (stream.failed() || stream.bytesWritten() == 0) {
    fail(mojom::Status::kLimit);
    return;
  }
  if (base::TimeTicks::Now() >= deadline) { fail(mojom::Status::kTimeout); return; }
  current = Geometry();
  if (!current || !current->Equals(*expected)) { fail(mojom::Status::kChanged); return; }
  std::move(callback).Run(
      mojom::Status::kSuccess, mojo_base::BigBuffer(base::span(stream.bytes())));
}

}  // namespace arx::document
