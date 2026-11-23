#ifndef ARX_CAST_BRIDGE_H
#define ARX_CAST_BRIDGE_H

#include <stdint.h>

#include <string>

namespace content {
class WebContents;
}

namespace arx {

// DEV-927. Chrome's Media Router finds Cast (mDNS) and DIAL (SSDP) devices and
// casts to them; Arx draws the device picker. Every WebContents' Media Router
// dialog is Arx's (cast_hooks.h): a site's Cast button (the Presentation API,
// which Google's Cast SDK uses) and the page menu open it, and the app reads
// its devices as JSON through the handler below.
//
// Headless runs start the engine with the MediaRouter feature off, so nothing
// is discovered and a site's request fails at once with "No screens found".

// Installs the picker as Chromium's Media Router dialog. Once, from
// EngineParts::PreProfileInit.
void StartCastPicker();

// The page menu's Cast… title when |contents| is an Arx page that can cast
// now, else empty.
std::string CastMenuTitle(content::WebContents* contents);

// Opens the picker for |contents| (the page menu, the app's media controls).
// False when the page can't cast or nobody shows pickers.
bool ShowCastPicker(content::WebContents* contents);

}  // namespace arx

// Main thread, outside the ABI table: the app looks them up with dlsym and
// casts nothing on an engine built before them.
extern "C" {

// The app's picker. The handler gets a page's picker as JSON each time it
// changes, and NULL when it closes:
//   {"source": "…", "presentation": bool, "permissionRejected": bool,
//    "devices": [{"id": "…", "name": "…", "status": "…", "issue": "…",
//                 "state": "available" | "connecting" | "connected" |
//                          "disconnecting" | "unavailable",
//                 "icon": "cast" | "audio" | "audioGroup" | "display" |
//                         "generic",
//                 "modes": [1 presentation, 2 tab mirroring], "route": "…"}]}
// "presentation" is true when a site's Cast button opened it. "status" (the
// route's description), "issue" and "route" may be absent. Reports are posted,
// never sent while the engine is inside the Media Router, so the handler may
// call the functions below. menu_title is the page menu's Cast… item; NULL or
// empty leaves it out. A NULL handler closes every picker and refuses new
// ones.
__attribute__((visibility("default"))) void ArxEngineSetCastPickerHandler(
    void (*handler)(void* context, uint64_t page, const char* json),
    void* context,
    const char* menu_title);

// Opens the page's picker, or reports it again when it's open already. False
// when the page can't cast.
__attribute__((visibility("default"))) bool ArxEngineShowCastPicker(
    uint64_t page);

// Chooses a device in the page's open picker: mode 1 casts the site's own
// presentation, 2 mirrors the tab, 0 picks as Chrome does (the site's
// presentation when the device takes it, else the tab). A device showing an
// issue clears the issue instead. False when the picker, device or mode isn't
// there.
__attribute__((visibility("default"))) bool ArxEngineChooseCastDevice(
    uint64_t page,
    const char* device,
    int32_t mode);

// Stops a route the page's open picker lists. False when it isn't listed.
__attribute__((visibility("default"))) bool ArxEngineStopCasting(
    uint64_t page,
    const char* route);

// Closes the page's picker. A site's request that chose nothing fails, as
// when Chrome's dialog closes.
__attribute__((visibility("default"))) void ArxEngineCloseCastPicker(
    uint64_t page);

}  // extern "C"

#endif  // ARX_CAST_BRIDGE_H
