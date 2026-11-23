#include "chrome/browser/arx/extension_menu_items.h"

#import <AppKit/AppKit.h>

#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "chrome/browser/arx/extensions_bridge.h"
#include "chrome/browser/extensions/context_menu_helpers.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/models/image_model.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/text_utils.h"

// Calls back with the chosen item's tag. Each item holds it (representedObject),
// so it lives as long as the menu.
@interface ARXExtensionMenuRunner : NSObject
- (instancetype)initWithCallback:(base::RepeatingCallback<void(int)>)callback;
- (void)choose:(NSMenuItem*)sender;
@end

@implementation ARXExtensionMenuRunner {
  base::RepeatingCallback<void(int)> _callback;
}
- (instancetype)initWithCallback:(base::RepeatingCallback<void(int)>)callback {
  if ((self = [super init])) _callback = std::move(callback);
  return self;
}
- (void)choose:(NSMenuItem*)sender {
  if (_callback) _callback.Run(static_cast<int>(sender.tag));
}
@end

namespace arx {
namespace {

void Retain(NSMenu* menu, id runner) {
  for (NSMenuItem* item in menu.itemArray) {
    if (item.submenu) Retain(item.submenu, runner);
    else if (item.target == runner) item.representedObject = runner;
  }
}

// Chrome's menus show a 16-point icon beside an extension's item.
constexpr CGFloat kIconSize = 16;

NSImage* Icon(const ui::ImageModel& icon) {
  if (!icon.IsImage()) return nil;
  const gfx::Image image = icon.GetImage();
  if (image.IsEmpty()) return nil;
  NSImage* copy = [image.ToNSImage() copy];
  copy.size = NSMakeSize(kIconSize, kIconSize);
  return copy;
}

// A separator between groups, never first or doubled.
void Separate(NSMenu* menu) {
  NSMenuItem* last = menu.itemArray.lastObject;
  if (last && !last.separatorItem) [menu addItem:[NSMenuItem separatorItem]];
}

void Append(ui::MenuModel* model, NSMenu* menu, id target, SEL action) {
  for (size_t index = 0; index < model->GetItemCount(); ++index) {
    if (!model->IsVisibleAt(index)) continue;
    // Extension titles keep a literal "&" as "&&", as every Chrome menu label.
    NSString* title = base::SysUTF16ToNSString(gfx::RemoveAccelerator(model->GetLabelAt(index)));
    switch (model->GetTypeAt(index)) {
      case ui::MenuModel::TYPE_SEPARATOR:
        Separate(menu);
        break;
      case ui::MenuModel::TYPE_SUBMENU: {
        ui::MenuModel* submodel = model->GetSubmenuModelAt(index);
        if (!submodel) break;
        NSMenu* submenu = [[NSMenu alloc] initWithTitle:title];
        submenu.autoenablesItems = NO;
        Append(submodel, submenu, target, action);
        NSMenuItem* last = submenu.itemArray.lastObject;
        if (last.separatorItem) [submenu removeItem:last];
        if (!submenu.numberOfItems) break;
        NSMenuItem* holder = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
        holder.submenu = submenu;
        holder.enabled = model->IsEnabledAt(index);
        holder.image = Icon(model->GetIconAt(index));
        break;
      }
      case ui::MenuModel::TYPE_COMMAND:
      case ui::MenuModel::TYPE_CHECK:
      case ui::MenuModel::TYPE_RADIO: {
        NSMenuItem* item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
        item.target = target;
        item.tag = model->GetCommandIdAt(index);
        item.enabled = model->IsEnabledAt(index);
        item.state = model->IsItemCheckedAt(index) ? NSControlStateValueOn : NSControlStateValueOff;
        item.image = Icon(model->GetIconAt(index));
        break;
      }
      default:
        // Chrome's extension items are only commands, checks, radios,
        // separators and submenus.
        break;
    }
  }
}

}  // namespace

ExtensionMenuItems::ExtensionMenuItems(content::WebContents* contents,
                                       const content::ContextMenuParams& params)
    : params_(params),
      model_(this),
      matcher_(contents ? contents->GetBrowserContext() : nullptr, this, &model_,
               base::BindRepeating(extensions::context_menu_helpers::MenuItemMatchesParams,
                                   params_)) {
  // A private page gets the items of the extensions allowed in private windows
  // (Chrome's matcher checks the switch) only while its opener is current, so
  // the extension tab APIs reach the page an item is chosen on (DEV-956).
  if (!contents || !ExtensionViewsAvailable() ||
      (contents->GetBrowserContext()->IsOffTheRecord() &&
       !PrivateExtensionContextIsCurrent(contents->GetBrowserContext())))
    return;
  extensions::context_menu_helpers::PopulateExtensionItems(contents->GetBrowserContext(),
                                                          params_, matcher_);
}

ExtensionMenuItems::~ExtensionMenuItems() = default;

bool ExtensionMenuItems::AppendTo(NSMenu* menu, id target, SEL action) const {
  if (empty() || !menu) return false;
  Separate(menu);
  const NSInteger before = menu.numberOfItems;
  Append(const_cast<ui::SimpleMenuModel*>(&model_), menu, target, action);
  NSMenuItem* last = menu.itemArray.lastObject;
  if (last.separatorItem && menu.numberOfItems > before) [menu removeItem:last];
  return menu.numberOfItems > before;
}

bool ExtensionMenuItems::AppendTo(NSMenu* menu, base::RepeatingCallback<void(int)> run) const {
  if (empty() || !menu || !run) return false;
  ARXExtensionMenuRunner* runner = [[ARXExtensionMenuRunner alloc] initWithCallback:std::move(run)];
  if (!AppendTo(menu, runner, @selector(choose:))) return false;
  Retain(menu, runner);
  return true;
}

bool ExtensionMenuItems::IsCommand(int tag) {
  return extensions::ContextMenuMatcher::IsExtensionsCustomCommandId(tag);
}

bool ExtensionMenuItems::Execute(int tag, content::WebContents* contents,
                                 content::RenderFrameHost* frame) {
  if (!IsCommand(tag) || !contents || !frame || !matcher_.extension_item_map().contains(tag) ||
      !matcher_.IsCommandIdEnabled(tag))
    return false;
  matcher_.ExecuteCommand(tag, contents, frame, params_);
  return true;
}

bool ExtensionMenuItems::IsCommandIdChecked(int command_id) const {
  return IsCommand(command_id) && matcher_.IsCommandIdChecked(command_id);
}

bool ExtensionMenuItems::IsCommandIdEnabled(int command_id) const {
  return IsCommand(command_id) && matcher_.IsCommandIdEnabled(command_id);
}

bool ExtensionMenuItems::IsCommandIdVisible(int command_id) const {
  return IsCommand(command_id) && matcher_.IsCommandIdVisible(command_id);
}

}  // namespace arx
