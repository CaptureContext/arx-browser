// Copyright 2026 CaptureContext. Arx (DEV-1193).
//
// Copied to //third_party/blink/renderer/core/loader/ by
// browser_scheme_link_overlay.py. Header-only, so core's BUILD.gn is unchanged.

#ifndef THIRD_PARTY_BLINK_RENDERER_CORE_LOADER_ARX_BROWSER_SCHEME_LINK_H_
#define THIRD_PARTY_BLINK_RENDERER_CORE_LOADER_ARX_BROWSER_SCHEME_LINK_H_

#include "mojo/public/cpp/bindings/remote.h"
#include "third_party/blink/public/platform/browser_interface_broker_proxy.h"
#include "third_party/blink/public/mojom/arx/browser_scheme_link.mojom-blink.h"
#include "third_party/blink/renderer/core/frame/local_frame.h"
#include "third_party/blink/renderer/platform/weborigin/kurl.h"

namespace blink {

// Blink refuses a web page's chrome:// link before the browser hears of it.
// While `frame` has the person's activation, tell the browser, which hands the
// link to Arx's app; the navigation stays refused either way. Called at each
// "Not allowed to load local resource" refusal of a navigation: a link or
// location change in the frame, a new window, and a navigation of a remote
// frame. Other refused schemes (file:, chrome-untrusted:) report nothing.
inline void ArxReportRefusedBrowserLink(LocalFrame* frame, const KURL& url) {
  if (!frame || !url.ProtocolIs("chrome") ||
      !LocalFrame::HasTransientUserActivation(frame)) {
    return;
  }
  mojo::Remote<mojom::blink::ArxBrowserSchemeLinkHost> host;
  frame->GetBrowserInterfaceBroker().GetInterface(
      host.BindNewPipeAndPassReceiver());
  // Sent before the remote goes; the browser binds the receiver and reads it.
  host->ReportRefusedLink(url);
}

}  // namespace blink

#endif  // THIRD_PARTY_BLINK_RENDERER_CORE_LOADER_ARX_BROWSER_SCHEME_LINK_H_
