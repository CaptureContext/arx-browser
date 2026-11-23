#ifndef ARX_BROWSER_SCHEME_LINK_HOOKS_H_
#define ARX_BROWSER_SCHEME_LINK_HOOKS_H_

// DEV-1193. Dependency-free apart from the mojom, so
// chrome_browser_interface_binders.cc can include it.
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "third_party/blink/public/mojom/arx/browser_scheme_link.mojom-forward.h"

namespace content { class RenderFrameHost; }

namespace arx {
// Binds a frame's report of a chrome:// link Blink refused. Registered for
// every frame by PopulateChromeFrameBinders (browser_scheme_link_overlay.py).
void BindBrowserSchemeLinkHost(
    content::RenderFrameHost* frame,
    mojo::PendingReceiver<blink::mojom::ArxBrowserSchemeLinkHost> receiver);
}  // namespace arx

#endif  // ARX_BROWSER_SCHEME_LINK_HOOKS_H_
