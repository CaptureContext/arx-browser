#ifndef ARX_CONTEXT_MENU_BRIDGE_H
#define ARX_CONTEXT_MENU_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#include <memory>
#include <string>

#include "chrome/browser/arx/ChromiumBridge.h"

namespace content {
struct ContextMenuParams;
class RenderFrameHost;
class WebContents;
}

namespace arx {
class ExtensionMenuItems;

// ABI48 (DEV-814). The app's titles for the context menus, one per
// ArxContextMenuItem, copied. Fewer titles, or an empty one, turn them off.
void ConfigureContextMenus(const char* const* titles, size_t count);
bool ContextMenusConfigured();

// What a right click is on, for the menus here. kNone keeps what it had: the
// page menu, the link menu, or the old behavior for anything else (form
// controls that aren't editable, canvas, plugins, links Arx doesn't take).
enum class ContextMenuKind { kNone, kEditable, kSelection, kImage, kVideo, kAudio };
ContextMenuKind ContextMenuKindFor(const content::ContextMenuParams& params);

// What the person chose in RunContextMenu: an ArxContextMenuItem,
// kContextMenuInspect, kContextMenuSuggestion (with the suggestion) or
// kContextMenuNothing. Items AppKit runs itself (Substitutions, Speech, and
// what AppKit adds) report nothing.
inline constexpr int kContextMenuNothing = -1;
inline constexpr int kContextMenuInspect = ARX_CONTEXT_MENU_ITEM_COUNT;
inline constexpr int kContextMenuSuggestion = ARX_CONTEXT_MENU_ITEM_COUNT + 1;
// DEV-890: an extension's chrome.contextMenus item, run by PerformContextMenuItem.
inline constexpr int kContextMenuExtension = ARX_CONTEXT_MENU_ITEM_COUNT + 16;
struct ContextMenuSelection {
  int item = kContextMenuNothing;
  std::u16string suggestion;
  // For kContextMenuExtension: the item's tag and the items it belongs to.
  int extension_command = 0;
  std::shared_ptr<ExtensionMenuItems> extensions;
};

// Whether the app carries the item out (context_menu_chosen).
bool IsAppContextMenuItem(int item);

// Shows the menu for params' kind on the page's render widget view, the way
// Chrome shows its own (AppKit adds Writing Tools, AutoFill and Services to
// it), inside AppKit's nested tracking loop. host_items is the app's mask of
// 1ull << ArxContextMenuItem for app items; inspect_title adds Inspect Element
// when it isn't empty. The contents may be gone when it returns: callers keep
// a weak pointer and check it before touching anything.
ContextMenuSelection RunContextMenu(content::WebContents* contents,
                                    const content::ContextMenuParams& params,
                                    uint64_t host_items, const std::string& inspect_title);

// Carries out a native item (not an app item, not Inspect Element) on frame,
// the frame the menu opened on, after the menu closed.
void PerformContextMenuItem(content::WebContents* contents, content::RenderFrameHost* frame,
                            const content::ContextMenuParams& params,
                            const ContextMenuSelection& selection);

// The address and text an app item carries (see ArxContextMenuChoice): the
// image's or media's http(s) address, or the selection. False when the item
// has nothing valid to carry.
bool ContextMenuPayload(const content::ContextMenuParams& params, int item, std::string* url,
                        std::string* text);
}  // namespace arx

#endif
