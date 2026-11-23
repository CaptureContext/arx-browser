#ifndef ARX_HOVERED_LINK_BRIDGE_H
#define ARX_HOVERED_LINK_BRIDGE_H

#include "base/functional/callback.h"

class GURL;
namespace content { class WebContents; }

namespace arx {
// ABI60 (DEV-1118): where a plain click on the hovered link navigates.
enum class HoveredLinkTarget {
  // No frame answered with that link in time, several did, or it names a
  // browsing context that may or may not exist.
  kUnknown,
  // The page's main frame: a link in it without a target, or `_top`, or
  // `_self` / `_parent` that reach it from a frame.
  kMainFrame,
  // A frame inside the page: `_self` or `_parent` of a nested frame.
  kSubframe,
  // A new browsing context: `_blank`.
  kNewContext,
};
using HoveredLinkTargetReply = base::OnceCallback<void(HoveredLinkTarget)>;

// Asks every live frame of the page, in a Chrome-internal isolated world, for
// the link under the pointer (the deepest `:hover` element, through open
// shadow roots, then its closest a[href] or area[href] across shadow hosts) and
// that link's target (its own, else when empty the document's <base target>). The one frame whose link is
// `link` decides, once every frame has answered. Read-only. Replies once,
// posted, never synchronously; kUnknown when a frame hasn't answered in time,
// the page closed or a new document committed.
void RequestHoveredLinkTarget(content::WebContents* contents, const GURL& link,
                              HoveredLinkTargetReply reply);
}  // namespace arx

#endif
