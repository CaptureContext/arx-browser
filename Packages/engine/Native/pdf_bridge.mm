#include "chrome/browser/arx/pdf_bridge.h"

#include <cmath>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <variant>

#include "base/functional/bind.h"
#include "base/memory/ref_counted_memory.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "base/timer/timer.h"
#include "components/printing/browser/print_to_pdf/pdf_print_job.h"
#include "components/printing/browser/print_to_pdf/pdf_print_utils.h"
#include "components/printing/common/print.mojom.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents_observer.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "net/base/isolation_info.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/cookies/site_for_cookies.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "url/origin.h"

namespace arx {
namespace {
constexpr uint32_t kMaximumPdfBytes = 32 * 1024 * 1024;
constexpr uint32_t kMaximumPdfTimeout = 30000;

constexpr net::NetworkTrafficAnnotationTag kPdfSourceAnnotation =
    net::DefineNetworkTrafficAnnotation("arx_pdf_source", R"(
      semantics {
        sender: "Arx local automation"
        description:
          "Reads the bytes of the PDF document a tab already shows, so a "
          "locally granted assistant can read its text."
        trigger: "An explicitly granted assistant asks for a PDF tab's text."
        data: "The tab's own URL with the profile's cookies."
        destination: WEBSITE
      }
      policy {
        cookies_allowed: YES
        cookies_store: "user"
        setting: "Local assistants (MCP) in Arx Settings."
        policy_exception_justification: "Not implemented."
      })");

void ReplyLater(PdfReply reply, uint64_t request, uint64_t page, ArxPdfStatus status) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
      base::BindOnce(reply, request, page, status, nullptr, nullptr, 0));
}

class PdfRequest;
std::map<uint64_t, std::unique_ptr<PdfRequest>>& Requests() {
  static base::NoDestructor<std::map<uint64_t, std::unique_ptr<PdfRequest>>> requests;
  return *requests;
}

// One logical reply per request. The print job or loader may outlive the reply;
// the request object stays until its physical work returns or the frame goes.
class PdfRequest final : public content::WebContentsObserver {
 public:
  PdfRequest(content::WebContents* contents, std::string document_id, uint64_t page,
             uint64_t request, uint32_t maximum_bytes, uint32_t timeout_ms, PdfReply reply)
      : WebContentsObserver(contents), document_id_(std::move(document_id)), page_(page),
        request_(request), maximum_bytes_(maximum_bytes), reply_(reply),
        document_(contents->GetPrimaryMainFrame()->GetWeakDocumentPtr()) {
    timeout_.Start(FROM_HERE, base::Milliseconds(timeout_ms),
        base::BindOnce(&PdfRequest::Fail, weak_.GetWeakPtr(), ARX_PDF_TIMEOUT));
  }

  void Export(ArxPdfOptions options) {
    auto* frame = web_contents()->GetPrimaryMainFrame();
    auto params = print_to_pdf::GetPrintPagesParams(frame->GetLastCommittedURL(),
        options.landscape, /*display_header_footer=*/false, options.print_background,
        options.scale > 0 ? std::optional<double>(options.scale) : std::nullopt,
        options.paper_width > 0 ? std::optional<double>(options.paper_width) : std::nullopt,
        options.paper_height > 0 ? std::optional<double>(options.paper_height) : std::nullopt,
        std::nullopt, std::nullopt, std::nullopt, std::nullopt, std::nullopt, std::nullopt,
        /*prefer_css_page_size=*/true, /*generate_tagged_pdf=*/false,
        /*generate_document_outline=*/false);
    if (std::holds_alternative<std::string>(params)) { Fail(ARX_PDF_INVALID); Drain(); return; }
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&printer_);
    printer_.set_disconnect_handler(base::BindOnce(&PdfRequest::Gone, weak_.GetWeakPtr()));
    print_to_pdf::PdfPrintJob::StartJob(web_contents(), frame, printer_, /*page_ranges=*/"",
        std::move(std::get<printing::mojom::PrintPagesParamsPtr>(params)),
        base::BindOnce(&PdfRequest::Printed, weak_.GetWeakPtr()));
  }

  void Source() {
    auto* frame = web_contents()->GetPrimaryMainFrame();
    const GURL url = frame->GetLastCommittedURL();
    const auto origin = url::Origin::Create(url);
    auto resource = std::make_unique<network::ResourceRequest>();
    resource->url = url;
    resource->method = "GET";
    // The tab already showed this document: a cached copy is preferred.
    resource->load_flags = net::LOAD_SKIP_CACHE_VALIDATION;
    resource->site_for_cookies = net::SiteForCookies::FromOrigin(origin);
    resource->request_initiator = origin;
    resource->trusted_params = network::ResourceRequest::TrustedParams();
    resource->trusted_params->isolation_info = net::IsolationInfo::Create(
        net::IsolationInfo::RequestType::kOther, origin, origin,
        net::SiteForCookies::FromOrigin(origin));
    loader_ = network::SimpleURLLoader::Create(std::move(resource), kPdfSourceAnnotation);
    auto* partition = web_contents()->GetBrowserContext()->GetDefaultStoragePartition();
    loader_->DownloadToString(partition->GetURLLoaderFactoryForBrowserProcess().get(),
        base::BindOnce(&PdfRequest::Downloaded, weak_.GetWeakPtr()), maximum_bytes_);
  }

  void Fail(ArxPdfStatus status) {
    if (replied_) return;
    replied_ = true;
    timeout_.Stop();
    ReplyLater(reply_, request_, page_, status);
  }

  void DidStartNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsInPrimaryMainFrame()) Fail(ARX_PDF_STALE);
  }
  void PrimaryPageWillBeDeactivated(content::Page&) override { Fail(ARX_PDF_STALE); }
  // DEV-943: a document entering the back/forward cache keeps its frame and the
  // print pipe. Let the one physical slot go as if the frame had gone.
  void RenderFrameHostStateChanged(content::RenderFrameHost* host,
                                   content::RenderFrameHost::LifecycleState,
                                   content::RenderFrameHost::LifecycleState state) override {
    if (state == content::RenderFrameHost::LifecycleState::kInBackForwardCache &&
        host == document_.AsRenderFrameHostIfValid()) Gone();
  }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override { Gone(); }
  void WebContentsDestroyed() override { Gone(); }

 private:
  bool IsCurrent() const {
    auto* frame = document_.AsRenderFrameHostIfValid();
    return frame && web_contents() && web_contents()->GetPrimaryMainFrame() == frame;
  }

  void Deliver(const uint8_t* bytes, size_t size) {
    if (replied_) { Drain(); return; }
    if (!IsCurrent()) { Fail(ARX_PDF_STALE); Drain(); return; }
    if (!bytes || !size) { Fail(ARX_PDF_FAILED); Drain(); return; }
    if (size > maximum_bytes_) { Fail(ARX_PDF_LIMIT); Drain(); return; }
    replied_ = true;
    timeout_.Stop();
    // Posted delivery: Swift may close the page from the callback.
    std::vector<uint8_t> owned(bytes, bytes + size);
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
        [](PdfReply reply, uint64_t request, uint64_t page, std::string document,
           std::vector<uint8_t> bytes) {
          reply(request, page, ARX_PDF_SUCCESS, document.c_str(), bytes.data(), bytes.size());
        }, reply_, request_, page_, document_id_, std::move(owned)));
    Drain();
  }

  void Printed(print_to_pdf::PdfPrintResult result, scoped_refptr<base::RefCountedMemory> data) {
    if (result != print_to_pdf::PdfPrintResult::kPrintSuccess || !data) {
      Fail(result == print_to_pdf::PdfPrintResult::kPrintingInProgress ? ARX_PDF_BUSY : ARX_PDF_FAILED);
      Drain();
      return;
    }
    Deliver(data->data(), data->size());
  }

  void Downloaded(std::optional<std::string> body) {
    const auto* head = loader_ ? loader_->ResponseInfo() : nullptr;
    const bool is_pdf = head && head->mime_type == "application/pdf";
    if (!body) {
      Fail(loader_ && loader_->NetError() == net::ERR_INSUFFICIENT_RESOURCES ? ARX_PDF_LIMIT : ARX_PDF_FAILED);
      Drain();
      return;
    }
    if (!is_pdf) { Fail(ARX_PDF_UNSUPPORTED); Drain(); return; }
    Deliver(reinterpret_cast<const uint8_t*>(body->data()), body->size());
  }

  void Gone() { Fail(ARX_PDF_STALE); Drain(); }

  void Drain() {
    // The owner's address only, never followed: this can run twice, and a pointer bound into
    // the task would dangle once the first run erases the owner.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](uint64_t request, uintptr_t owner) {
          auto found = Requests().find(request);
          if (found != Requests().end() && reinterpret_cast<uintptr_t>(found->second.get()) == owner)
            Requests().erase(found);
        }, request_, reinterpret_cast<uintptr_t>(this)));
  }

  const std::string document_id_;
  const uint64_t page_, request_;
  const uint32_t maximum_bytes_;
  const PdfReply reply_;
  const content::WeakDocumentPtr document_;
  bool replied_ = false;
  mojo::AssociatedRemote<printing::mojom::PrintRenderFrame> printer_;
  std::unique_ptr<network::SimpleURLLoader> loader_;
  base::OneShotTimer timeout_;
  base::WeakPtrFactory<PdfRequest> weak_{this};
};
}  // namespace

void RequestPdf(content::WebContents* contents, const std::string& document_id, uint64_t page,
                uint64_t request, ArxPdfKind kind, ArxPdfOptions options,
                uint32_t maximum_bytes, uint32_t timeout_ms, PdfReply reply) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const bool valid_options = std::isfinite(options.scale) && options.scale >= 0 && options.scale <= 2 &&
      std::isfinite(options.paper_width) && options.paper_width >= 0 && options.paper_width <= 100 &&
      std::isfinite(options.paper_height) && options.paper_height >= 0 && options.paper_height <= 100 &&
      (options.scale == 0 || options.scale >= 0.1);
  if (!request || !maximum_bytes || maximum_bytes > kMaximumPdfBytes || !timeout_ms ||
      timeout_ms > kMaximumPdfTimeout || (kind != ARX_PDF_EXPORT && kind != ARX_PDF_SOURCE) ||
      !valid_options || Requests().contains(request)) {
    ReplyLater(reply, request, page, ARX_PDF_INVALID);
    return;
  }
  // ABI56 (DEV-971): a private page only for the app's own Print and Save as PDF.
  if (!contents || contents->IsBeingDestroyed() || contents->IsCrashed() ||
      (contents->GetBrowserContext()->IsOffTheRecord() && !options.allows_private)) {
    ReplyLater(reply, request, page, ARX_PDF_UNAVAILABLE);
    return;
  }
  auto* frame = contents->GetPrimaryMainFrame();
  if (!frame || !frame->IsRenderFrameLive() || contents->IsLoading()) {
    ReplyLater(reply, request, page, ARX_PDF_UNAVAILABLE);
    return;
  }
  const bool is_pdf = contents->GetContentsMimeType() == "application/pdf";
  if (!frame->GetLastCommittedURL().SchemeIsHTTPOrHTTPS() || frame->IsErrorDocument() ||
      (kind == ARX_PDF_SOURCE) != is_pdf) {
    ReplyLater(reply, request, page, ARX_PDF_UNSUPPORTED);
    return;
  }
  // One physical job at a time, like the capture slot.
  if (!Requests().empty()) { ReplyLater(reply, request, page, ARX_PDF_BUSY); return; }
  auto& owned = Requests()[request];
  owned = std::make_unique<PdfRequest>(contents, document_id, page, request, maximum_bytes,
                                       timeout_ms, reply);
  if (kind == ARX_PDF_EXPORT) owned->Export(options);
  else owned->Source();
}

void CancelPdf(uint64_t request) {
  auto found = Requests().find(request);
  if (found != Requests().end()) found->second->Fail(ARX_PDF_CANCELLED);
}

void StopPdfs() { Requests().clear(); }
}  // namespace arx
