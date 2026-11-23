#ifndef ARX_EXTENSION_ACTION_HOST_H
#define ARX_EXTENSION_ACTION_HOST_H

#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include "base/functional/callback.h"
#include "chrome/browser/arx/ChromiumBridge.h"

class GURL;
namespace content { class WebContents; }
namespace input { struct NativeWebKeyboardEvent; }
enum class WindowOpenDisposition;
namespace arx {
// One ordinary source Page owns both the menu and any extension-owned popup.
// The popup keeps ExtensionViewHost's delegate and WebContents ownership.
class ExtensionActionHost {
 public:
  using Current = base::RepeatingCallback<uint64_t()>;
  using RunScoped = base::RepeatingCallback<void(base::OnceClosure)>;
  using Offer = base::RepeatingCallback<content::WebContents*(
      std::unique_ptr<content::WebContents>, const GURL&, WindowOpenDisposition)>;
  ExtensionActionHost(content::WebContents* source, Current current, RunScoped run, Offer offer);
  ~ExtensionActionHost();
  void Invalidate();
  bool HandleShortcut(const input::NativeWebKeyboardEvent& event);
  // ABI22: the open extension popup's contents, or null. With more than one
  // open (DEV-1316: a popup the person moved stays open beside another), the
  // one shown or brought forward last.
  content::WebContents* PopupContents() const;
  // DEV-1316: whether `contents` is one of this page's open popups.
  bool HostsPopup(const content::WebContents* contents) const;
  // DEV-1316: whether one of this page's popups has the keyboard. Only then is
  // the page its window's active tab for extensions, as Chrome's popup always
  // belongs to the active tab: a popup left open beside another pane doesn't.
  bool HasFocusedPopup() const;
  // ABI48 (DEV-828): the app runs an extension's action for this page, as a
  // click on its toolbar button. Its popup anchors at an AppKit screen point.
  ArxExtensionActionRunStatus RunAction(const std::string& extension_id, double screen_x,
                                        double screen_y);
  // DEV-824 follow-up, exported as ArxEngineCopyExtensionActionIcon: the PNG of
  // the icon extension_id's action shows for this page's tab at `scale` (1 or
  // 2) when chrome.action.setIcon or a declarative rule chose it. Empty when
  // the action shows its default icon, which the inventory's actionIcons name,
  // and for an extension whose action the app can't run here.
  std::vector<uint8_t> ActionIcon(const std::string& extension_id, float scale) const;
 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace arx

// DEV-1316, exported outside the ABI table: the app's window for an
// extension's action popup, and how a popup answers losing focus. Main thread,
// safe before the engine runs. Engines built before it lack the export, and
// the app keeps their popover.
//
// `make_window(context, content_view, title, icon_png, icon_png_size,
// icon_path, width, height)` returns a window the app made (an `NSWindow*` the
// engine now owns: +1, as CFBridgingRetain gives it) with the borrowed
// `NSView*` content_view in it, laid out so the view is `width` x `height`
// points, not yet shown; or NULL for the engine's own window. `title` is the
// extension's name. Its icon, as its toolbar button shows it on that page:
// `icon_png` (borrowed for the call) when chrome.action.setIcon or a
// declarative rule chose one, else `icon_path`, the action's default icon or
// the manifest icon nearest 64 pixels, joined to the extension's folder and
// never resolved (empty when neither has one). The app draws it in the
// window's header, so the person sees whose window it is; the page can't
// change it. `resize_window(context, window, width, height)` resizes it so the
// view is that size, keeping its top-left corner. The engine places, shows,
// focuses and closes the window, and listens for the person moving or closing
// it. `closing` is an `ArxExtensionPopupClosing`. NULL `make_window` goes back
// to the engine's own window, which closes as `closing` says too.
extern "C" {
typedef enum ArxExtensionPopupClosing : uint32_t {
  // Closes on losing focus, unless the person moved it (the default).
  ARX_EXTENSION_POPUP_CLOSES_UNLESS_MOVED = 0,
  // Closes on losing focus, as Chrome's popup does, even when moved.
  ARX_EXTENSION_POPUP_CLOSES_ON_FOCUS_LOSS = 1,
  // Stays open until it is closed: its Close, Escape or window.close().
  ARX_EXTENSION_POPUP_STAYS_OPEN = 2,
} ArxExtensionPopupClosing;
typedef void* (*ArxExtensionPopupMakeWindowFunction)(void* context, void* content_view,
                                                       const char* title,
                                                       const uint8_t* icon_png,
                                                       size_t icon_png_size,
                                                       const char* icon_path, double width,
                                                       double height);
typedef void (*ArxExtensionPopupResizeWindowFunction)(void* context, void* window,
                                                        double width, double height);
__attribute__((visibility("default"))) void ArxEngineSetExtensionPopupPresenter(
    ArxExtensionPopupMakeWindowFunction make_window,
    ArxExtensionPopupResizeWindowFunction resize_window, uint32_t closing, void* context);
}
#endif
