"""Let a web notification's click find its tab in Arx (ABI55, DEV-885).

Chrome shows site notifications through its Mac notification bridge (banners
in the browser process, alerts through the Alerts helper) and Arx keeps that.
Three places assume Chrome's own browser windows, which Arx pages don't have:

* `NotificationDisplayServiceImpl::ProcessNotificationOperation` runs a
  click; its completion is wrapped so the app hears when the click ends.
* `NotificationDisplayServiceImpl::Display` drops sites' notifications in
  unattended (headless) runs, where nobody sees Notification Center.
* `NonPersistentNotificationHandler::DidDispatchClickEvent` opens the origin
  with `Navigate()` when the page that made the notification is gone; Arx
  takes that and the app opens or finds the site's tab.
* `ChromeContentBrowserClient::OpenURL`, which service workers'
  `clients.openWindow()` reaches, would open a Chrome browser window; Arx
  answers it with a page the app adopts as a tab.
* `MacNotificationProviderImpl::BindNotificationService` gives the browser
  process's banners to the deprecated `NSUserNotificationCenter`, which on
  macOS 27 takes `deliverNotification:` and keeps nothing: no banner and
  nothing in Notification Center. The in-process provider uses Chromium's
  `UNUserNotificationCenter` service instead, as web app shims do; the Alerts
  helper (out of process) keeps its own.

The code lives in `Native/engine_bridge.mm` behind
`Native/notification_bridge.h`. Every insertion is guarded by
`BUILDFLAG(IS_MAC)` and anchored on upstream lines only.
"""
from .overlay import replace_once

DISPLAY = "chrome/browser/notifications/notification_display_service_impl.cc"
NON_PERSISTENT = "chrome/browser/notifications/non_persistent_notification_handler.cc"
CLIENT = "chrome/browser/chrome_content_browser_client.cc"
PROVIDER = "chrome/services/mac_notifications/mac_notification_provider_impl.mm"
INCLUDE = '#include "chrome/browser/arx/notification_bridge.h"  // nogncheck\n'


def patches():
    yield DISPLAY, '#include "chrome/browser/notifications/notification_display_service_impl.h"\n', \
        '#include "chrome/browser/notifications/notification_display_service_impl.h"\n' \
        '#if BUILDFLAG(IS_MAC)\n' + INCLUDE + '#endif\n'
    yield DISPLAY, """    case NotificationOperation::kClick:
      handler->OnClick(profile_, origin, notification_id, action_index, reply,
                       std::move(on_completed_cb));""", """    case NotificationOperation::kClick:
#if BUILDFLAG(IS_MAC)
      // Arx (ABI55, DEV-885): the app hears when a site's click ends.
      if (notification_type == NotificationHandler::Type::WEB_PERSISTENT ||
          notification_type == NotificationHandler::Type::WEB_NON_PERSISTENT) {
        on_completed_cb = arx::WrapNotificationClick(
            profile_,
            notification_type == NotificationHandler::Type::WEB_PERSISTENT,
            origin, std::move(on_completed_cb));
      }
#endif
      handler->OnClick(profile_, origin, notification_id, action_index, reply,
                       std::move(on_completed_cb));"""

    # Headless and other unattended runs (DEV-885): nobody sees Notification
    # Center, so a site's notification is dropped before it posts.
    yield DISPLAY, """  CHECK(profile_ || notification_type == NotificationHandler::Type::TRANSIENT);

  if (!bridge_delegator_initialized_) {
    actions_.push(base::BindOnce(&NotificationDisplayServiceImpl::Display,""", """  CHECK(profile_ || notification_type == NotificationHandler::Type::TRANSIENT);

#if BUILDFLAG(IS_MAC)
  if ((notification_type == NotificationHandler::Type::WEB_PERSISTENT ||
       notification_type == NotificationHandler::Type::WEB_NON_PERSISTENT) &&
      arx::RefusesWebNotifications()) {
    return;
  }
#endif

  if (!bridge_delegator_initialized_) {
    actions_.push(base::BindOnce(&NotificationDisplayServiceImpl::Display,"""

    yield NON_PERSISTENT, '#include "chrome/browser/notifications/non_persistent_notification_handler.h"\n', \
        '#include "chrome/browser/notifications/non_persistent_notification_handler.h"\n' \
        '#if BUILDFLAG(IS_MAC)\n' + INCLUDE + '#endif\n'
    yield NON_PERSISTENT, """    params.window_action = NavigateParams::WindowAction::kShowWindow;
    Navigate(&params);""", """    params.window_action = NavigateParams::WindowAction::kShowWindow;
#if BUILDFLAG(IS_MAC)
    // Arx (ABI55, DEV-885) has no Chrome browser window to open it in: the
    // app opens or finds the site's tab when the click ends.
    if (!arx::TakeNotificationOrigin(profile, origin))
#endif
    Navigate(&params);"""

    # content_host_overlay.py extends the client's own include line; anchor elsewhere.
    yield CLIENT, '#include "chrome/browser/browser_process.h"\n', \
        '#include "chrome/browser/browser_process.h"\n' \
        '#if BUILDFLAG(IS_MAC)\n' + INCLUDE + '#endif\n'
    yield CLIENT, """#else
  NavigateParams nav_params(Profile::FromBrowserContext(browser_context),
                            params.url, params.transition);
  nav_params.FillNavigateParamsFromOpenURLParams(params);""", """#else
#if BUILDFLAG(IS_MAC)
  // Arx (ABI55, DEV-885): a service worker's openWindow() opens an Arx tab,
  // never a Chrome browser window.
  if (arx::OpenServiceWorkerWindow(browser_context, params, callback)) {
    return;
  }
#endif
  NavigateParams nav_params(Profile::FromBrowserContext(browser_context),
                            params.url, params.transition);
  nav_params.FillNavigateParamsFromOpenURLParams(params);"""


    # The browser process's banners (DEV-885, macOS 27): NSUserNotificationCenter
    # delivers nothing there. The in-process provider is the one made without a
    # bound receiver (`LaunchInProcessProvider`); the Alerts helper binds its own.
    yield PROVIDER, """    mojo::PendingRemote<mojom::MacNotificationActionHandler> handler) {
  DCHECK(!service_);
""", """    mojo::PendingRemote<mojom::MacNotificationActionHandler> handler) {
  DCHECK(!service_);

  // Arx (DEV-885): on macOS 27 NSUserNotificationCenter takes a banner and
  // keeps nothing, so the browser process's banners go through
  // UNUserNotificationCenter, as web app shims' do. The Alerts helper, which
  // binds its own receiver, keeps NSUserNotificationCenter.
  if (!binding_.is_bound()) {
    auto service_un = std::make_unique<MacNotificationServiceUN>(
        std::move(handler), base::DoNothing(),
        UNUserNotificationCenter.currentNotificationCenter);
    service_un->Bind(std::move(service));
    service_un->RequestPermission(base::DoNothing());
    service_ = std::move(service_un);
    return;
  }
"""


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
