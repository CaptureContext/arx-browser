#include "components/paint_preview/arx/document_capture.h"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <memory>
#include <optional>
#include <utility>

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "components/paint_preview/arx/budget.h"
#include "components/paint_preview/arx/capture_slot.h"
#include "components/paint_preview/arx/png_encoding.h"
#include "components/paint_preview/browser/compositor_utils.h"
#include "components/paint_preview/common/proto/paint_preview.pb.h"
#include "components/paint_preview/common/version.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "mojo/public/cpp/base/proto_wrapper.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "third_party/skia/include/core/SkBitmap.h"

namespace arx::document {
namespace {

namespace preview = paint_preview::mojom;
using Compositor = preview::PaintPreviewCompositor;
class Operation;

void InvalidLimits(const mojom::Limits* limits) {
  if (!limits) {
    std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_BROWSER_INVALID_LIMITS present=0\n");
    return;
  }
  std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_BROWSER_INVALID_LIMITS present=1 dimension=%u pixels=%llu "
      "record_bytes=%llu record_ops=%llu decoded_bytes=%llu serialized_bytes=%llu png_bytes=%llu timeout_ms=%u\n",
      limits->maximum_dimension, static_cast<unsigned long long>(limits->maximum_pixels),
      static_cast<unsigned long long>(limits->maximum_record_bytes),
      static_cast<unsigned long long>(limits->maximum_record_ops),
      static_cast<unsigned long long>(limits->maximum_decoded_image_bytes),
      static_cast<unsigned long long>(limits->maximum_serialized_bytes),
      static_cast<unsigned long long>(limits->maximum_png_bytes), limits->timeout_ms);
}

std::unique_ptr<Operation>& Active() {
  static base::NoDestructor<std::unique_ptr<Operation>> active;
  return *active;
}

void Reply(base::OnceCallback<void(Result)> callback, Result result) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(std::move(callback), std::move(result)));
}

class Operation final : public content::WebContentsObserver {
 public:
  Operation(content::WebContents* contents, mojom::LimitsPtr limits,
            base::OnceCallback<void(base::OnceClosure)> before_record,
            base::OnceCallback<void(Result)> callback)
      : WebContentsObserver(contents), limits_(std::move(limits)),
        callback_(std::move(callback)), before_record_(std::move(before_record)),
        document_(contents->GetPrimaryMainFrame()->GetWeakDocumentPtr()),
        embedding_(*contents->GetPrimaryMainFrame()->GetEmbeddingToken()),
        view_(contents->GetRenderWidgetHostView()),
        viewport_(view_->GetVisibleViewportSize()),
        device_scale_(view_->GetDeviceScaleFactor()),
        was_loading_(contents->IsLoading()),
        deadline_(base::TimeTicks::Now() + base::Milliseconds(limits_->timeout_ms)),
        service_(nullptr, base::OnTaskRunnerDeleter(nullptr)),
        compositor_(nullptr, base::OnTaskRunnerDeleter(nullptr)) {}

  const base::UnguessableToken& id() const { return id_; }

  void Start() {
    timeout_.Start(FROM_HERE, base::Milliseconds(limits_->timeout_ms),
        base::BindOnce(&Operation::Fail, weak_factory_.GetWeakPtr(), mojom::Status::kTimeout));
    document_.AsRenderFrameHostIfValid()->GetRemoteAssociatedInterfaces()->GetInterface(&recorder_);
    recorder_.set_disconnect_handler(
        base::BindOnce(&Operation::Disconnected, weak_factory_.GetWeakPtr()));
    recorder_->Inspect(base::BindOnce(&Operation::Inspected, weak_factory_.GetWeakPtr()));
  }

  void Fail(mojom::Status status) {
    if (!callback_) return;
    timeout_.Stop();
    cancelled_->store(true);
    Reply(std::move(callback_), {status, nullptr, {}});
    if (waiting_before_record_) Drain();
    // Do not reset the remote or free the physical slot: a renderer request or
    // compositor/encoder may still own work. The stage callback drains it.
  }

  void DidStartNavigation(content::NavigationHandle*) override { Fail(mojom::Status::kChanged); }
  void RenderFrameDeleted(content::RenderFrameHost*) override { Fail(mojom::Status::kChanged); }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override { Fail(mojom::Status::kChanged); }
  void PrimaryPageWillBeDeactivated(content::Page&) override { Fail(mojom::Status::kChanged); }
  void PrimaryMainFrameWasResized(bool) override { Fail(mojom::Status::kChanged); }
  void CaptureTargetChanged() override { Fail(mojom::Status::kChanged); }
  void OnVisibilityWillChange(content::Visibility visibility) override {
    if (visibility != content::Visibility::VISIBLE) Fail(mojom::Status::kChanged);
  }
  void WebContentsDestroyed() override { Fail(mojom::Status::kChanged); }

 private:
  bool Current() const {
    auto* contents = web_contents();
    auto* frame = document_.AsRenderFrameHostIfValid();
    if (!contents || !frame || contents->GetPrimaryMainFrame() != frame ||
        frame->GetEmbeddingToken() != embedding_ || contents->GetRenderWidgetHostView() != view_) {
      return false;
    }
    size_t frames = 0;
    frame->ForEachRenderFrameHost([&frames](content::RenderFrameHost*) { ++frames; });
    return frames == 1 && view_->IsShowing() && view_->GetVisibleViewportSize() == viewport_ &&
           view_->GetDeviceScaleFactor() == device_scale_;
  }

  // Called only after the current stage has returned. Logical completion never
  // by itself releases this slot. An unresponsive stage remains busy, not an
  // opportunity to start unlimited replacement captures.
  bool Continue() {
    if (!callback_) { Drain(); return false; }
    if (base::TimeTicks::Now() >= deadline_) {
      Fail(mojom::Status::kTimeout);
      Drain();
      return false;
    }
    if (!Current()) { Fail(mojom::Status::kChanged); Drain(); return false; }
    return true;
  }

  void Drain() {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce([](base::UnguessableToken id) {
          if (Active() && Active()->id() == id) Active().reset();
        }, id_));
  }

  void Disconnected() {
    Fail(mojom::Status::kUnavailable);
    // A renderer disconnect proves its request cannot return; after recording
    // it says nothing about the separately owned compositor/encoder stage.
    if (renderer_pending_) Drain();
  }

  void Inspected(mojom::GeometryPtr geometry) {
    if (!Continue()) return;
    if (!geometry) {
      std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_BROWSER_INSPECT_NULL\n");
      Fail(mojom::Status::kUnsupported); Drain(); return;
    }
    const auto bounds = geometry->document_rect;
    if (!FitsExtent(bounds.x(), bounds.y(), bounds.width(), bounds.height(), *limits_)) {
      std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_BROWSER_EXTENT_LIMIT rect=%d,%d,%d,%d visible=%d,%d,%d,%d "
          "scroll=%g,%g zoom=%g page_scale=%g device_scale=%g dimension=%u pixels=%llu\n",
          bounds.x(), bounds.y(), bounds.width(), bounds.height(),
          geometry->visible_rect.x(), geometry->visible_rect.y(), geometry->visible_rect.width(), geometry->visible_rect.height(),
          geometry->scroll.x(), geometry->scroll.y(), geometry->zoom_level, geometry->page_scale, device_scale_,
          limits_->maximum_dimension, static_cast<unsigned long long>(limits_->maximum_pixels));
      Fail(mojom::Status::kLimit);
      Drain();
      return;
    }
    geometry_ = std::move(geometry);
    renderer_pending_ = false;
    if (before_record_) {
      waiting_before_record_ = true;
      std::move(before_record_).Run(base::BindOnce(
          &Operation::RecordCurrent, weak_factory_.GetWeakPtr()));
      return;
    }
    RecordCurrent();
  }

  void RecordCurrent() {
    waiting_before_record_ = false;
    if (!Continue()) return;
    renderer_pending_ = true;
    auto renderer_limits = limits_.Clone();
    renderer_limits->timeout_ms = std::max<int64_t>(
        1, (deadline_ - base::TimeTicks::Now()).InMilliseconds());
    recorder_->Record(geometry_.Clone(), std::move(renderer_limits),
        base::BindOnce(&Operation::Recorded, weak_factory_.GetWeakPtr()));
  }

  void Recorded(mojom::Status status, std::optional<mojo_base::BigBuffer> recording) {
    renderer_pending_ = false;
    if (!Continue()) return;
    if (status != mojom::Status::kSuccess || !recording || recording->size() == 0 ||
        recording->size() > limits_->maximum_serialized_bytes) {
      std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_BROWSER_RECORD_FAILED status=%u\n",
                   static_cast<unsigned>(status));
      Fail(status == mojom::Status::kSuccess ? mojom::Status::kFailed : status);
      Drain();
      return;
    }
    auto request = preview::PaintPreviewBeginCompositeRequest::New();
    request->arx_document_deadline = deadline_;
    request->arx_document_width = geometry_->document_rect.width();
    request->arx_document_height = geometry_->document_rect.height();
    paint_preview::PaintPreviewProto proto;
    proto.mutable_metadata()->set_url(web_contents()->GetLastCommittedURL().spec());
    proto.mutable_metadata()->set_version(paint_preview::kPaintPreviewVersion);
    auto* root = proto.mutable_root_frame();
    root->set_embedding_token_high(embedding_.GetHighForSerialization());
    root->set_embedding_token_low(embedding_.GetLowForSerialization());
    root->set_is_main_frame(true);
    request->preview = mojo_base::ProtoWrapper(std::move(proto));
    request->recording_map.emplace(embedding_, paint_preview::SerializedRecording(std::move(*recording)));
    composite_request_ = std::move(request);
    service_ = paint_preview::StartCompositorService(
        base::BindOnce(&Operation::CompositorDisconnected, weak_factory_.GetWeakPtr()));
    compositor_ = service_->CreateCompositor(
        base::BindOnce(&Operation::Connected, weak_factory_.GetWeakPtr()));
    compositor_->SetDisconnectHandler(
        base::BindOnce(&Operation::CompositorDisconnected, weak_factory_.GetWeakPtr()));
  }

  void CompositorDisconnected() {
    Fail(mojom::Status::kUnavailable);
    if (!encoder_pending_) Drain();
  }

  void Connected() {
    if (!Continue()) return;
    compositor_->BeginMainFrameComposite(std::move(composite_request_),
        base::BindOnce(&Operation::Composed, weak_factory_.GetWeakPtr()));
  }

  void Composed(Compositor::BeginCompositeStatus status,
                preview::PaintPreviewBeginCompositeResponsePtr response) {
    if (!Continue()) return;
    if (status != Compositor::BeginCompositeStatus::kSuccess || !response ||
        response->root_frame_guid != embedding_ || response->frames.size() != 1 ||
        !response->frames.contains(embedding_) ||
        response->frames.at(embedding_)->scroll_extents != geometry_->document_rect.size()) {
      Fail(mojom::Status::kFailed);
      Drain();
      return;
    }
    compositor_->BitmapForMainFrame(gfx::Rect(geometry_->document_rect.size()), 1.0f,
        base::BindOnce(&Operation::Rasterized, weak_factory_.GetWeakPtr()));
  }

  void Rasterized(Compositor::BitmapStatus status, const SkBitmap& bitmap) {
    if (!Continue()) return;
    if (status == Compositor::BitmapStatus::kArxLimit || status == Compositor::BitmapStatus::kArxTimeout) {
      Fail(status == Compositor::BitmapStatus::kArxLimit ? mojom::Status::kLimit : mojom::Status::kTimeout);
      Drain();
      return;
    }
    if (status != Compositor::BitmapStatus::kSuccess || bitmap.drawsNothing() ||
        bitmap.colorType() != kN32_SkColorType ||
        bitmap.width() != geometry_->document_rect.width() ||
        bitmap.height() != geometry_->document_rect.height()) {
      Fail(mojom::Status::kFailed);
      Drain();
      return;
    }
    encoder_pending_ = true;
    base::ThreadPool::PostTaskAndReplyWithResult(FROM_HERE,
        {base::TaskPriority::USER_VISIBLE},
        base::BindOnce([](SkBitmap image, mojom::LimitsPtr limits,
                          base::TimeTicks deadline, std::shared_ptr<std::atomic<bool>> cancelled) {
          return EncodeDocumentPNG(image, *limits, deadline, *cancelled);
        }, bitmap, limits_.Clone(), deadline_, cancelled_),
        base::BindOnce(&Operation::Encoded, weak_factory_.GetWeakPtr()));
  }

  void Encoded(EncodedPNG png) {
    encoder_pending_ = false;
    if (!Continue()) return;
    if (png.status != mojom::Status::kSuccess || png.bytes.empty() ||
        png.bytes.size() > limits_->maximum_png_bytes) {
      Fail(png.status == mojom::Status::kSuccess ? mojom::Status::kFailed : png.status);
      Drain();
      return;
    }
    png_ = std::move(png.bytes);
    renderer_pending_ = true;
    recorder_->Inspect(base::BindOnce(&Operation::Validated, weak_factory_.GetWeakPtr()));
  }

  void Validated(mojom::GeometryPtr geometry) {
    renderer_pending_ = false;
    if (!Continue()) return;
    if (!geometry || !geometry->Equals(*geometry_)) {
      Fail(mojom::Status::kChanged);
      Drain();
      return;
    }
    timeout_.Stop();
    Reply(std::move(callback_), {mojom::Status::kSuccess, std::move(geometry_), std::move(png_), was_loading_});
    Drain();
  }

  const capture::Lease physical_slot_;
  const base::UnguessableToken id_ = base::UnguessableToken::Create();
  mojom::LimitsPtr limits_;
  base::OnceCallback<void(Result)> callback_;
  base::OnceCallback<void(base::OnceClosure)> before_record_;
  bool waiting_before_record_ = false;
  content::WeakDocumentPtr document_;
  const base::UnguessableToken embedding_;
  content::RenderWidgetHostView* const view_;
  const gfx::Size viewport_;
  const float device_scale_;
  const bool was_loading_;
  const base::TimeTicks deadline_;
  mojom::GeometryPtr geometry_;
  mojo::AssociatedRemote<mojom::DocumentRecorder> recorder_;
  preview::PaintPreviewBeginCompositeRequestPtr composite_request_;
  std::unique_ptr<paint_preview::PaintPreviewCompositorService, base::OnTaskRunnerDeleter> service_;
  std::unique_ptr<paint_preview::PaintPreviewCompositorClient, base::OnTaskRunnerDeleter> compositor_;
  std::vector<uint8_t> png_;
  const std::shared_ptr<std::atomic<bool>> cancelled_ = std::make_shared<std::atomic<bool>>(false);
  bool renderer_pending_ = true;
  bool encoder_pending_ = false;
  base::OneShotTimer timeout_;
  base::WeakPtrFactory<Operation> weak_factory_{this};
};

}  // namespace

base::UnguessableToken CaptureDocumentPrototype(
    content::WebContents* contents, mojom::LimitsPtr limits,
    base::OnceCallback<void(Result)> callback) {
  return CaptureDocumentPrototypeForTesting(contents, std::move(limits), {}, std::move(callback));
}

base::UnguessableToken CaptureDocumentPrototypeForTesting(
    content::WebContents* contents, mojom::LimitsPtr limits,
    base::OnceCallback<void(base::OnceClosure)> before_record,
    base::OnceCallback<void(Result)> callback) {
  if (capture::Busy()) { Reply(std::move(callback), {mojom::Status::kBusy, nullptr, {}}); return {}; }
  if (!limits || !ValidLimits(*limits)) {
    InvalidLimits(limits.get());
    Reply(std::move(callback), {mojom::Status::kLimit, nullptr, {}});
    return {};
  }
  auto* frame = contents ? contents->GetPrimaryMainFrame() : nullptr;
  auto* view = contents ? contents->GetRenderWidgetHostView() : nullptr;
  if (!frame || !frame->GetEmbeddingToken() || !view || !view->IsShowing()) {
    Reply(std::move(callback), {mojom::Status::kUnavailable, nullptr, {}});
    return {};
  }
  size_t initial_frames = 0;
  frame->ForEachRenderFrameHost([&initial_frames](content::RenderFrameHost*) { ++initial_frames; });
  if (initial_frames != 1) {
    std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_INITIAL_FRAME_TREE_UNSUPPORTED frames=%zu\n", initial_frames);
    Reply(std::move(callback), {mojom::Status::kUnsupported, nullptr, {}});
    return {};
  }
  Active() = std::make_unique<Operation>(contents, std::move(limits), std::move(before_record), std::move(callback));
  const auto id = Active()->id();
  Active()->Start();
  return id;
}

void CancelDocumentPrototype(const base::UnguessableToken& operation) {
  if (Active() && Active()->id() == operation) Active()->Fail(mojom::Status::kCancelled);
}

void StopDocumentPrototype() {
  // Final runtime shutdown only; do not use this as a retry/reset mechanism.
  if (Active()) Active()->Fail(mojom::Status::kCancelled);
  Active().reset();
}

}  // namespace arx::document
