#ifndef ARX_CAST_HOOKS_H
#define ARX_CAST_HOOKS_H

// DEV-927. Dependency-free, so Chromium's views code can include it
// (cast_overlay.py). The setter is defined next to its call site in
// chrome/browser/ui/views/chrome_browser_main_extra_parts_views.cc.

namespace content {
class WebContents;
}
namespace media_router {
class MediaRouterDialogController;
}

namespace arx {

// Returns the Media Router dialog controller for a WebContents. Never null.
using CastDialogFactory =
    media_router::MediaRouterDialogController* (*)(content::WebContents*);

// Once set, Chrome's views Cast dialog is never made: every WebContents gets
// Arx's Cast picker (cast_bridge.mm), which refuses pages that aren't Arx's.
// Set before profiles load; nullptr restores Chrome's dialog.
void SetCastDialogFactory(CastDialogFactory factory);

}  // namespace arx

#endif  // ARX_CAST_HOOKS_H
