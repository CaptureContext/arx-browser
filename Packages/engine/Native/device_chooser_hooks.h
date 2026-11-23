#ifndef ARX_DEVICE_CHOOSER_HOOKS_H_
#define ARX_DEVICE_CHOOSER_HOOKS_H_

#include <memory>

#include "base/functional/callback_forward.h"

// DEV-905. Dependency-free so Chrome's chooser_bubble_ui.cc can include it; the
// setter is defined next to its call site by device_chooser_overlay.py.
namespace content { class RenderFrameHost; }
namespace permissions { class ChooserController; }

namespace arx {
// Called on the UI thread for every WebUSB, WebHID, Web Serial and Web
// Bluetooth chooser before Chrome looks for a browser window to anchor its
// bubble (an Arx page has none, so Chrome would cancel it). Returning true
// takes `controller` and sets `close` to what closes the embedder's chooser;
// false leaves both for Chrome.
using DeviceChooserHandler =
    bool (*)(content::RenderFrameHost* owner,
             std::unique_ptr<permissions::ChooserController>& controller,
             base::OnceClosure* close);
void SetDeviceChooserHandler(DeviceChooserHandler handler);
}  // namespace arx

#endif  // ARX_DEVICE_CHOOSER_HOOKS_H_
