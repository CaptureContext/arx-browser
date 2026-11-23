#include "components/paint_preview/arx/document_capture_fixture.h"

#include <array>
#include <cmath>
#include <cstdio>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/task/single_thread_task_runner.h"
#include "base/uuid.h"
#include "components/paint_preview/arx/budget.h"
#include "components/paint_preview/arx/raster_allocator_fixture.h"
#include "components/services/paint_preview_compositor/public/mojom/paint_preview_compositor.mojom.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/host_zoom_map.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkColorSpace.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "third_party/skia/include/core/SkImageInfo.h"
#include "ui/base/page_transition_types.h"
#include "ui/gfx/codec/png_codec.h"

namespace arx::document::testing {
namespace {

constexpr std::array<const char*, 9> kVariants = {
    "horizontal", "fixed", "sticky", "canvas", "animation", "frame", "lazy", "loading", "zoom"};

mojom::LimitsPtr Limits() {
  auto limits = mojom::Limits::New();
  limits->maximum_dimension = 8192;
  limits->maximum_pixels = kMaximumPixels;
  limits->maximum_record_bytes = kMaximumRecordBytes;
  limits->maximum_record_ops = kMaximumRecordOps;
  limits->maximum_decoded_image_bytes = kMaximumDecodedImageBytes;
  limits->maximum_serialized_bytes = kMaximumSerializedBytes;
  limits->maximum_png_bytes = kMaximumPNGBytes;
  limits->timeout_ms = 10000;
  return limits;
}

void Marker(const char* marker) { std::fprintf(stderr, "%s\n", marker); }

std::optional<double> Number(const base::DictValue& state, const char* name) {
  if (auto integer = state.FindInt(name)) return *integer;
  return state.FindDouble(name);
}

uint32_t SRGB(const SkBitmap& bitmap, int x, int y) {
  uint32_t color = 0;
  const auto info = SkImageInfo::MakeN32Premul(1, 1, SkColorSpace::MakeSRGB());
  if (!bitmap.readPixels(info, &color, 4, x, y)) return 0;
  // N32 memory layout is platform dependent; expose a canonical SkColor.
  SkBitmap pixel;
  if (!pixel.installPixels(info, &color, 4)) return 0;
  return pixel.getColor(0, 0);
}

}  // namespace

OwnedCaptureFixture::OwnedCaptureFixture(content::WebContents* contents, GURL origin,
                                         base::OnceCallback<void(bool)> completion)
    : WebContentsObserver(contents), origin_(std::move(origin)), completion_(std::move(completion)) {}

OwnedCaptureFixture::~OwnedCaptureFixture() {
  if (!operation_.is_empty()) CancelDocumentPrototype(operation_);
}

void OwnedCaptureFixture::Start() {
  // No arbitrary origin, credentials, file route, redirects or request payload.
  if (!web_contents() || !origin_.is_valid() || !origin_.SchemeIs("http") ||
      origin_.host() != "127.0.0.1" || !origin_.has_port() ||
      origin_.has_username() || origin_.has_password() || origin_.has_query() || origin_.has_ref()) {
    Finish(false);
    return;
  }
  const auto ordinary_request = paint_preview::mojom::PaintPreviewBeginCompositeRequest::New();
  if (!ordinary_request->arx_document_deadline.is_null() || ordinary_request->arx_document_width ||
      ordinary_request->arx_document_height || !VerifyRasterAllocator()) {
    phase_ = "raster-allocator";
    Finish(false);
    return;
  }
  Marker("ARX_DOCUMENT_CAPTURE_RASTER_ALLOCATOR_VERIFIED");
  timeout_.Start(FROM_HERE, base::Seconds(120), base::BindOnce(
      &OwnedCaptureFixture::Finish, weak_factory_.GetWeakPtr(), false));
  Navigate("plain", base::BindOnce(&OwnedCaptureFixture::AwaitState,
      weak_factory_.GetWeakPtr(), 2, base::BindOnce(&OwnedCaptureFixture::Before, weak_factory_.GetWeakPtr())));
}

void OwnedCaptureFixture::Finish(bool success) {
  if (finished_) return;
  finished_ = true;
  weak_factory_.InvalidateWeakPtrs();
  timeout_.Stop();
  repaint_timeout_.Stop();
  loader_.reset();
  resume_record_.Reset();
  if (!operation_.is_empty()) CancelDocumentPrototype(operation_);
  if (success) Marker("ARX_DOCUMENT_CAPTURE_SMOKE_VERIFIED");
  else std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_SMOKE_FAILED phase=%s\n", phase_);
  if (completion_) std::move(completion_).Run(success);
}

GURL OwnedCaptureFixture::URL(const std::string& route, const std::string& query) const {
  GURL::Replacements replacements;
  const std::string path = "/document-capture/" + route;
  replacements.SetPathStr(path);
  replacements.SetQueryStr(query);
  replacements.ClearRef();
  return origin_.ReplaceComponents(replacements);
}

void OwnedCaptureFixture::Navigate(const char* mode, base::OnceClosure loaded) {
  allow_loading_state_ = std::string(mode) == "loading";
  run_ = base::Uuid::GenerateRandomV4().AsLowercaseString();
  expected_ = URL("main", "run=" + run_ + "&mode=" + mode);
  loaded_ = std::move(loaded);
  content::NavigationController::LoadURLParams parameters(expected_);
  parameters.transition_type = ui::PAGE_TRANSITION_TYPED;
  web_contents()->GetController().LoadURLWithParams(parameters);
}

void OwnedCaptureFixture::DidStopLoading() {
  if (!loaded_ || web_contents()->IsLoading() || web_contents()->GetLastCommittedURL() != expected_) return;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, std::move(loaded_));
}

void OwnedCaptureFixture::DidStartNavigation(content::NavigationHandle* handle) {
  if (!handle->IsInPrimaryMainFrame() && resume_record_)
    std::move(resume_record_).Run();
}

void OwnedCaptureFixture::DidFinishNavigation(content::NavigationHandle* handle) {
  if (allow_loading_state_ && handle->IsInPrimaryMainFrame() && handle->HasCommitted() &&
      web_contents()->GetLastCommittedURL() == expected_ && loaded_)
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, std::move(loaded_));
}

void OwnedCaptureFixture::WebContentsDestroyed() { Finish(false); }

void OwnedCaptureFixture::Fetch(GURL url, Response response) {
  if (finished_ || !web_contents() || loader_) { Finish(false); return; }
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = std::move(url);
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  request->redirect_mode = network::mojom::RedirectMode::kError;
  const auto annotation = net::DefineNetworkTrafficAnnotation("arx_document_capture_disposable_fixture", R"(
    semantics {
      sender: "Arx full-document capture fixture"
      description: "Reads fixed evidence and controls from a developer-owned loopback fixture."
      trigger: "Explicit signed disposable engine-host fixture."
      data: "No user data; bounded layout counters and one fixed frame command."
      destination: LOCAL
    }
    policy {
      cookies_allowed: NO
      setting: "Unexposed native prototype fixture only."
      policy_exception_justification: "Developer-owned local test."
    })");
  loader_ = network::SimpleURLLoader::Create(std::move(request), annotation);
  loader_->SetAllowHttpErrorResults(true);
  loader_->SetTimeoutDuration(base::Seconds(3));
  loader_->DownloadToString(web_contents()->GetBrowserContext()->GetDefaultStoragePartition()
      ->GetURLLoaderFactoryForBrowserProcess().get(), base::BindOnce(
          &OwnedCaptureFixture::Fetched, weak_factory_.GetWeakPtr(), std::move(response)), 8192);
}

void OwnedCaptureFixture::Fetched(Response response, std::optional<std::string> body) {
  const auto* info = loader_->ResponseInfo();
  const int code = info && info->headers ? info->headers->response_code() : 0;
  const int error = loader_->NetError();
  loader_.reset();
  if (error != 0 || (code != 200 && code != 204 && code != 404)) {
    std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_FETCH_FAILED phase=%s code=%d net=%d\n", phase_, code, error);
    Finish(false); return;
  }
  std::move(response).Run(code, std::move(body));
}

void OwnedCaptureFixture::AwaitState(int after, StateCallback callback) {
  Fetch(URL("state/" + run_), base::BindOnce(&OwnedCaptureFixture::StateReceived,
      weak_factory_.GetWeakPtr(), after, std::move(callback)));
}

void OwnedCaptureFixture::StateReceived(int after, StateCallback callback, int code,
                                       std::optional<std::string> body) {
  auto value = code == 200 && body ? base::JSONReader::Read(*body, base::JSON_PARSE_RFC) : std::nullopt;
  const auto* state = value ? value->GetIfDict() : nullptr;
  if (state && state->FindBool("ready") == true && state->FindBool("focused") == true &&
      state->FindInt("sample").value_or(0) > after) {
    std::move(callback).Run(state->Clone());
    return;
  }
  if (code != 404 && !state) { Finish(false); return; }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
      base::BindOnce(&OwnedCaptureFixture::AwaitState, weak_factory_.GetWeakPtr(), after, std::move(callback)),
      base::Milliseconds(50));
}

void OwnedCaptureFixture::Before(State state) {
  if (state.FindInt("documentHeight") != kDocumentHeight || Number(state, "scrollY") != kScroll ||
      Number(state, "scrollX") != 0 || Number(state, "visualScale") != 1 || state.FindInt("frames") != 0) {
    Finish(false); return;
  }
  phase_ = "pixels";
  before_ = std::move(state);
  auto* view = web_contents()->GetRenderWidgetHostView();
  std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_PIXELS_VIEW showing=%d\n", view && view->IsShowing());
  if (!view || !view->IsShowing()) { Finish(false); return; }
  viewport_size_ = view->GetVisibleViewportSize();
  device_scale_ = view->GetDeviceScaleFactor();
  std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_PIXELS_FIXTURE_GEOMETRY viewport=%d,%d device_scale=%g "
      "css_document=%d,%d css_viewport=%d,%d css_device_scale=%g visual_scale=%g\n",
      viewport_size_.width(), viewport_size_.height(), device_scale_,
      before_.FindInt("documentWidth").value_or(-1), before_.FindInt("documentHeight").value_or(-1),
      before_.FindInt("viewportWidth").value_or(-1), before_.FindInt("viewportHeight").value_or(-1),
      Number(before_, "deviceScale").value_or(-1), Number(before_, "visualScale").value_or(-1));
  CopyViewport(base::BindOnce(&OwnedCaptureFixture::BeginPositive, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::CopyViewport(base::OnceCallback<void(ViewportSamples)> callback) {
  auto* view = web_contents()->GetRenderWidgetHostView();
  if (!view || !view->IsShowing() || view->GetVisibleViewportSize() != viewport_size_ ||
      view->GetDeviceScaleFactor() != device_scale_) { Finish(false); return; }
  auto runner = base::SingleThreadTaskRunner::GetCurrentDefault();
  view->CopyFromSurface(gfx::Rect(viewport_size_), view->GetVisibleViewportSizeDevicePx(), base::Seconds(3),
      base::BindOnce([](scoped_refptr<base::SingleThreadTaskRunner> runner,
                       base::WeakPtr<OwnedCaptureFixture> fixture,
                       base::OnceCallback<void(ViewportSamples)> callback,
                       const content::CopyFromSurfaceResult& result) {
        if (!result || result->bitmap.width() < 128 || result->bitmap.height() < 128) {
          std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_VIEWPORT_COPY failed=%d width=%d height=%d\n",
              !result, result ? result->bitmap.width() : 0, result ? result->bitmap.height() : 0);
          runner->PostTask(FROM_HERE, base::BindOnce(&OwnedCaptureFixture::Finish, fixture, false));
          return;
        }
        const auto samples = ViewportPixels(result->bitmap.width(), result->bitmap.height(),
            [&result](int x, int y) { return SRGB(result->bitmap, x, y); });
        runner->PostTask(FROM_HERE, base::BindOnce([](base::WeakPtr<OwnedCaptureFixture> fixture,
            base::OnceCallback<void(ViewportSamples)> callback, ViewportSamples samples) {
          if (fixture) std::move(callback).Run(samples);
        }, fixture, std::move(callback), samples));
      }, std::move(runner), weak_factory_.GetWeakPtr(), std::move(callback)));
}

void OwnedCaptureFixture::BeginPositive(ViewportSamples samples) {
  Marker("ARX_DOCUMENT_CAPTURE_PIXELS_SUBMITTED");
  viewport_before_ = samples;
  operation_ = CaptureDocumentPrototype(web_contents(), Limits(), base::BindOnce(
      &OwnedCaptureFixture::Captured, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::Captured(Result result) {
  std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_PIXELS_RESULT status=%d geometry=%d png_bytes=%zu\n",
      static_cast<int>(result.status), static_cast<bool>(result.geometry), result.png.size());
  if (result.geometry) {
    const auto& rect = result.geometry->document_rect;
    std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_PIXELS_GEOMETRY rect=%d,%d,%d,%d scroll=%.6f,%.6f zoom=%.6f page_scale=%.6f focused=%d\n",
        rect.x(), rect.y(), rect.width(), rect.height(), result.geometry->scroll.x(), result.geometry->scroll.y(),
        result.geometry->zoom_level, result.geometry->page_scale, result.geometry->focused_node != 0);
  }
  if (result.status != mojom::Status::kSuccess || !result.geometry || result.png.empty() ||
      result.geometry->document_rect.origin() != gfx::Point() ||
      !GeometryMatchesCSS(result.geometry->document_rect.width(), result.geometry->document_rect.height(),
          result.geometry->scroll.x(), result.geometry->scroll.y(), before_.FindInt("documentWidth").value_or(0),
          kDocumentHeight, 0, kScroll, Number(before_, "deviceScale").value_or(0), device_scale_, 1) ||
      result.geometry->zoom_level != 0 ||
      result.geometry->page_scale != 1 || result.geometry->focused_node == 0) { Finish(false); return; }
  const SkBitmap bitmap = gfx::PNGCodec::Decode(result.png);
  std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_PIXELS_BITMAP width=%d height=%d empty=%d\n",
      bitmap.width(), bitmap.height(), bitmap.drawsNothing());
  if (!bitmap.drawsNothing() && bitmap.width() >= 400 && bitmap.height() == std::lround(kDocumentHeight * device_scale_)) {
    const int band_height = std::lround(kBandHeight * device_scale_);
    for (int band = 0; band < 3; ++band) {
      std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_PIXELS_BAND index=%d colors=%08x,%08x,%08x\n", band,
          SRGB(bitmap, 32, band * band_height + 32),
          SRGB(bitmap, bitmap.width() / 2, band * band_height + band_height / 2),
          SRGB(bitmap, 32, (band + 1) * band_height - 32));
    }
  }
  if (bitmap.drawsNothing() ||
      bitmap.dimensions().width() != result.geometry->document_rect.width() ||
      !FullDocumentPixels(bitmap.width(), bitmap.height(), device_scale_,
          [&bitmap](int x, int y) { return SRGB(bitmap, x, y); })) { Marker("ARX_DOCUMENT_CAPTURE_VARIANT_MARKER_MISMATCH"); Finish(false); return; }
  AwaitState(before_.FindInt("sample").value_or(0) + 2,
      base::BindOnce(&OwnedCaptureFixture::After, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::After(State state) {
  auto expected = before_.Clone();
  expected.Remove("sample"); state.Remove("sample");
  if (state != expected) { Marker("ARX_DOCUMENT_CAPTURE_PIXELS_STATE_CHANGED"); Finish(false); return; }
  Marker("ARX_DOCUMENT_CAPTURE_PIXELS_STATE_PRESERVED");
  CopyViewport(base::BindOnce(&OwnedCaptureFixture::ViewportVerified, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::ViewportVerified(ViewportSamples samples) {
  if (samples != viewport_before_) { Marker("ARX_DOCUMENT_CAPTURE_PIXELS_VIEWPORT_CHANGED"); Finish(false); return; }
  Marker("ARX_DOCUMENT_CAPTURE_SMOKE_PIXELS_AND_STATE");
  CheckCancellation();
}

void OwnedCaptureFixture::CheckCancellation() {
  phase_ = "cancel";
  operation_ = CaptureDocumentPrototype(web_contents(), Limits(), base::BindOnce(
      &OwnedCaptureFixture::Cancelled, weak_factory_.GetWeakPtr()));
  if (operation_.is_empty()) { Finish(false); return; }
  CancelDocumentPrototype(operation_);
  // Admission stays physically busy until the outstanding Inspect response.
  CaptureDocumentPrototype(web_contents(), Limits(), base::BindOnce(
      [](base::WeakPtr<OwnedCaptureFixture> fixture, Result result) {
        if (fixture && (result.status != mojom::Status::kBusy || !result.png.empty())) fixture->Finish(false);
      }, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::Cancelled(Result result) {
  if (result.status != mojom::Status::kCancelled || !result.png.empty()) { Finish(false); return; }
  Marker("ARX_DOCUMENT_CAPTURE_SMOKE_CANCEL_BUSY");
  WaitDrained(base::BindOnce(&OwnedCaptureFixture::CheckNavigation, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::WaitDrained(base::OnceClosure continuation) {
  auto limits = Limits();
  limits->maximum_pixels = 1; // once free, geometry rejects before painting
  CaptureDocumentPrototype(web_contents(), std::move(limits), base::BindOnce(
      &OwnedCaptureFixture::DrainResult, weak_factory_.GetWeakPtr(), std::move(continuation)));
}

void OwnedCaptureFixture::DrainResult(base::OnceClosure continuation, Result result) {
  if (result.status == mojom::Status::kBusy) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
        base::BindOnce(&OwnedCaptureFixture::WaitDrained, weak_factory_.GetWeakPtr(), std::move(continuation)),
        base::Milliseconds(25));
    return;
  }
  size_t frames = 0;
  if (web_contents() && web_contents()->GetPrimaryMainFrame())
    web_contents()->GetPrimaryMainFrame()->ForEachRenderFrameHost(
        [&frames](content::RenderFrameHost*) { ++frames; });
  // Busy is checked before initial-tree admission. An unsupported result from
  // an existing child tree therefore also proves no physical work was started.
  const bool idle = result.status == mojom::Status::kLimit ||
      (result.status == mojom::Status::kUnsupported && frames > 1);
  if (!idle || !result.png.empty()) {
    std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_DRAIN_FAILED status=%u frames=%zu png=%zu\n",
        static_cast<unsigned>(result.status), frames, result.png.size());
    Finish(false); return;
  }
  // Limit reply precedes the operation's deferred physical retirement.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, std::move(continuation));
}

void OwnedCaptureFixture::CheckNavigation() {
  phase_ = "navigation";
  navigation_check_ = true;
  navigation_ready_ = navigation_invalidated_ = false;
  expected_ = URL("destination", "run=" + run_);
  loaded_ = base::BindOnce(&OwnedCaptureFixture::NavigationReady, weak_factory_.GetWeakPtr());
  operation_ = CaptureDocumentPrototype(web_contents(), Limits(), base::BindOnce(
      &OwnedCaptureFixture::Navigated, weak_factory_.GetWeakPtr()));
  if (operation_.is_empty()) { Finish(false); return; }
  content::NavigationController::LoadURLParams parameters(expected_);
  parameters.transition_type = ui::PAGE_TRANSITION_TYPED;
  web_contents()->GetController().LoadURLWithParams(parameters);
}

void OwnedCaptureFixture::Navigated(Result result) {
  if (result.status != mojom::Status::kChanged || !result.png.empty()) { Finish(false); return; }
  Marker("ARX_DOCUMENT_CAPTURE_SMOKE_NAVIGATION_INVALIDATED");
  navigation_invalidated_ = true;
  MaybeNavigationFinished();
}

void OwnedCaptureFixture::NavigationReady() {
  navigation_ready_ = true;
  MaybeNavigationFinished();
}

void OwnedCaptureFixture::MaybeNavigationFinished() {
  if (!navigation_check_ || !navigation_ready_ || !navigation_invalidated_) return;
  navigation_check_ = false;
  WaitDrained(base::BindOnce(&OwnedCaptureFixture::CheckFrame, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::CheckFrame() {
  phase_ = "frame";
  frame_command_done_ = frame_invalidated_ = false;
  Navigate("plain", base::BindOnce(&OwnedCaptureFixture::AwaitState, weak_factory_.GetWeakPtr(), 2,
      base::BindOnce([](base::WeakPtr<OwnedCaptureFixture> fixture, State) {
        if (!fixture) return;
        fixture->operation_ = CaptureDocumentPrototypeForTesting(fixture->web_contents(), Limits(),
            base::BindOnce(&OwnedCaptureFixture::HoldForFrame, fixture),
            base::BindOnce(&OwnedCaptureFixture::Framed, fixture));
        if (fixture->operation_.is_empty()) fixture->Finish(false);
      }, weak_factory_.GetWeakPtr())));
}

void OwnedCaptureFixture::HoldForFrame(base::OnceClosure resume) {
  resume_record_ = std::move(resume);
  Fetch(URL("command/" + run_, "action=add-frame"), base::BindOnce(
      [](base::WeakPtr<OwnedCaptureFixture> fixture, int code, std::optional<std::string>) {
        if (!fixture) return;
        if (code != 204) { fixture->Finish(false); return; }
        fixture->frame_command_done_ = true;
        fixture->MaybeFrameFinished();
      }, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::Framed(Result result) {
  resume_record_.Reset();
  if (result.status != mojom::Status::kChanged || !result.png.empty()) { Finish(false); return; }
  Marker("ARX_DOCUMENT_CAPTURE_SMOKE_FRAME_CHANGED");
  frame_invalidated_ = true;
  MaybeFrameFinished();
}

void OwnedCaptureFixture::MaybeFrameFinished() {
  if (!frame_invalidated_ || !frame_command_done_) return;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
      base::BindOnce(&OwnedCaptureFixture::CheckRecordingBudget, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::CheckRecordingBudget() {
  phase_ = "recording-budget";
  Navigate("plain", base::BindOnce(&OwnedCaptureFixture::AwaitState, weak_factory_.GetWeakPtr(), 2,
      base::BindOnce([](base::WeakPtr<OwnedCaptureFixture> fixture, State state) {
        if (!fixture) return;
        fixture->before_ = std::move(state);
        fixture->repaint_document_ = fixture->web_contents()->GetPrimaryMainFrame()->GetWeakDocumentPtr();
        fixture->repaint_attempts_ = 0;
        fixture->repaint_wait_reported_ = false;
        auto limits = Limits();
        limits->maximum_record_ops = 1;
        fixture->operation_ = CaptureDocumentPrototype(fixture->web_contents(), std::move(limits),
            base::BindOnce(&OwnedCaptureFixture::BudgetRejected, fixture));
      }, weak_factory_.GetWeakPtr())));
}

void OwnedCaptureFixture::BudgetRejected(Result result) {
  if (result.status != mojom::Status::kLimit || !result.png.empty()) { Finish(false); return; }
  AwaitState(before_.FindInt("sample").value_or(0) + 2,
      base::BindOnce(&OwnedCaptureFixture::AfterBudget, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::AfterBudget(State state) {
  auto expected = before_.Clone();
  expected.Remove("sample"); state.Remove("sample");
  if (state != expected || !RepaintSourceIsCurrent()) {
    Marker("ARX_DOCUMENT_CAPTURE_BUDGET_STATE_OR_SOURCE_CHANGED"); Finish(false); return;
  }
  Marker("ARX_DOCUMENT_CAPTURE_BUDGET_STATE_PRESERVED");
  WaitDrained(base::BindOnce([](base::WeakPtr<OwnedCaptureFixture> fixture) {
    if (!fixture) return;
    fixture->phase_ = "recording-budget-command";
    fixture->Fetch(fixture->URL("command/" + fixture->run_, "action=repaint"), base::BindOnce(
        [](base::WeakPtr<OwnedCaptureFixture> fixture, int code, std::optional<std::string>) {
          if (!fixture) return;
          std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_REPAINT_COMMAND code=%d\n", code);
          if (code != 204 || !fixture->RepaintSourceIsCurrent()) { fixture->Finish(false); return; }
          fixture->phase_ = "recording-budget-repaint-state";
          fixture->AwaitState(0, base::BindOnce(&OwnedCaptureFixture::RepaintState, fixture));
        }, fixture));
  }, weak_factory_.GetWeakPtr()));
}

bool OwnedCaptureFixture::RepaintSourceIsCurrent() const {
  return web_contents() && web_contents()->GetLastCommittedURL() == expected_ &&
         repaint_document_.AsRenderFrameHostIfValid() &&
         repaint_document_.AsRenderFrameHostIfValid() == web_contents()->GetPrimaryMainFrame();
}

void OwnedCaptureFixture::RepaintState(State state) {
  if (!RepaintSourceIsCurrent()) {
    Marker("ARX_DOCUMENT_CAPTURE_REPAINT_SOURCE_CHANGED"); Finish(false); return;
  }
  if (state.FindBool("repainted") != true) {
    if (!repaint_wait_reported_) {
      std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_REPAINT_WAIT sample=%d\n", state.FindInt("sample").value_or(-1));
      repaint_wait_reported_ = true;
    }
    AwaitState(state.FindInt("sample").value_or(0),
        base::BindOnce(&OwnedCaptureFixture::RepaintState, weak_factory_.GetWeakPtr()));
    return;
  }
  auto expected = before_.Clone();
  expected.Remove("sample"); state.Remove("sample");
  expected.Set("repainted", true);
  if (state != expected) {
    Marker("ARX_DOCUMENT_CAPTURE_REPAINT_STATE_CHANGED"); Finish(false); return;
  }
  Marker("ARX_DOCUMENT_CAPTURE_REPAINT_STATE_READY");
  phase_ = "recording-budget-visual-submission";
  repaint_started_ = base::TimeTicks::Now();
  repaint_timeout_.Start(FROM_HERE, base::Seconds(1), base::BindOnce(
      [](base::WeakPtr<OwnedCaptureFixture> fixture) {
        if (!fixture) return;
        std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_REPAINT_TIMEOUT attempts=%u last=%08x,%08x,%08x\n", fixture->repaint_attempts_,
            fixture->repaint_last_samples_[0], fixture->repaint_last_samples_[1], fixture->repaint_last_samples_[2]);
        fixture->Finish(false);
      }, weak_factory_.GetWeakPtr()));
  // A renderer report/double-rAF can precede Viz activation. Submission is a
  // first fence, followed by bounded observation of the exact expected pixels.
  web_contents()->GetPrimaryMainFrame()->InsertVisualStateCallback(base::BindOnce(
      [](base::WeakPtr<OwnedCaptureFixture> fixture, bool submitted) {
        if (!fixture) return;
        std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_REPAINT_SUBMITTED ready=%d\n", submitted);
        if (!submitted || !fixture->RepaintSourceIsCurrent()) { fixture->Finish(false); return; }
        fixture->phase_ = "recording-budget-visual-pixels";
        fixture->CopyViewport(base::BindOnce(&OwnedCaptureFixture::Repainted, fixture));
      }, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::Repainted(ViewportSamples samples) {
  if (!RepaintSourceIsCurrent()) {
    Marker("ARX_DOCUMENT_CAPTURE_REPAINT_SOURCE_CHANGED"); Finish(false); return;
  }
  ++repaint_attempts_;
  repaint_last_samples_ = samples;
  const auto elapsed = (base::TimeTicks::Now() - repaint_started_).InMilliseconds();
  const auto observation = ObserveRepaint(viewport_before_, samples, elapsed);
  const bool final = observation != RepaintObservation::kPending || repaint_attempts_ >= 20;
  if (repaint_attempts_ == 1 || final) {
    std::fprintf(stderr,
        "ARX_DOCUMENT_CAPTURE_REPAINT_PIXELS attempt=%u elapsed_ms=%lld observation=%u baseline=%08x,%08x,%08x actual=%08x,%08x,%08x\n",
        repaint_attempts_, static_cast<long long>(elapsed), static_cast<unsigned>(observation),
        viewport_before_[0], viewport_before_[1], viewport_before_[2], samples[0], samples[1], samples[2]);
  }
  if (observation == RepaintObservation::kReady) {
    repaint_timeout_.Stop();
    Marker("ARX_DOCUMENT_CAPTURE_SMOKE_RECORDING_LIMIT_AND_REPAINT");
    RunNextVariant();
    return;
  }
  if (final) { Finish(false); return; }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
      base::BindOnce([](base::WeakPtr<OwnedCaptureFixture> fixture) {
        if (!fixture) return;
        if (!fixture->RepaintSourceIsCurrent()) { fixture->Finish(false); return; }
        fixture->CopyViewport(base::BindOnce(&OwnedCaptureFixture::Repainted, fixture));
      }, weak_factory_.GetWeakPtr()), base::Milliseconds(50));
}

void OwnedCaptureFixture::RunNextVariant() {
  if (variant_ == kVariants.size()) {
    content::HostZoomMap::SetZoomLevel(web_contents(), 0);
    Marker("ARX_DOCUMENT_CAPTURE_SMOKE_VARIANTS_VERIFIED");
    CheckLimits();
    return;
  }
  phase_ = kVariants[variant_];
  variant_factor_ = std::string(phase_) == "zoom" ? 1.25 : 1;
  content::HostZoomMap::SetZoomLevel(web_contents(), blink::ZoomFactorToZoomLevel(variant_factor_));
  Navigate(phase_, base::BindOnce(&OwnedCaptureFixture::AwaitState, weak_factory_.GetWeakPtr(), 2,
      base::BindOnce(&OwnedCaptureFixture::BeforeVariant, weak_factory_.GetWeakPtr())));
}

void OwnedCaptureFixture::BeforeVariant(State state) {
  const std::string mode = kVariants[variant_];
  std::fprintf(stderr,
      "ARX_DOCUMENT_CAPTURE_VARIANT_INPUT mode=%s css_document=%d,%d css_viewport=%d,%d scroll=%g,%g css_device=%g backing=%g zoom_factor=%g frames=%d lazy_requests=%d loading=%d\n",
      mode.c_str(), state.FindInt("documentWidth").value_or(-1), state.FindInt("documentHeight").value_or(-1),
      state.FindInt("viewportWidth").value_or(-1), state.FindInt("viewportHeight").value_or(-1),
      Number(state, "scrollX").value_or(-1), Number(state, "scrollY").value_or(-1),
      Number(state, "deviceScale").value_or(-1), device_scale_, variant_factor_,
      state.FindInt("frames").value_or(-1), state.FindInt("lazyRequests").value_or(-1), web_contents()->IsLoading());
  if ((mode == "loading" && !web_contents()->IsLoading()) ||
      (mode == "lazy" && state.FindInt("lazyRequests") != 0) ||
      (mode == "horizontal" && Number(state, "scrollX").value_or(0) <= 0)) { Finish(false); return; }
  before_ = std::move(state);
  CopyViewport(base::BindOnce(&OwnedCaptureFixture::VariantViewportBefore, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::VariantViewportBefore(ViewportSamples samples) {
  viewport_before_ = samples;
  operation_ = CaptureDocumentPrototype(web_contents(), Limits(), base::BindOnce(
      &OwnedCaptureFixture::VariantCaptured, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::VariantCaptured(Result result) {
  const std::string mode = kVariants[variant_];
  std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_VARIANT_RESULT mode=%s status=%u geometry=%d png=%zu loading=%d\n",
      mode.c_str(), static_cast<unsigned>(result.status), !!result.geometry, result.png.size(), result.was_loading);
  const bool unsupported = mode == "canvas" || mode == "animation" || mode == "frame";
  if (unsupported) {
    if (result.status != mojom::Status::kUnsupported || !result.png.empty()) { Finish(false); return; }
  } else {
    if (result.status != mojom::Status::kSuccess || !result.geometry || result.png.empty()) {
      std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_SMOKE_VARIANT_STATUS status=%d\n", static_cast<int>(result.status));
      Finish(false); return;
    }
    if (mode == "loading" && !result.was_loading) { Marker("ARX_DOCUMENT_CAPTURE_VARIANT_LOADING_METADATA_MISSING"); Finish(false); return; }
    const auto& geometry = *result.geometry;
    const auto bitmap = gfx::PNGCodec::Decode(result.png);
    const double layout_scale = device_scale_ * variant_factor_;
    const int expected_height = std::lround(before_.FindInt("documentHeight").value_or(0) * layout_scale);
    const int expected_width = std::lround(before_.FindInt("documentWidth").value_or(0) * layout_scale);
    std::fprintf(stderr,
        "ARX_DOCUMENT_CAPTURE_VARIANT_GEOMETRY mode=%s bitmap=%d,%d rect=%d,%d,%d,%d expected=%d,%d scroll=%g,%g zoom=%g pinch=%g scale=%g\n",
        mode.c_str(), bitmap.width(), bitmap.height(), geometry.document_rect.x(), geometry.document_rect.y(),
        geometry.document_rect.width(), geometry.document_rect.height(), expected_width, expected_height,
        geometry.scroll.x(), geometry.scroll.y(), geometry.zoom_level, geometry.page_scale, layout_scale);
    if (bitmap.drawsNothing() || bitmap.width() != geometry.document_rect.width() ||
        bitmap.height() != expected_height || geometry.document_rect.height() != expected_height ||
        bitmap.width() != expected_width ||
        !GeometryMatchesCSS(bitmap.width(), bitmap.height(), geometry.scroll.x(), geometry.scroll.y(),
            before_.FindInt("documentWidth").value_or(0), before_.FindInt("documentHeight").value_or(0),
            Number(before_, "scrollX").value_or(0), Number(before_, "scrollY").value_or(0),
            Number(before_, "deviceScale").value_or(0), device_scale_, variant_factor_) ||
        geometry.document_rect.origin() != gfx::Point() || geometry.page_scale != 1 ||
        std::abs(geometry.zoom_level - blink::ZoomFactorToZoomLevel(variant_factor_)) > 1e-6 ||
        (mode == "horizontal" && bitmap.width() != std::lround(1200 * layout_scale))) {
      Marker("ARX_DOCUMENT_CAPTURE_VARIANT_GEOMETRY_MISMATCH"); Finish(false); return;
    }
    for (int x : {32, bitmap.width() / 2}) {
      if (SRGB(bitmap, x, 32) != kColors[0] ||
          SRGB(bitmap, x, std::lround(kBandHeight * layout_scale) + 32) != kColors[1] ||
          SRGB(bitmap, x, bitmap.height() - 32) != kColors[2]) {
        std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_VARIANT_PIXELS_MISMATCH x=%d colors=%08x,%08x,%08x\n",
            x, SRGB(bitmap, x, 32), SRGB(bitmap, x, std::lround(kBandHeight * layout_scale) + 32),
            SRGB(bitmap, x, bitmap.height() - 32));
        Finish(false); return;
      }
    }
    if (mode == "fixed" || mode == "sticky") {
      const double x = Number(before_, "markerX").value_or(-1) + Number(before_, "scrollX").value_or(-1);
      const double y = Number(before_, "markerY").value_or(-1) + Number(before_, "scrollY").value_or(-1);
      const double width = Number(before_, "markerWidth").value_or(0);
      const double height = Number(before_, "markerHeight").value_or(0);
      if (!SingleMarkerPixels(bitmap.width(), bitmap.height(), x, y, width, height, layout_scale,
          [&bitmap](int x, int y) { return SRGB(bitmap, x, y); })) { Finish(false); return; }
    }
    if (mode == "zoom") std::fprintf(stderr,
        "ARX_DOCUMENT_CAPTURE_SMOKE_ZOOM_METADATA zoom=%.6f device=%.3f css_to_layout=%.3f raster=1 width=%d height=%d\n",
        geometry.zoom_level, device_scale_, layout_scale, bitmap.width(), bitmap.height());
  }
  AwaitState(before_.FindInt("sample").value_or(0) + 2,
      base::BindOnce(&OwnedCaptureFixture::AfterVariant, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::AfterVariant(State state) {
  auto expected = before_.Clone();
  expected.Remove("sample"); state.Remove("sample");
  if (state != expected || (std::string(kVariants[variant_]) == "loading" && !web_contents()->IsLoading())) {
    std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_VARIANT_STATE_CHANGED mode=%s loading=%d lazy_requests=%d frames=%d\n",
        kVariants[variant_], web_contents()->IsLoading(), state.FindInt("lazyRequests").value_or(-1),
        state.FindInt("frames").value_or(-1));
    Finish(false); return;
  }
  CopyViewport(base::BindOnce(&OwnedCaptureFixture::VariantViewportAfter, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::VariantViewportAfter(ViewportSamples samples) {
  if (samples != viewport_before_) {
    for (size_t index = 0; index < samples.size(); ++index)
      if (samples[index] != viewport_before_[index]) {
        std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_VARIANT_VIEWPORT_CHANGED index=%zu before=%08x after=%08x\n",
            index, viewport_before_[index], samples[index]);
        break;
      }
    Finish(false); return;
  }
  if (std::string(kVariants[variant_]) == "loading") {
    Fetch(URL("command/" + run_, "action=release-load"), base::BindOnce(
        [](base::WeakPtr<OwnedCaptureFixture> fixture, int code, std::optional<std::string>) {
          if (!fixture) return;
          if (code != 204) { fixture->Finish(false); return; }
          fixture->VariantFinished();
        }, weak_factory_.GetWeakPtr()));
    return;
  }
  VariantFinished();
}

void OwnedCaptureFixture::VariantFinished() {
  std::fprintf(stderr, "ARX_DOCUMENT_CAPTURE_SMOKE_VARIANT_%s\n", kVariants[variant_]);
  ++variant_;
  WaitDrained(base::BindOnce(&OwnedCaptureFixture::RunNextVariant, weak_factory_.GetWeakPtr()));
}

void OwnedCaptureFixture::CheckLimits() {
  phase_ = "limits";
  Navigate("oversize", base::BindOnce(&OwnedCaptureFixture::AwaitState, weak_factory_.GetWeakPtr(), 2,
      base::BindOnce([](base::WeakPtr<OwnedCaptureFixture> fixture, State state) {
        if (!fixture) return;
        if (state.FindInt("documentHeight").value_or(0) <= 8192) { fixture->Finish(false); return; }
        fixture->operation_ = CaptureDocumentPrototype(fixture->web_contents(), Limits(),
            base::BindOnce(&OwnedCaptureFixture::LimitResult, fixture));
      }, weak_factory_.GetWeakPtr())));
}

void OwnedCaptureFixture::LimitResult(Result result) {
  if (result.status != mojom::Status::kLimit || !result.png.empty()) { Finish(false); return; }
  Marker("ARX_DOCUMENT_CAPTURE_SMOKE_LIMIT_REJECTED");
  Finish(true);
}

}  // namespace arx::document::testing
