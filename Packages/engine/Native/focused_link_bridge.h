#ifndef ARX_FOCUSED_LINK_BRIDGE_H
#define ARX_FOCUSED_LINK_BRIDGE_H

#include <cstddef>
#include <cstdint>

#include "chrome/browser/arx/ChromiumBridge.h"

namespace content { class WebContents; }

namespace arx {
// url is NULL when the page has no focused link Arx can open.
using FocusedLinkReply = void (*)(uint64_t request, uint64_t page, uint64_t document_generation,
                                  const char* url, size_t url_size);

// ABI37 (DEV-713). Reads the keyboard-focused link of an ordinary, visible
// HTTP(S) page: document.activeElement of the focused frame (any origin), then
// its closest a[href] or area[href], in a Chrome-internal isolated world.
// Replies once, never synchronously; generation is the page's document
// generation when asked. A navigation, a hidden view, a closed page or no
// answer within the timeout replies without a URL.
void RequestFocusedLink(content::WebContents* contents, uint64_t page, uint64_t request,
                        uint64_t generation, FocusedLinkReply reply);
}  // namespace arx

#endif
