#ifndef ARX_DEVTOOLS_BRIDGE_H_
#define ARX_DEVTOOLS_BRIDGE_H_

#include <string>

#include "chrome/browser/arx/ChromiumBridge.h"

namespace content { class RenderFrameHost; class WebContents; }

namespace arx {
// ABI19 developer tools, docked since ABI42 (DEV-733). One Arx-owned frontend
// per inspected WebContents, created in that exact BrowserContext (ordinary or
// private) and attached to its tab DevToolsAgentHost. Navigation and renderer
// replacement keep the same agent; destroying the inspected contents closes its
// frontend synchronously.
//
// The frontend is told it can dock, so its own Dock side menu works and keeps
// the side and size in the profile's DevTools preferences, as Chrome's do.
// Docked, its view is handed to the app, which lays it out behind the page at
// the bounds the frontend reports; undocked, it lives in its own window. All
// entry points run on the Chromium UI thread.
void ConfigureDevTools(const std::string& window_title, const std::string& inspect_title,
                       bool inspect_context);
bool DevToolsInspectContextEnabled();
const std::string& DevToolsInspectTitle();
// Called with the inspected contents whenever its DevTools opens, closes, docks,
// undocks or reports new page bounds. Never during CloseAllDevTools.
using DevToolsLayoutObserver = void (*)(content::WebContents* inspected);
void SetDevToolsLayoutObserver(DevToolsLayoutObserver observer);
ArxDevToolsStatus OpenDevTools(content::WebContents* inspected);
// Opens (or shows) DevTools at a panel: "elements", "console", "network",
// "sources" and the like.
ArxDevToolsStatus ShowDevToolsPanel(content::WebContents* inspected, const std::string& panel);
// Opens DevTools and starts Inspect Element's picker in the page.
ArxDevToolsStatus StartDevToolsInspectMode(content::WebContents* inspected);
// Root-view DIP coordinates from ContextMenuParams; the frame must belong to inspected.
ArxDevToolsStatus InspectElement(content::WebContents* inspected,
                                 content::RenderFrameHost* frame, int x, int y);
bool CloseDevTools(content::WebContents* inspected);
bool DevToolsIsOpen(content::WebContents* inspected);
// The bundled frontend finished loading and attached to the inspected page's
// target (its readyForTest), so its panels show the page (DEV-785).
bool DevToolsFrontendLoaded(content::WebContents* inspected);
// False without an open DevTools for inspected.
bool ReadDevToolsLayout(content::WebContents* inspected, ArxDevToolsLayout* layout);
void CloseAllDevTools();
}  // namespace arx

#endif  // ARX_DEVTOOLS_BRIDGE_H_
