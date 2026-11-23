// Copied by Scripts/engine/live_connection_overlay.py to
// content/public/browser/arx_live_connection.h.

#ifndef CONTENT_PUBLIC_BROWSER_ARX_LIVE_CONNECTION_H_
#define CONTENT_PUBLIC_BROWSER_ARX_LIVE_CONNECTION_H_

#include "base/feature_list.h"
#include "content/common/content_export.h"

namespace content {

class RenderFrameHost;
class WebContents;

// DEV-879: a page holding a WebSocket or WebTransport connection is neither
// frozen by infinite tabs freezing nor unloaded by Arx, because both end the
// connection: Blink fails a WebSocket and closes a WebTransport session when
// its frame freezes, and an unload discards the document. On by default;
// ARX_SPARE_LIVE_CONNECTIONS=off turns it off to weigh its CPU cost.
CONTENT_EXPORT BASE_DECLARE_FEATURE(kArxSpareLiveConnections);

// Whether the document in `frame` has opened a WebSocket or WebTransport
// connection. Read from the frame's back/forward cache features: with
// DisconnectWebSocketOnBFCache (stable) Blink reports a WebSocket only as the
// sticky feature, so this stays true until the frame's document is replaced,
// even after the page closes the connection. WebRTC is Chromium's own
// CannotFreezeReason::kWebRTC. UI thread.
CONTENT_EXPORT bool ArxFrameHoldsLiveConnection(RenderFrameHost* frame);

// ArxFrameHoldsLiveConnection for any frame of the primary page, and
// kArxSpareLiveConnections is on. UI thread.
CONTENT_EXPORT bool ArxPageHoldsLiveConnection(WebContents* contents);

}  // namespace content

#endif  // CONTENT_PUBLIC_BROWSER_ARX_LIVE_CONNECTION_H_
