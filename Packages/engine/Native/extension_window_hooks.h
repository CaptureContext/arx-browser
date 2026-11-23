#ifndef ARX_EXTENSION_WINDOW_HOOKS_H_
#define ARX_EXTENSION_WINDOW_HOOKS_H_

#include "base/functional/callback_forward.h"

// DEV-1240. Dependency-free so Chrome's windows_api.cc can include it
// (extension_window_create_overlay.py); extension_window_bridge.mm defines
// these. An Arx page has no Chrome browser window, so chrome.windows.create had
// nowhere to put an extension's own window (1Password's pop-out and unlock
// window): Arx shows it in Little Arx instead.
//
// DEV-1314. chrome.tabs.create from an extension found no Chrome browser
// window either and answered "No current window", so nothing opened: an
// extension that opens its own page in a tab (1Password's welcome and sign-in
// page, when its toolbar button has no popup) showed nothing. The page opens
// the same way as a window (extension_tab_create_overlay.py).
class GURL;
namespace content { class BrowserContext; class WebContents; }
namespace extensions { class Extension; }

namespace arx {
// Runs once with the new window's ID (an embedder window, as windows.get lists
// it), or extension_misc::kUnknownWindowId when it didn't open.
using ExtensionWindowOpened = base::OnceCallback<void(int window_id)>;

// windows.create from `extension`, running in an ordinary Arx profile, for one
// page of its own. True when Arx took the request: `opened` runs later, always.
// False leaves the request, and `opened`, to Chrome.
bool OpenExtensionWindow(content::BrowserContext* context,
                         const extensions::Extension& extension,
                         const GURL& url,
                         ExtensionWindowOpened& opened);

// windows.update and windows.remove for a window that OpenExtensionWindow
// opened in `context`; false when `window_id` isn't one. An update brings the
// window forward with the keyboard when `focus` is set and changes nothing else.
bool UpdateExtensionWindow(content::BrowserContext* context, int window_id, bool focus);
bool RemoveExtensionWindow(content::BrowserContext* context, int window_id);

// Runs once with the new tab's page once the app has placed it, or with null
// when it didn't open.
using ExtensionTabOpened = base::OnceCallback<void(content::WebContents* contents)>;

// tabs.create from `extension`, running in an ordinary Arx profile, for one
// page of its own, when Chrome has no browser window to put it in. True when
// Arx took the request: `opened` runs later, always. False leaves the request,
// and `opened`, to Chrome.
bool OpenExtensionTab(content::BrowserContext* context,
                      const extensions::Extension& extension,
                      const GURL& url,
                      ExtensionTabOpened& opened);
}  // namespace arx

#endif  // ARX_EXTENSION_WINDOW_HOOKS_H_
