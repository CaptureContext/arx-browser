#ifndef ARX_CAPTURE_BRIDGE_H
#define ARX_CAPTURE_BRIDGE_H

#include <string>
#include "chrome/browser/arx/ChromiumBridge.h"

namespace content { class WebContents; }

namespace arx {
using CaptureReply = void (*)(uint64_t request, uint64_t page,
                             ArxCaptureStatus status, const ArxCaptureSnapshot* snapshot);
void CaptureViewport(content::WebContents* contents, const std::string& document_id,
                     uint64_t page, uint64_t request, ArxCaptureLimits limits,
                     CaptureReply reply);
using DocumentCaptureReply = void (*)(uint64_t request, uint64_t page,
    ArxCaptureStatus status, const ArxDocumentCaptureSnapshot* snapshot);
void CaptureDocument(content::WebContents* contents, const std::string& document_id,
                     uint64_t page, uint64_t request, ArxCaptureLimits limits,
                     DocumentCaptureReply reply);
// ABI26: a hidden page keeps rendering through a hidden capturer while copied.
void CaptureOffscreen(content::WebContents* contents, const std::string& document_id,
                      uint64_t page, uint64_t request, ArxCaptureLimits limits,
                      CaptureReply reply);
void CancelDocumentCapture(uint64_t request);
void CancelCapture(uint64_t request);
void StopAllCaptures();
// DEV-1125: whether Arx's own capture (viewport, hidden or document) is reading this
// page, until its work has physically returned. Another tab sharing the page, as
// into a call, isn't Arx's capture. Main thread.
bool CapturesPage(content::WebContents* contents);
// DEV-1172. Whether any viewport, hidden or document capture holds or awaits the
// engine's one capture slot. Main thread.
bool CaptureInFlight();
}

#endif
