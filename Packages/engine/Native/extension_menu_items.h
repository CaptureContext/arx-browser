#ifndef ARX_EXTENSION_MENU_ITEMS_H_
#define ARX_EXTENSION_MENU_ITEMS_H_

#include "base/functional/callback.h"
#include "chrome/browser/extensions/context_menu_matcher.h"
#include "content/public/browser/context_menu_params.h"
#include "ui/menus/simple_menu_model.h"

#ifdef __OBJC__
@class NSMenu;
#else
class NSMenu;
#endif

namespace content {
class RenderFrameHost;
class WebContents;
}

namespace arx {
// DEV-890. The items extensions added with chrome.contextMenus for one right
// click, as Chrome's own menu shows them (RenderViewContextMenu's
// AppendAllExtensionItems): extensions sorted by name, one extension's single
// item on its own, several in a submenu named after the extension, with its
// icon. Chromium's MenuManager matches each item's contexts and URL patterns
// against `params`. Private pages get none. Main thread. Keep the object until the chosen item has run: it maps
// the menu's tags to the extensions' items.
class ExtensionMenuItems final : public ui::SimpleMenuModel::Delegate {
 public:
  // An empty set when extensions are off or `contents` is null.
  ExtensionMenuItems(content::WebContents* contents, const content::ContextMenuParams& params);
  ExtensionMenuItems(const ExtensionMenuItems&) = delete;
  ExtensionMenuItems& operator=(const ExtensionMenuItems&) = delete;
  ~ExtensionMenuItems() override;

  bool empty() const { return model_.GetItemCount() == 0; }

  // Appends the items to `menu`, after a separator when it has items, each
  // reporting its tag to `target`'s `action` (an NSMenuItem sender). Returns
  // whether it added any.
  bool AppendTo(NSMenu* menu, id target, SEL action) const;

  // The same for a menu someone else runs, such as the app's link menu: a
  // chosen item calls `run` with its tag, right away. The items keep `run`
  // alive while the menu does.
  bool AppendTo(NSMenu* menu, base::RepeatingCallback<void(int)> run) const;

  // Whether `tag` is one AppendTo used.
  static bool IsCommand(int tag);

  // Fires the extension's onClicked for the chosen `tag`, with the page,
  // frame, link, selection and media of the right click. False for a tag that
  // isn't one of these items.
  bool Execute(int tag, content::WebContents* contents, content::RenderFrameHost* frame);

  // ui::SimpleMenuModel::Delegate:
  bool IsCommandIdChecked(int command_id) const override;
  bool IsCommandIdEnabled(int command_id) const override;
  bool IsCommandIdVisible(int command_id) const override;
  void ExecuteCommand(int command_id, int event_flags) override {}

 private:
  const content::ContextMenuParams params_;
  ui::SimpleMenuModel model_;
  extensions::ContextMenuMatcher matcher_;
};
}  // namespace arx

#endif  // ARX_EXTENSION_MENU_ITEMS_H_
