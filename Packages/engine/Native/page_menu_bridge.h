#ifndef ARX_PAGE_MENU_BRIDGE_H
#define ARX_PAGE_MENU_BRIDGE_H

#include <stddef.h>

#include <memory>
#include <string>

#include "chrome/browser/arx/ChromiumBridge.h"

class GURL;
namespace base { class FilePath; }
namespace content {
struct ContextMenuParams;
class WebContents;
}

namespace arx {
class ExtensionMenuItems;

// ABI45 (DEV-795). The app's titles for the page menu, one per
// ArxPageMenuItem, copied. Fewer titles, or an empty one, turn the menu off.
void ConfigurePageMenu(const char* const* titles, size_t count);
bool PageMenuConfigured();

// A right click on the page itself: no link, editable field, selection, image
// or media under the pointer. Those keep the menus they had before.
bool IsPageMenuContext(const content::ContextMenuParams& params);

// What the person chose in RunPageMenu.
inline constexpr int kPageMenuNothing = -1;
inline constexpr int kPageMenuInspect = ARX_PAGE_MENU_ITEM_COUNT;
// DEV-927: Cast…, native like Inspect Element, shown while the page can cast
// (cast_bridge.h CastMenuTitle). Outside ArxPageMenuItem, so the ABI is unchanged.
inline constexpr int kPageMenuCast = ARX_PAGE_MENU_ITEM_COUNT + 1;

// Shows Back, Forward, Reload, Save Page As…, Print…, Share… (ABI48) and View
// Page Source when
// host_items (a mask of 1u << ArxPageMenuItem the app allows) isn't zero, each
// enabled only when the host and the page both allow it, and Inspect Element
// (inspect_title) when it isn't empty,
// at view point (x, y) in root-view DIP coordinates, inside AppKit's nested
// tracking loop. Returns the chosen ArxPageMenuItem, kPageMenuInspect or
// kPageMenuNothing. The contents may be gone when it returns: callers keep a
// weak pointer and check it before touching anything.
//
// DEV-890: with `params` and `extensions`, extensions' chrome.contextMenus
// items for the page come before Inspect Element. A chosen one returns its tag
// (ExtensionMenuItems::IsCommand) and leaves the items in `extensions` for the
// caller to run once it has rechecked the frame.
int RunPageMenu(content::WebContents* contents, uint32_t host_items,
                const std::string& inspect_title, int x, int y,
                const content::ContextMenuParams* params = nullptr,
                std::shared_ptr<ExtensionMenuItems>* extensions = nullptr);

// Save Page As through Chromium's SavePackage: HTML only, complete (with a
// "<name>_files" folder beside it) or MHTML. Only an http(s) page and an
// absolute path. The save shows up as a download in the page's profile.
bool SavePageAs(content::WebContents* contents, const base::FilePath& path, ArxSavePageKind kind);

// The addresses the app may load on its own besides the ordinary web: the
// source of an http(s) page (view-source:), a local file the person chose
// with Open File (file:) and an allowlisted diagnostic page (chrome://gpu and
// the like, DEV-898).
bool UserNavigationURL(const GURL& url);

// chrome://version, gpu, net-internals, process-internals, media-internals,
// serviceworker-internals, webrtc-internals and inspect, without credentials,
// a port or a query (DEV-898).
bool DiagnosticPageURL(const GURL& url);
}  // namespace arx

#endif
