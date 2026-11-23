#include "chrome/browser/arx/capture_bridge.h"
#include "chrome/browser/arx/page_capture_bridge.h"

#import <AppKit/AppKit.h>

#include <cmath>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "components/paint_preview/arx/budget.h"
#include "components/paint_preview/arx/capture_slot.h"
#include "components/paint_preview/arx/document_capture.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "ui/gfx/codec/png_codec.h"

namespace arx {
namespace {

class Capture;
struct DocumentRequest {
  base::UnguessableToken delivery = base::UnguessableToken::Create();
  base::UnguessableToken operation;
  uint64_t request, page;
  std::string document_id;
  DocumentCaptureReply reply;
  content::WeakDocumentPtr document;
  gfx::Size viewport;
  float device_scale;
  bool was_loading;
};
std::unique_ptr<DocumentRequest>& DocumentPending() {
  static base::NoDestructor<std::unique_ptr<DocumentRequest>> pending;
  return *pending;
}
ArxCaptureStatus DocumentStatus(document::mojom::Status status) {
  switch (status) {
    case document::mojom::Status::kSuccess: return ARX_CAPTURE_SUCCESS;
    case document::mojom::Status::kUnavailable: return ARX_CAPTURE_UNAVAILABLE;
    case document::mojom::Status::kUnsupported: return ARX_CAPTURE_UNSUPPORTED;
    case document::mojom::Status::kChanged: return ARX_CAPTURE_STALE;
    case document::mojom::Status::kLimit: return ARX_CAPTURE_LIMIT;
    case document::mojom::Status::kFailed: return ARX_CAPTURE_ENCODING_FAILED;
    case document::mojom::Status::kCancelled: return ARX_CAPTURE_CANCELLED;
    case document::mojom::Status::kTimeout: return ARX_CAPTURE_TIMEOUT;
    case document::mojom::Status::kBusy: return ARX_CAPTURE_BUSY;
  }
}

std::unique_ptr<Capture>& Active() {
  static base::NoDestructor<std::unique_ptr<Capture>> capture;
  return *capture;
}

bool ValidLimits(const ArxCaptureLimits& limits) {
  return limits.maximum_dimension > 0 && limits.maximum_dimension <= 8192 &&
         limits.maximum_pixels > 0 && limits.maximum_pixels <= 16777216 &&
         limits.maximum_encoded_bytes > 0 && limits.maximum_encoded_bytes <= 67108864 &&
         limits.timeout_ms > 0 && limits.timeout_ms <= 10000;
}

bool Fits(const gfx::Size& size, const ArxCaptureLimits& limits) {
  return !size.IsEmpty() && size.width() <= static_cast<int>(limits.maximum_dimension) &&
         size.height() <= static_cast<int>(limits.maximum_dimension) &&
         static_cast<uint64_t>(size.width()) * size.height() <= limits.maximum_pixels;
}

ArxCaptureStatus Failure(content::CopyFromSurfaceError error) {
  switch (error) {
    case content::CopyFromSurfaceError::kTimeout: return ARX_CAPTURE_TIMEOUT;
    case content::CopyFromSurfaceError::kFrameGone:
    case content::CopyFromSurfaceError::kEmbeddingTokenChanged: return ARX_CAPTURE_STALE;
    default: return ARX_CAPTURE_UNSUPPORTED;
  }
}

void ReplyLater(CaptureReply reply, uint64_t request, uint64_t page, ArxCaptureStatus status) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(reply, request, page, status, nullptr));
}

// Logical completion and physical drainage are separate. Cancellation/navigation/
// timeout complete the caller, but cannot cancel a submitted compositor copy or
// PNG encoder. The global slot stays occupied until that work actually returns.
class Capture final : public content::WebContentsObserver {
 public:
  Capture(content::WebContents* contents, std::string document_id, uint64_t page,
          uint64_t request, ArxCaptureLimits limits, CaptureReply reply, bool offscreen = false)
      : WebContentsObserver(contents), offscreen_(offscreen), document_id_(std::move(document_id)),
        page_(page), request_(request), limits_(limits), reply_(reply),
        document_(contents->GetPrimaryMainFrame()->GetWeakDocumentPtr()),
        view_(contents->GetRenderWidgetHostView()), viewport_(view_->GetVisibleViewportSize()),
        pixels_(view_->GetVisibleViewportSizeDevicePx()), scale_(view_->GetDeviceScaleFactor()),
        was_loading_(contents->IsLoading()),
        deadline_(base::TimeTicks::Now() + base::Milliseconds(limits.timeout_ms)) {}

  uint64_t request() const { return request_; }

  void Start() {
    timeout_.Start(FROM_HERE, base::Milliseconds(limits_.timeout_ms),
        base::BindOnce(&Capture::Fail, weak_factory_.GetWeakPtr(), ARX_CAPTURE_TIMEOUT));
    if (!offscreen_) { Copy(); return; }
    // Hidden capture keeps the renderer producing frames without showing the
    // page; released with this object once the copy has physically returned.
    capturer_ = web_contents()->IncrementCapturerCount(gfx::Size(), /*stay_hidden=*/true,
        /*stay_awake=*/true, /*is_activity=*/false);
    WaitForSurface();
  }

  void WaitForSurface() {
    if (completed_) { Drain(); return; }
    if (web_contents()->GetRenderWidgetHostView() != view_) { Fail(ARX_CAPTURE_STALE); Drain(); return; }
    if (!view_->IsSurfaceAvailableForCopy() || view_->GetVisibleViewportSize().IsEmpty()) {
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
          base::BindOnce(&Capture::WaitForSurface, weak_factory_.GetWeakPtr()),
          base::Milliseconds(50));
      return;
    }
    viewport_ = view_->GetVisibleViewportSize();
    pixels_ = view_->GetVisibleViewportSizeDevicePx();
    scale_ = view_->GetDeviceScaleFactor();
    if (!std::isfinite(scale_) || scale_ <= 0 || !Fits(pixels_, limits_)) {
      Fail(ARX_CAPTURE_LIMIT);
      Drain();
      return;
    }
    Copy();
  }

  void Copy() {
    auto runner = base::SingleThreadTaskRunner::GetCurrentDefault();
    view_->CopyFromSurface(gfx::Rect(viewport_), pixels_, base::Milliseconds(limits_.timeout_ms),
        base::BindOnce([](scoped_refptr<base::SingleThreadTaskRunner> runner,
                         base::WeakPtr<Capture> capture,
                         const content::CopyFromSurfaceResult& result) {
          // The copy callback may arrive on another sequence. SkBitmap retains
          // the immutable pixel ref; no WebContents/WeakDocumentPtr is touched here.
          SkBitmap bitmap;
          ArxCaptureStatus status = ARX_CAPTURE_SUCCESS;
          if (result.has_value()) bitmap = result->bitmap;
          else status = Failure(result.error());
          runner->PostTask(FROM_HERE, base::BindOnce(&Capture::Copied, capture, status, bitmap));
        }, std::move(runner), weak_factory_.GetWeakPtr()));
  }

  void Fail(ArxCaptureStatus status) {
    if (completed_) return;
    completed_ = true;
    timeout_.Stop();
    // Observer stacks may still be using WebContents. Never call Swift there.
    ReplyLater(reply_, request_, page_, status);
  }

  void DidStartNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsInPrimaryMainFrame()) Fail(ARX_CAPTURE_STALE);
  }

  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsInPrimaryMainFrame() && navigation->HasCommitted()) Fail(ARX_CAPTURE_STALE);
  }

  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override { Fail(ARX_CAPTURE_STALE); }
  void PrimaryPageWillBeDeactivated(content::Page&) override { Fail(ARX_CAPTURE_STALE); }
  void CaptureTargetChanged() override { Fail(ARX_CAPTURE_STALE); }
  // Chromium reports every visual-property update here, not only resizes: a
  // hidden page shown for the capturer gets a new surface ID, and an
  // ordered-out window takes another display's screen info. An offscreen copy
  // compares the actual geometry when it returns and copies again if it moved.
  void PrimaryMainFrameWasResized(bool) override {
    if (!offscreen_) Fail(ARX_CAPTURE_STALE);
  }
  void OnVisibilityWillChange(content::Visibility visibility) override {
    if (!offscreen_ && visibility != content::Visibility::VISIBLE) Fail(ARX_CAPTURE_STALE);
  }
  void WebContentsDestroyed() override { Fail(ARX_CAPTURE_STALE); }

 private:
  bool IsCurrent() const {
    auto* contents = web_contents();
    auto* document = document_.AsRenderFrameHostIfValid();
    if (!contents || !document || contents->GetPrimaryMainFrame() != document ||
        contents->GetRenderWidgetHostView() != view_) return false;
    return (offscreen_ || view_->IsShowing()) && view_->GetVisibleViewportSize() == viewport_ &&
           view_->GetVisibleViewportSizeDevicePx() == pixels_ &&
           view_->GetDeviceScaleFactor() == scale_;
  }

  void Drain() {
    // Deleting on the next UI turn also protects synchronous copy callbacks.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce([](uint64_t request) {
          if (Active() && Active()->request() == request) Active().reset();
        }, request_));
  }

  // Offscreen geometry may still settle and a page that just became hidden may
  // hand back its evicted surface; its next frame follows the hidden capturer.
  // Only the document has to stay the same, so copy again while time allows.
  bool CopyAgain() {
    auto* document = document_.AsRenderFrameHostIfValid();
    if (!offscreen_ || !document || !web_contents() ||
        web_contents()->GetPrimaryMainFrame() != document ||
        base::TimeTicks::Now() + base::Milliseconds(150) >= deadline_) return false;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
        base::BindOnce(&Capture::WaitForSurface, weak_factory_.GetWeakPtr()),
        base::Milliseconds(100));
    return true;
  }

  void Copied(ArxCaptureStatus status, SkBitmap bitmap) {
    if (completed_) { Drain(); return; }
    if (base::TimeTicks::Now() >= deadline_) { Fail(ARX_CAPTURE_TIMEOUT); Drain(); return; }
    if (!IsCurrent() || status != ARX_CAPTURE_SUCCESS || bitmap.drawsNothing() ||
        bitmap.width() != pixels_.width() || bitmap.height() != pixels_.height()) {
      if (CopyAgain()) return;
      Fail(!IsCurrent() ? ARX_CAPTURE_STALE
           : status != ARX_CAPTURE_SUCCESS ? status : ARX_CAPTURE_UNSUPPORTED);
      Drain();
      return;
    }
    // Geometry was bounded before copy and checked again before encoding.
    base::ThreadPool::PostTaskAndReplyWithResult(FROM_HERE,
        {base::TaskPriority::USER_VISIBLE},
        base::BindOnce([](SkBitmap bitmap) {
          return gfx::PNGCodec::EncodeBGRASkBitmap(bitmap, false);
        }, std::move(bitmap)),
        base::BindOnce(&Capture::Encoded, weak_factory_.GetWeakPtr()));
  }

  void Encoded(std::optional<std::vector<uint8_t>> png) {
    if (completed_) { Drain(); return; }
    if (base::TimeTicks::Now() >= deadline_) { Fail(ARX_CAPTURE_TIMEOUT); Drain(); return; }
    if (!IsCurrent()) {
      if (CopyAgain()) return;
      Fail(ARX_CAPTURE_STALE);
      Drain();
      return;
    }
    if (!png || png->empty()) { Fail(ARX_CAPTURE_ENCODING_FAILED); Drain(); return; }
    if (png->size() > limits_.maximum_encoded_bytes) { Fail(ARX_CAPTURE_LIMIT); Drain(); return; }
    timeout_.Stop();
    completed_ = true;
    const ArxCaptureSnapshot snapshot = {
        document_id_.c_str(), png->data(), png->size(),
        static_cast<uint32_t>(pixels_.width()), static_cast<uint32_t>(pixels_.height()),
        static_cast<double>(viewport_.width()), static_cast<double>(viewport_.height()),
        scale_, was_loading_};
    // Already on the UI sequence outside an observer stack. Swift copies all
    // borrowed data before returning. Protected surfaces may be blacked out by viz.
    reply_(request_, page_, ARX_CAPTURE_SUCCESS, &snapshot);
    Drain();
  }

  const capture::Lease physical_slot_;
  const bool offscreen_;

 public:
  // A detached page renders only inside some window. An ordered-out window
  // hosts its root view for the copy and returns it detached afterwards.
  void HostDetached(NSView* root) {
    // On the main screen, so the page gets that display's scale; never ordered in.
    host_window_ = [[NSWindow alloc] initWithContentRect:root.frame
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO
                                                  screen:NSScreen.mainScreen];
    host_window_.releasedWhenClosed = NO;
    hosted_root_ = root;
    [host_window_.contentView addSubview:root];
  }
  ~Capture() override {
    if (!hosted_root_) return;
    [hosted_root_ removeFromSuperview];
    [host_window_ close];
  }

 private:
  NSWindow* __strong host_window_ = nil;
  NSView* __strong hosted_root_ = nil;
  const std::string document_id_;
  const uint64_t page_, request_;
  const ArxCaptureLimits limits_;
  const CaptureReply reply_;
  const content::WeakDocumentPtr document_;
  content::RenderWidgetHostView* const view_;
  gfx::Size viewport_, pixels_;
  float scale_;
  const bool was_loading_;
  const base::TimeTicks deadline_;
  bool completed_ = false;
  base::ScopedClosureRunner capturer_;
  base::OneShotTimer timeout_;
  base::WeakPtrFactory<Capture> weak_factory_{this};
};

}  // namespace

void CaptureViewport(content::WebContents* contents, const std::string& document_id,
                     uint64_t page, uint64_t request, ArxCaptureLimits limits,
                     CaptureReply reply) {
  if (!ValidLimits(limits)) { ReplyLater(reply, request, page, ARX_CAPTURE_INVALID); return; }
  if (capture::Busy()) { ReplyLater(reply, request, page, ARX_CAPTURE_BUSY); return; }
  auto* view = contents ? contents->GetRenderWidgetHostView() : nullptr;
  if (!view || !contents->GetPrimaryMainFrame() || !view->IsShowing() ||
      !view->IsSurfaceAvailableForCopy()) {
    ReplyLater(reply, request, page, ARX_CAPTURE_UNAVAILABLE);
    return;
  }
  const auto viewport = view->GetVisibleViewportSize();
  const auto pixels = view->GetVisibleViewportSizeDevicePx();
  const auto scale = view->GetDeviceScaleFactor();
  if (viewport.IsEmpty() || !std::isfinite(scale) || scale <= 0 || !Fits(pixels, limits)) {
    ReplyLater(reply, request, page, ARX_CAPTURE_LIMIT);
    return;
  }
  Active() = std::make_unique<Capture>(contents, document_id, page, request, limits, reply);
  Active()->Start();
}

void CaptureOffscreen(content::WebContents* contents, const std::string& document_id,
                      uint64_t page, uint64_t request, ArxCaptureLimits limits,
                      CaptureReply reply) {
  if (!ValidLimits(limits)) { ReplyLater(reply, request, page, ARX_CAPTURE_INVALID); return; }
  auto* view = contents ? contents->GetRenderWidgetHostView() : nullptr;
  // A never-attached page still reports showing; only a visible window counts.
  NSView* native = contents ? contents->GetNativeView().GetNativeNSView() : nil;
  if (view && view->IsShowing() && native.window.isVisible) {
    CaptureViewport(contents, document_id, page, request, limits, reply);
    return;
  }
  if (capture::Busy()) { ReplyLater(reply, request, page, ARX_CAPTURE_BUSY); return; }
  if (!view || !contents->GetPrimaryMainFrame() || contents->IsCrashed() ||
      contents->GetBrowserContext()->IsOffTheRecord()) {
    ReplyLater(reply, request, page, ARX_CAPTURE_UNAVAILABLE);
    return;
  }
  Active() = std::make_unique<Capture>(contents, document_id, page, request, limits, reply,
                                       /*offscreen=*/true);
  // A detached page that was never laid out gets an ordinary window's size.
  if (native && !native.window) {
    NSView* root = native;
    while (root.superview) root = root.superview;
    if (NSIsEmptyRect(root.frame)) [root setFrame:NSMakeRect(0, 0, 1280, 800)];
    if (NSIsEmptyRect(native.frame)) [native setFrame:root.bounds];
    Active()->HostDetached(root);
  }
  Active()->Start();
}

void CaptureDocument(content::WebContents* contents, const std::string& document_id,
                     uint64_t page, uint64_t request, ArxCaptureLimits limits,
                     DocumentCaptureReply reply) {
  auto fail = [&](ArxCaptureStatus status) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(reply, request, page, status, nullptr));
  };
  if (!ValidLimits(limits)) { fail(ARX_CAPTURE_INVALID); return; }
  if (capture::Busy() || DocumentPending()) { fail(ARX_CAPTURE_BUSY); return; }
  auto* view = contents ? contents->GetRenderWidgetHostView() : nullptr;
  auto* frame = contents ? contents->GetPrimaryMainFrame() : nullptr;
  if (!frame || !view || !view->IsShowing()) { fail(ARX_CAPTURE_UNAVAILABLE); return; }
  auto pending = std::make_unique<DocumentRequest>();
  pending->request = request; pending->page = page; pending->document_id = document_id;
  pending->reply = reply; pending->document = frame->GetWeakDocumentPtr();
  pending->viewport = view->GetVisibleViewportSize();
  pending->device_scale = view->GetDeviceScaleFactor(); pending->was_loading = contents->IsLoading();
  const auto delivery = pending->delivery;
  auto native = document::mojom::Limits::New();
  native->maximum_dimension = limits.maximum_dimension;
  native->maximum_pixels = limits.maximum_pixels;
  native->maximum_record_bytes = document::kMaximumRecordBytes;
  native->maximum_record_ops = document::kMaximumRecordOps;
  native->maximum_decoded_image_bytes = document::kMaximumDecodedImageBytes;
  native->maximum_serialized_bytes = document::kMaximumSerializedBytes;
  native->maximum_png_bytes = limits.maximum_encoded_bytes;
  native->timeout_ms = limits.timeout_ms;
  DocumentPending() = std::move(pending);
  DocumentPending()->operation = document::CaptureDocumentPrototype(contents, std::move(native),
      base::BindOnce([](base::UnguessableToken delivery, document::Result result) {
        if (!DocumentPending() || DocumentPending()->delivery != delivery) return;
        auto pending = std::move(DocumentPending());
        auto status = DocumentStatus(result.status);
        auto* frame = pending->document.AsRenderFrameHostIfValid();
        auto* contents = frame ? content::WebContents::FromRenderFrameHost(frame) : nullptr;
        auto* view = contents ? contents->GetRenderWidgetHostView() : nullptr;
        if (status == ARX_CAPTURE_SUCCESS && (!view || contents->GetPrimaryMainFrame() != frame ||
            !view->IsShowing() || view->GetVisibleViewportSize() != pending->viewport ||
            view->GetDeviceScaleFactor() != pending->device_scale)) status = ARX_CAPTURE_STALE;
        if (status != ARX_CAPTURE_SUCCESS || !result.geometry || result.png.empty()) {
          pending->reply(pending->request, pending->page,
              status == ARX_CAPTURE_SUCCESS ? ARX_CAPTURE_ENCODING_FAILED : status, nullptr);
          return;
        }
        const auto& g = *result.geometry;
        const ArxDocumentCaptureSnapshot snapshot = {
          pending->document_id.c_str(), result.png.data(), result.png.size(),
          static_cast<uint32_t>(g.document_rect.width()), static_cast<uint32_t>(g.document_rect.height()),
          static_cast<double>(g.document_rect.x()), static_cast<double>(g.document_rect.y()),
          static_cast<double>(g.document_rect.width()), static_cast<double>(g.document_rect.height()),
          static_cast<double>(g.visible_rect.x()), static_cast<double>(g.visible_rect.y()),
          static_cast<double>(g.visible_rect.width()), static_cast<double>(g.visible_rect.height()),
          g.scroll.x(), g.scroll.y(), g.zoom_level, g.page_scale,
          static_cast<double>(pending->viewport.width()), static_cast<double>(pending->viewport.height()),
          pending->device_scale, 1, result.was_loading};
        pending->reply(pending->request, pending->page, ARX_CAPTURE_SUCCESS, &snapshot);
      }, delivery));
}

void CancelDocumentCapture(uint64_t request) {
  if (DocumentPending() && DocumentPending()->request == request)
    document::CancelDocumentPrototype(DocumentPending()->operation);
}

void CancelCapture(uint64_t request) {
  if (Active() && Active()->request() == request) Active()->Fail(ARX_CAPTURE_CANCELLED);
}

bool CapturesPage(content::WebContents* contents) {
  if (!contents) return false;
  if (Active() && Active()->web_contents() == contents) return true;
  if (CapturesWholePage(contents)) return true;
  if (!DocumentPending()) return false;
  auto* frame = DocumentPending()->document.AsRenderFrameHostIfValid();
  return frame && content::WebContents::FromRenderFrameHost(frame) == contents;
}

bool CaptureInFlight() {
  return capture::Busy() || Active() || DocumentPending();
}

void StopAllCaptures() {
  // Shutdown cannot restart. Drop weak callbacks; pending copy/encoding owns no
  // page and can release its bounded bitmap when the worker eventually returns.
  Active().reset();
  StopWholePageCaptures();
  document::StopDocumentPrototype();
  DocumentPending().reset();
}

}  // namespace arx
