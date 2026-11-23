#ifndef ARX_PDF_BRIDGE_H
#define ARX_PDF_BRIDGE_H

#include <string>
#include "chrome/browser/arx/ChromiumBridge.h"

namespace content { class WebContents; }

namespace arx {
using PdfReply = void (*)(uint64_t request, uint64_t page, ArxPdfStatus status,
                          const char* document_id, const uint8_t* bytes, size_t size);
// ABI26. Export prints the primary main frame of an ordinary HTTP(S) page to
// PDF; source reads the bytes of a page showing a PDF document. Both reply
// once, never synchronously, and reject private pages.
void RequestPdf(content::WebContents* contents, const std::string& document_id, uint64_t page,
                uint64_t request, ArxPdfKind kind, ArxPdfOptions options,
                uint32_t maximum_bytes, uint32_t timeout_ms, PdfReply reply);
void CancelPdf(uint64_t request);
void StopPdfs();
}  // namespace arx

#endif
