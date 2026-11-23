#ifndef ARX_PAGE_CAPTURE_BRIDGE_H_
#define ARX_PAGE_CAPTURE_BRIDGE_H_

#include <stddef.h>
#include <stdint.h>

#include "chrome/browser/arx/ChromiumBridge.h"

namespace content { class WebContents; }

// DEV-1172. The whole page, rendered beyond the viewport the way DevTools'
// "Capture full size screenshot" renders it. ArxPageCaptureLimits,
// ArxPageCaptureSnapshot and ArxPageCaptureCallback are in ChromiumBridge.h,
// outside the ABI table.

namespace arx {
// Whether this capture is reading `contents` until its DevTools work has
// physically returned (DEV-1125's CapturesPage). Main thread.
bool CapturesWholePage(content::WebContents* contents);
// Shutdown only.
void StopWholePageCaptures();
}  // namespace arx

extern "C" {
// Main thread. Captures Arx page `page` while it's shown. False, and no callback,
// when the engine isn't running, the page isn't an Arx page, `done` is null or
// `limits` are out of range. Otherwise `done` runs exactly once, later, on the
// main thread: ARX_CAPTURE_BUSY while another capture holds the engine's one
// capture slot, ARX_CAPTURE_UNAVAILABLE for a page that isn't shown,
// ARX_CAPTURE_STALE when the page navigated, closed or moved, ARX_CAPTURE_LIMIT
// when even one row exceeds the limits or the PNG is too large,
// ARX_CAPTURE_UNSUPPORTED when DevTools is open on the page or Chromium's
// capture failed or came back another size, ARX_CAPTURE_TIMEOUT, or ARX_CAPTURE_CANCELLED. A capture timed out or
// canceled after its screenshot was asked for keeps the slot until Chromium's
// screenshot returns, so the page's size is always restored first.
__attribute__((visibility("default")))
bool ArxEngineCaptureWholePage(uint64_t page, uint64_t request, const ArxPageCaptureLimits* limits,
                               ArxPageCaptureCallback done, void* context);

// Main thread. Completes `request` with ARX_CAPTURE_CANCELLED if it's in flight.
__attribute__((visibility("default")))
void ArxEngineCancelWholePageCapture(uint64_t request);
}

#endif  // ARX_PAGE_CAPTURE_BRIDGE_H_
