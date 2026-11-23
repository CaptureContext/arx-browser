#ifndef ARX_NOTIFICATION_BRIDGE_H
#define ARX_NOTIFICATION_BRIDGE_H

#include "base/functional/callback.h"

class GURL;
class Profile;
namespace content {
class BrowserContext;
class WebContents;
struct OpenURLParams;
}  // namespace content

namespace arx {
// ABI55 (DEV-885). Web notification clicks. Declared apart from
// engine_bridge.h so Chrome's notification and content-client targets need
// only this; the code lives in engine_bridge.mm.
//
// A click on a site's notification is "in flight" for its ordinary profile and
// origin from NotificationDisplayServiceImpl's click until shortly after its
// completion. Only then may the site's page or service worker bring a tab
// forward (window.focus(), client.focus()) or open one (clients.openWindow());
// generic window.focus() still does nothing in Arx.

// True in unattended (headless) runs: nobody sees Notification Center, so
// sites' notifications are dropped before they post. Their permission prompts
// are already refused there like every other prompt.
bool RefusesWebNotifications();

// Wraps the click's completion. When the click ends, the app hears which
// profile and origin it was for, whether the page or its service worker
// already showed a tab, and whether the notification outlived its page.
// Returns `completed` unchanged for clicks Arx doesn't follow (private
// profiles, no app consumer).
base::OnceClosure WrapNotificationClick(Profile* profile, bool persistent,
                                        const GURL& origin,
                                        base::OnceClosure completed);

// A non-persistent notification outlived the document that showed it. Chrome
// opens `origin` in a new browser tab with Navigate(); true when Arx takes it
// instead: the app opens or finds the site's tab when the click ends.
bool TakeNotificationOrigin(Profile* profile, const GURL& origin);

// ChromeContentBrowserClient::OpenURL, which service workers' openWindow()
// reaches. Embedded, Arx always answers `callback` and returns true: with a
// new page the app adopted as a tab during a notification click for the
// worker's origin, or with nullptr. Stock Chrome returns false and keeps its
// own path.
bool OpenServiceWorkerWindow(
    content::BrowserContext* context,
    const content::OpenURLParams& params,
    base::OnceCallback<void(content::WebContents*)>& callback);
}  // namespace arx

#endif
