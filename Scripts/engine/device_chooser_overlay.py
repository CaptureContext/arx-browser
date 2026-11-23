"""Give Arx the WebUSB, WebHID, Web Serial and Web Bluetooth choosers (DEV-905).

Chrome shows every device chooser through `chrome::ShowDeviceChooserDialog`,
which anchors a bubble to the requesting tab's browser window. An Arx page has
no Chrome browser window, so Chrome found no host and cancelled every request:
firmware flashers, security key setup pages and Arduino tools couldn't connect.

This overlay calls an embedder handler first. The handler is declared in the
dependency-free `chrome/browser/arx/device_chooser_hooks.h`; its setter is
defined here, next to its call site. `device_chooser_bridge.mm` takes choosers
for Arx pages and leaves every other one to Chrome.

If an anchor changes, the build stops.
"""
from .overlay import replace_once

SOURCE = "chrome/browser/ui/views/permissions/chooser_bubble_ui.cc"

HOOKS = '#include "chrome/browser/arx/device_chooser_hooks.h"  // nogncheck\n'


def patches():
    yield SOURCE, '#include "chrome/browser/ui/dialogs/browser_dialogs.h"\n', (
        '#include "chrome/browser/ui/dialogs/browser_dialogs.h"\n' + HOOKS)
    yield SOURCE, '''base::OnceClosure ShowDeviceChooserDialog(
    content::RenderFrameHost* owner,
    std::unique_ptr<permissions::ChooserController> controller) {
''', '''}  // namespace chrome

namespace {
arx::DeviceChooserHandler g_arx_device_chooser = nullptr;
}  // namespace

void arx::SetDeviceChooserHandler(DeviceChooserHandler handler) {
  g_arx_device_chooser = handler;
}

namespace chrome {

base::OnceClosure ShowDeviceChooserDialog(
    content::RenderFrameHost* owner,
    std::unique_ptr<permissions::ChooserController> controller) {
  // Arx (DEV-905): an embedder page has no browser window to anchor a bubble;
  // the embedder shows its own chooser, or cancels it when nobody can answer.
  if (g_arx_device_chooser) {
    base::OnceClosure close;
    if (g_arx_device_chooser(owner, controller, &close)) {
      return close;
    }
  }
'''


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
