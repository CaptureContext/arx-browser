#include "chrome/browser/arx/page_capture_bridge.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iterator>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/base64.h"
#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/browser/arx/capture_bridge.h"
#include "chrome/browser/arx/devtools_bridge.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "components/paint_preview/arx/capture_slot.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/host_zoom_map.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "ui/gfx/geometry/size.h"
#include "url/gurl.h"

namespace arx {
namespace {

// The largest texture side Apple GPUs take; a taller page is cut here.
constexpr uint32_t kMaximumDimension = 16384;
constexpr uint64_t kMaximumPixels = 67108864;
constexpr uint64_t kMaximumEncodedBytes = 67108864;
constexpr uint32_t kMaximumTimeoutMs = 30000;

bool ValidLimits(const ArxPageCaptureLimits& limits) {
  return limits.maximum_dimension > 0 && limits.maximum_dimension <= kMaximumDimension &&
         limits.maximum_pixels > 0 && limits.maximum_pixels <= kMaximumPixels &&
         limits.maximum_encoded_bytes > 0 && limits.maximum_encoded_bytes <= kMaximumEncodedBytes &&
         limits.timeout_ms > 0 && limits.timeout_ms <= kMaximumTimeoutMs;
}

void ReplyLater(ArxPageCaptureCallback done, void* context, uint64_t request,
                ArxCaptureStatus status) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
      base::BindOnce(done, context, request, status, nullptr));
}

// The screenshot reply, decoded off the UI sequence: it carries the whole PNG as base64.
struct Screenshot {
  // Whether the message was the reply to the screenshot command at all.
  bool is_reply = false;
  ArxCaptureStatus status = ARX_CAPTURE_UNSUPPORTED;
  std::vector<uint8_t> png;
  uint32_t width = 0, height = 0;
};

// A PNG starts with its signature, then IHDR: width and height, big-endian, at 16 and 20.
bool PNGSize(const std::vector<uint8_t>& png, uint32_t* width, uint32_t* height) {
  static constexpr uint8_t kSignature[] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
  if (png.size() < 24 || !std::equal(std::begin(kSignature), std::end(kSignature), png.begin()) ||
      std::memcmp(png.data() + 12, "IHDR", 4) != 0) return false;
  auto read = [&png](size_t at) {
    return (static_cast<uint32_t>(png[at]) << 24) | (static_cast<uint32_t>(png[at + 1]) << 16) |
           (static_cast<uint32_t>(png[at + 2]) << 8) | static_cast<uint32_t>(png[at + 3]);
  };
  *width = read(16);
  *height = read(20);
  return *width > 0 && *height > 0;
}

Screenshot Decode(std::string message, int id, uint64_t maximum_bytes) {
  Screenshot result;
  std::optional<base::DictValue> value = base::JSONReader::ReadDict(message, base::JSON_PARSE_RFC);
  if (!value) return result;
  std::optional<int> reply = value->FindInt("id");
  if (!reply || *reply != id) return result;
  result.is_reply = true;
  // An error reply ("Unable to capture screenshot") has no data.
  const std::string* data = value->FindStringByDottedPath("result.data");
  if (!data || data->empty()) return result;
  // Base64 is 4 characters for 3 bytes: refuse an oversized image before decoding it.
  if (data->size() / 4 * 3 > maximum_bytes + 3) {
    result.status = ARX_CAPTURE_LIMIT;
    return result;
  }
  std::optional<std::vector<uint8_t>> png = base::Base64Decode(*data);
  if (!png || png->empty()) {
    result.status = ARX_CAPTURE_ENCODING_FAILED;
    return result;
  }
  if (png->size() > maximum_bytes) {
    result.status = ARX_CAPTURE_LIMIT;
    return result;
  }
  if (!PNGSize(*png, &result.width, &result.height)) {
    result.status = ARX_CAPTURE_ENCODING_FAILED;
    return result;
  }
  result.status = ARX_CAPTURE_SUCCESS;
  result.png = std::move(*png);
  return result;
}

class WholePageCapture;

std::unique_ptr<WholePageCapture>& Active() {
  static base::NoDestructor<std::unique_ptr<WholePageCapture>> capture;
  return *capture;
}

// One capture through Arx's own DevTools protocol session, holding the engine's
// one capture slot. Like the viewport capture, logical completion and physical
// drainage are separate: a canceled or timed-out capture answers the caller at
// once, but once its screenshot is out it keeps the slot and the session until
// that screenshot returns, because Chromium puts the page back to its own size
// just before it replies. Detaching earlier would leave the page laid out at its
// whole height.
class WholePageCapture final : public content::DevToolsAgentHostClient,
                               public content::WebContentsObserver {
 public:
  WholePageCapture(content::WebContents* contents, std::string document_id, uint64_t request,
                   ArxPageCaptureLimits limits, ArxPageCaptureCallback done, void* context)
      : WebContentsObserver(contents), document_id_(std::move(document_id)), request_(request),
        limits_(limits), done_(done), context_(context),
        document_(contents->GetPrimaryMainFrame()->GetWeakDocumentPtr()),
        view_(contents->GetRenderWidgetHostView()), viewport_(view_->GetVisibleViewportSize()),
        container_(contents->GetContainerBounds().size()),
        scale_(view_->GetDeviceScaleFactor()),
        zoom_level_(content::HostZoomMap::GetZoomLevel(contents)),
        zoom_(blink::ZoomLevelToZoomFactor(zoom_level_)), was_loading_(contents->IsLoading()),
        host_(content::DevToolsAgentHost::GetOrCreateFor(contents)) {}

  ~WholePageCapture() override {
    RestoreClipping();
    if (host_ && attached_) host_->DetachClient(this);
  }

  uint64_t request() const { return request_; }

  void Start() {
    timeout_.Start(FROM_HERE, base::Milliseconds(limits_.timeout_ms),
        base::BindOnce(&WholePageCapture::Complete, weak_factory_.GetWeakPtr(),
                       ARX_CAPTURE_TIMEOUT));
    attached_ = host_ && host_->AttachClient(this);
    if (!attached_) {
      Complete(ARX_CAPTURE_UNAVAILABLE);
      Drain();
      return;
    }
    Send("Page.getLayoutMetrics", base::DictValue(), &metrics_id_);
  }

  // The caller hears once; Chromium's work may still be out. Only a screenshot
  // in flight keeps the slot: before it, nothing was resized, and a renderer
  // that never answers Page.getLayoutMetrics mustn't hold every tab's captures.
  void Complete(ArxCaptureStatus status) {
    if (completed_) return;
    completed_ = true;
    timeout_.Stop();
    // Never call Swift inside an observer or a DevTools dispatch stack.
    ReplyLater(done_, context_, request_, status);
    // With a screenshot out, the session stays until Chromium has put the page's
    // size and preferences back: detaching sooner would leave them changed. Only
    // a widget that's gone (Lost) or a closed session drains without its reply.
    if (!screenshot_id_) Drain();
  }

  // content::DevToolsAgentHostClient:
  void DispatchProtocolMessage(content::DevToolsAgentHost*,
                               base::span<const uint8_t> message) override {
    std::string text(reinterpret_cast<const char*>(message.data()), message.size());
    if (screenshot_id_) {
      base::ThreadPool::PostTaskAndReplyWithResult(FROM_HERE,
          {base::TaskPriority::USER_VISIBLE},
          base::BindOnce(&Decode, std::move(text), screenshot_id_, limits_.maximum_encoded_bytes),
          base::BindOnce(&WholePageCapture::Captured, weak_factory_.GetWeakPtr()));
      return;
    }
    std::optional<base::DictValue> value = base::JSONReader::ReadDict(text, base::JSON_PARSE_RFC);
    if (!value) return;
    std::optional<int> id = value->FindInt("id");
    if (id && *id == metrics_id_) Measured(*value);
  }

  void AgentHostClosed(content::DevToolsAgentHost*) override {
    attached_ = false;
    Complete(ARX_CAPTURE_STALE);
    Drain();
  }

  bool MayAttachToURL(const GURL&, bool is_webui) override { return !is_webui; }

  // content::WebContentsObserver. The capture itself resizes the page, so a
  // resize isn't a reason to stop; IsCurrent() compares the geometry after.
  void DidStartNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsInPrimaryMainFrame()) Complete(ARX_CAPTURE_STALE);
  }
  // The page's widget is gone: Chromium drops its screenshot without a reply,
  // and there's no view left to put back.
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override { Lost(); }
  void RenderFrameHostChanged(content::RenderFrameHost*,
                              content::RenderFrameHost* new_host) override {
    if (new_host && new_host->IsInPrimaryMainFrame() &&
        web_contents()->GetRenderWidgetHostView() != view_)
      Lost();
  }
  void PrimaryPageWillBeDeactivated(content::Page&) override { Complete(ARX_CAPTURE_STALE); }
  void OnVisibilityWillChange(content::Visibility visibility) override {
    if (visibility != content::Visibility::VISIBLE) Complete(ARX_CAPTURE_STALE);
  }
  void WebContentsDestroyed() override {
    Complete(ARX_CAPTURE_STALE);
    Drain();
  }

 private:
  void Lost() {
    Complete(ARX_CAPTURE_STALE);
    Drain();
  }

  void Send(const char* method, base::DictValue params, int* id) {
    // The id is set before dispatch: an immediate failure can reply re-entrantly.
    *id = next_message_++;
    base::DictValue message;
    message.Set("id", *id);
    message.Set("method", method);
    message.Set("params", std::move(params));
    std::string json;
    base::JSONWriter::Write(message, &json);
    host_->DispatchProtocolMessage(this, base::as_byte_span(json));
  }

  bool IsCurrent() const {
    auto* contents = web_contents();
    auto* document = document_.AsRenderFrameHostIfValid();
    return contents && document && contents->GetPrimaryMainFrame() == document &&
           contents->GetRenderWidgetHostView() == view_ && view_->IsShowing() &&
           contents->GetVisibility() == content::Visibility::VISIBLE &&
           contents->GetContainerBounds().size() == container_ &&
           view_->GetVisibleViewportSize() == viewport_ &&
           view_->GetDeviceScaleFactor() == scale_ &&
           content::HostZoomMap::GetZoomLevel(contents) == zoom_level_;
  }

  // Page.getLayoutMetrics: the document's CSS size and scroll. The clip is in
  // DIP and the image comes back at the view's device scale, so CSS pixels are
  // scaled by the browser zoom first; Chromium's own full page screenshot skips
  // that and crops a zoomed-in page. From here on sizes are DIP.
  void Measured(const base::DictValue& reply) {
    metrics_id_ = 0;
    if (completed_) { Drain(); return; }
    if (!IsCurrent()) { Complete(ARX_CAPTURE_STALE); Drain(); return; }
    const base::DictValue* result = reply.FindDict("result");
    const base::DictValue* content = result ? result->FindDict("cssContentSize") : nullptr;
    const base::DictValue* layout = result ? result->FindDict("cssLayoutViewport") : nullptr;
    const std::optional<double> width = content ? content->FindDouble("width") : std::nullopt;
    const std::optional<double> height = content ? content->FindDouble("height") : std::nullopt;
    if (!width || !height || !std::isfinite(*width) || !std::isfinite(*height) || *width <= 0 ||
        *height <= 0 || !std::isfinite(scale_) || scale_ <= 0 || !std::isfinite(zoom_) ||
        zoom_ <= 0) {
      Complete(ARX_CAPTURE_UNSUPPORTED);
      Drain();
      return;
    }
    document_width_ = std::ceil(*width) * zoom_;
    document_height_ = std::ceil(*height) * zoom_;
    if (layout) {
      scroll_x_ = layout->FindDouble("pageX").value_or(0) * zoom_;
      scroll_y_ = layout->FindDouble("pageY").value_or(0) * zoom_;
    }
    // Chromium's own rounding of a clip to the image's size.
    auto pixels = [this](double dip) {
      return std::max<int64_t>(1, std::llround(dip * scale_));
    };
    // A side over the limit is cut there; then rows over the pixel budget.
    const double side = std::floor(limits_.maximum_dimension / scale_);
    captured_width_ = std::min(document_width_, side);
    captured_height_ = std::min(document_height_, side);
    const uint64_t row = static_cast<uint64_t>(pixels(captured_width_));
    if (row * static_cast<uint64_t>(pixels(captured_height_)) > limits_.maximum_pixels)
      captured_height_ = std::floor(static_cast<double>(limits_.maximum_pixels / row) / scale_);
    if (captured_width_ < 1 || captured_height_ < 1) {
      Complete(ARX_CAPTURE_LIMIT);
      Drain();
      return;
    }
    expected_ = gfx::Size(static_cast<int>(pixels(captured_width_)),
                          static_cast<int>(pixels(captured_height_)));
    cut_ = captured_width_ < document_width_ || captured_height_ < document_height_;

    base::DictValue clip;
    clip.Set("x", 0);
    clip.Set("y", 0);
    clip.Set("width", captured_width_);
    clip.Set("height", captured_height_);
    clip.Set("scale", 1);
    base::DictValue params;
    params.Set("format", "png");
    params.Set("clip", std::move(clip));
    params.Set("fromSurface", true);
    params.Set("captureBeyondViewport", true);
    ClipPage();
    Send("Page.captureScreenshot", std::move(params), &screenshot_id_);
  }

  void Captured(Screenshot screenshot) {
    if (!screenshot.is_reply || !screenshot_id_) return;
    // Chromium has put the page back to its own size: the work has returned.
    screenshot_id_ = 0;
    RestoreClipping();
    FitResizedPage();
    if (completed_) { Drain(); return; }
    if (!IsCurrent()) { Complete(ARX_CAPTURE_STALE); Drain(); return; }
    if (screenshot.status != ARX_CAPTURE_SUCCESS) { Complete(screenshot.status); Drain(); return; }
    // A frame of another size isn't the page as measured: the app falls back.
    if (screenshot.width != static_cast<uint32_t>(expected_.width()) ||
        screenshot.height != static_cast<uint32_t>(expected_.height())) {
      Complete(ARX_CAPTURE_UNSUPPORTED);
      Drain();
      return;
    }
    completed_ = true;
    timeout_.Stop();
    const ArxPageCaptureSnapshot snapshot = {
        document_id_.c_str(), screenshot.png.data(), screenshot.png.size(),
        screenshot.width, screenshot.height,
        document_width_, document_height_, captured_width_, captured_height_,
        scroll_x_, scroll_y_,
        static_cast<double>(viewport_.width()), static_cast<double>(viewport_.height()),
        static_cast<double>(scale_), zoom_level_,
        cut_, was_loading_};
    // A posted reply on the UI sequence, outside any observer stack. Swift copies
    // the borrowed PNG before it returns.
    done_(context_, request_, ARX_CAPTURE_SUCCESS, &snapshot);
    Drain();
  }

  // While the page lays out at its whole height, its view grows past the window's
  // page area; the WebContents view clips it there until the size is restored.
  void ClipPage() {
    if (@available(macOS 14.0, *)) {
      NSView* page = web_contents()->GetNativeView().GetNativeNSView();
      if (!page || clipped_) return;
      clipped_ = page;
      was_clipping_ = page.clipsToBounds;
      page.clipsToBounds = YES;
    }
  }

  // Chromium put the view back to its size before the screenshot. When the
  // window resized the page area meanwhile, the view follows the page area now.
  void FitResizedPage() {
    auto* contents = web_contents();
    if (!contents || contents->GetRenderWidgetHostView() != view_) return;
    const gfx::Size container = contents->GetContainerBounds().size();
    if (container != container_ && !container.IsEmpty()) view_->SetSize(container);
  }

  void RestoreClipping() {
    if (@available(macOS 14.0, *)) {
      if (!clipped_) return;
      clipped_.clipsToBounds = was_clipping_;
      clipped_ = nil;
    }
  }

  void Drain() {
    // Deleting on the next UI turn keeps this object alive through the current stack.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](uint64_t request) {
          if (Active() && Active()->request() == request) Active().reset();
        }, request_));
  }

  const capture::Lease physical_slot_;
  const std::string document_id_;
  const uint64_t request_;
  const ArxPageCaptureLimits limits_;
  const ArxPageCaptureCallback done_;
  void* const context_;
  const content::WeakDocumentPtr document_;
  content::RenderWidgetHostView* const view_;
  const gfx::Size viewport_;
  // The WebContents view's own size: Chromium resizes and restores the page's
  // view inside it, never the container itself.
  const gfx::Size container_;
  const float scale_;
  const double zoom_level_;
  const double zoom_;
  const bool was_loading_;
  scoped_refptr<content::DevToolsAgentHost> host_;
  bool attached_ = false;
  bool completed_ = false;
  int next_message_ = 1;
  int metrics_id_ = 0;
  int screenshot_id_ = 0;
  double document_width_ = 0, document_height_ = 0;
  double captured_width_ = 0, captured_height_ = 0;
  double scroll_x_ = 0, scroll_y_ = 0;
  gfx::Size expected_;
  bool cut_ = false;
  NSView* __strong clipped_ = nil;
  bool was_clipping_ = false;
  base::OneShotTimer timeout_;
  base::WeakPtrFactory<WholePageCapture> weak_factory_{this};
};

}  // namespace

bool CapturesWholePage(content::WebContents* contents) {
  return contents && Active() && Active()->web_contents() == contents;
}

void StopWholePageCaptures() {
  Active().reset();
}

}  // namespace arx

extern "C" __attribute__((visibility("default")))
bool ArxEngineCaptureWholePage(uint64_t page, uint64_t request, const ArxPageCaptureLimits* limits,
                               ArxPageCaptureCallback done, void* context) {
  CHECK([NSThread isMainThread]);
  if (!limits || !done || !arx::IsEmbedded() || !arx::ValidLimits(*limits)) return false;
  content::WebContents* contents = arx::PageContents(page);
  const std::string document_id = arx::PageDocumentID(page);
  if (!contents || document_id.empty()) return false;
  if (arx::CaptureInFlight() || arx::Active()) {
    arx::ReplyLater(done, context, request, ARX_CAPTURE_BUSY);
    return true;
  }
  // Chromium's screenshot CHECKs that the page isn't hidden, so only a shown page.
  auto* view = contents->GetRenderWidgetHostView();
  const float scale = view ? view->GetDeviceScaleFactor() : 0;
  if (!view || !contents->GetPrimaryMainFrame() || contents->IsCrashed() || !view->IsShowing() ||
      contents->GetVisibility() != content::Visibility::VISIBLE ||
      view->GetVisibleViewportSize().IsEmpty() || !std::isfinite(scale) || scale <= 0) {
    arx::ReplyLater(done, context, request, ARX_CAPTURE_UNAVAILABLE);
    return true;
  }
  // The screenshot applies this session's device emulation and puts it back
  // after, which would turn off DevTools' device toolbar: the app falls back.
  if (arx::DevToolsIsOpen(contents)) {
    arx::ReplyLater(done, context, request, ARX_CAPTURE_UNSUPPORTED);
    return true;
  }
  arx::Active() = std::make_unique<arx::WholePageCapture>(contents, document_id, request, *limits,
                                                          done, context);
  arx::Active()->Start();
  return true;
}

extern "C" __attribute__((visibility("default")))
void ArxEngineCancelWholePageCapture(uint64_t request) {
  CHECK([NSThread isMainThread]);
  if (arx::Active() && arx::Active()->request() == request)
    arx::Active()->Complete(ARX_CAPTURE_CANCELLED);
}
