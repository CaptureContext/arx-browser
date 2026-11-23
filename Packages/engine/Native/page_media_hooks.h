#ifndef ARX_PAGE_MEDIA_HOOKS_H_
#define ARX_PAGE_MEDIA_HOOKS_H_

// DEV-1144. Dependency-free so ChromeContentBrowserClient can include it
// (page_media_overlay.py); defined in page_media_bridge.mm.
namespace blink { class AssociatedInterfaceRegistry; }
namespace content { class RenderFrameHost; }

namespace arx {
// Adds the page media bridge's PageMediaHost binder for `frame`. The binder
// accepts only an Arx page's primary main frame whose committed origin is
// bridged, and scopes the receiver to that frame's current document.
void RegisterPageMediaBinders(content::RenderFrameHost& frame,
                              blink::AssociatedInterfaceRegistry& registry);
}  // namespace arx

#endif  // ARX_PAGE_MEDIA_HOOKS_H_
