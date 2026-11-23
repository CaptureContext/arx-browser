"""Web notification clicks reach Arx's tabs (ABI55, DEV-885).

Runs the overlay against the pinned Chromium files when a prepared tree is on
this Mac, and against the upstream anchors otherwise.
"""

from pathlib import Path
import shutil
import tempfile
import unittest

from Scripts.engine import notification_overlay
from Scripts.engine.config import SOURCE

UPSTREAM = {
    notification_overlay.DISPLAY: '''#include "chrome/browser/notifications/notification_display_service_impl.h"

  CHECK(profile_ || notification_type == NotificationHandler::Type::TRANSIENT);

  if (!bridge_delegator_initialized_) {
    actions_.push(base::BindOnce(&NotificationDisplayServiceImpl::Display,

  switch (operation) {
    case NotificationOperation::kClick:
      handler->OnClick(profile_, origin, notification_id, action_index, reply,
                       std::move(on_completed_cb));
      break;
''',
    notification_overlay.NON_PERSISTENT: '''#include "chrome/browser/notifications/non_persistent_notification_handler.h"

  if (!success) {
    NavigateParams params(profile, origin, ui::PAGE_TRANSITION_LINK);

    params.disposition = WindowOpenDisposition::NEW_FOREGROUND_TAB;
    params.window_action = NavigateParams::WindowAction::kShowWindow;
    Navigate(&params);
''',
    notification_overlay.CLIENT: '''#include "chrome/browser/chrome_content_browser_client.h"
#include "chrome/browser/browser_process.h"

#if BUILDFLAG(IS_ANDROID)
  ServiceTabLauncher::GetInstance()->LaunchTab(browser_context, params,
                                               std::move(callback));
#else
  NavigateParams nav_params(Profile::FromBrowserContext(browser_context),
                            params.url, params.transition);
  nav_params.FillNavigateParamsFromOpenURLParams(params);

  Navigate(&nav_params);
#endif
''',
    notification_overlay.PROVIDER: '''#import "chrome/services/mac_notifications/mac_notification_provider_impl.h"

void MacNotificationProviderImpl::BindNotificationService(
    mojo::PendingReceiver<mojom::MacNotificationService> service,
    mojo::PendingRemote<mojom::MacNotificationActionHandler> handler) {
  DCHECK(!service_);

  service_ = std::make_unique<MacNotificationServiceNS>(
      std::move(service), std::move(handler),
      [NSUserNotificationCenter defaultUserNotificationCenter]);
}
''',
}


def prepare(root):
    for relative, text in UPSTREAM.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        pinned = SOURCE / relative
        if pinned.exists():
            shutil.copyfile(pinned, path)
        else:
            path.write_text(text)


class NotificationOverlayTests(unittest.TestCase):
    def test_applies_once_and_is_repeatable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            notification_overlay.apply(root)
            first = {relative: (root / relative).read_text() for relative in UPSTREAM}
            notification_overlay.apply(root)
            for relative, text in first.items():
                self.assertEqual(text, (root / relative).read_text(), relative)
                if relative != notification_overlay.PROVIDER:
                    self.assertEqual(text.count('#include "chrome/browser/arx/notification_bridge.h"'), 1)

    def test_routes_clicks_origins_and_windows_through_arx(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            notification_overlay.apply(root)
            display = (root / notification_overlay.DISPLAY).read_text()
            click = display.index("arx::WrapNotificationClick(")
            self.assertLess(click, display.index("handler->OnClick(profile_, origin"))
            self.assertIn("NotificationHandler::Type::WEB_PERSISTENT ||", display)
            self.assertIn("arx::RefusesWebNotifications()", display)
            self.assertLess(display.index("arx::RefusesWebNotifications()"), display.index("if (!bridge_delegator_initialized_)"))

            handler = (root / notification_overlay.NON_PERSISTENT).read_text()
            self.assertIn("if (!arx::TakeNotificationOrigin(profile, origin))\n#endif\n    Navigate(&params);", handler)

            client = (root / notification_overlay.CLIENT).read_text()
            taken = client.index("arx::OpenServiceWorkerWindow(browser_context, params, callback)")
            self.assertLess(taken, client.index("NavigateParams nav_params("))


    def test_browser_process_banners_use_user_notifications(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            notification_overlay.apply(root)
            provider = (root / notification_overlay.PROVIDER).read_text()
            un = provider.index("std::make_unique<MacNotificationServiceUN>(")
            self.assertLess(provider.index("if (!binding_.is_bound()) {"), un)
            self.assertLess(un, provider.index("std::make_unique<MacNotificationServiceNS>("))
            self.assertIn("UNUserNotificationCenter.currentNotificationCenter", provider)
            self.assertEqual(provider.count("service_un->RequestPermission(base::DoNothing());"), 1)


if __name__ == "__main__":
    unittest.main()
