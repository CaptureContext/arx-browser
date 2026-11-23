#include "chrome/browser/arx/page_menu_bridge.h"

#import <AppKit/AppKit.h>

#include <array>
#include <string>
#include <string_view>

#include "base/files/file_path.h"
#include "base/no_destructor.h"
#include "chrome/browser/arx/cast_bridge.h"
#include "chrome/browser/arx/extension_menu_items.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/current_thread.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/save_page_type.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/url_constants.h"
#include "third_party/blink/public/mojom/context_menu/context_menu.mojom.h"
#include "ui/gfx/native_ui_types.h"
#include "url/gurl.h"

@interface ARXPageMenuTarget : NSObject
@property(nonatomic) NSInteger chosen;
- (void)choose:(NSMenuItem*)sender;
@end

@implementation ARXPageMenuTarget
- (instancetype)init {
  if ((self = [super init])) _chosen = arx::kPageMenuNothing;
  return self;
}
- (void)choose:(NSMenuItem*)sender { self.chosen = sender.tag; }
@end

namespace arx {
namespace {

using Titles = std::array<std::string, ARX_PAGE_MENU_ITEM_COUNT>;

Titles& PageMenuTitles() {
  static base::NoDestructor<Titles> titles;
  return *titles;
}

bool WebPage(const GURL& url) { return url.is_valid() && url.SchemeIsHTTPOrHTTPS(); }

}  // namespace

void ConfigurePageMenu(const char* const* titles, size_t count) {
  Titles copied;
  if (titles && count == ARX_PAGE_MENU_ITEM_COUNT) {
    for (size_t index = 0; index < count; ++index) {
      const char* title = titles[index];
      if (!title || strnlen(title, 257) > 256) { copied = {}; break; }
      copied[index] = title;
    }
  }
  PageMenuTitles() = std::move(copied);
}

bool PageMenuConfigured() {
  for (const auto& title : PageMenuTitles())
    if (title.empty()) return false;
  return true;
}

bool IsPageMenuContext(const content::ContextMenuParams& params) {
  return !params.is_editable && !params.form_control_type.has_value() &&
      params.link_url.is_empty() && params.unfiltered_link_url.is_empty() &&
      params.src_url.is_empty() && !params.has_image_contents &&
      params.selection_text.empty() &&
      params.media_type == blink::mojom::ContextMenuDataMediaType::kNone;
}

int RunPageMenu(content::WebContents* contents, uint32_t host_items,
                const std::string& inspect_title, int x, int y,
                const content::ContextMenuParams* params,
                std::shared_ptr<ExtensionMenuItems>* extensions) {
  const bool page_items = host_items != 0;
  if (!contents || (!page_items && inspect_title.empty())) return kPageMenuNothing;
  NSView* view = contents->GetNativeView().GetNativeNSView();
  if (!view || !view.window || !view.window.visible || view.window.miniaturized ||
      view.hiddenOrHasHiddenAncestor) return kPageMenuNothing;

  ARXPageMenuTarget* target = [[ARXPageMenuTarget alloc] init];
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
  menu.autoenablesItems = NO;
  const auto add = [&](int tag, const std::string& title, bool enabled) {
    NSMenuItem* item = [menu addItemWithTitle:base::SysUTF8ToNSString(title)
                                       action:@selector(choose:) keyEquivalent:@""];
    item.target = target;
    item.tag = tag;
    // Inspect Element and Cast… are native; every other item also needs the
    // host's yes.
    item.enabled = enabled && (tag == kPageMenuInspect || tag == kPageMenuCast ||
                               (host_items & (1u << tag)));
  };
  if (page_items) {
    const Titles& titles = PageMenuTitles();
    auto& controller = contents->GetController();
    const bool web = WebPage(contents->GetPrimaryMainFrame()->GetLastCommittedURL());
    add(ARX_PAGE_MENU_BACK, titles[ARX_PAGE_MENU_BACK], controller.CanGoBack());
    add(ARX_PAGE_MENU_FORWARD, titles[ARX_PAGE_MENU_FORWARD], controller.CanGoForward());
    add(ARX_PAGE_MENU_RELOAD, titles[ARX_PAGE_MENU_RELOAD], true);
    [menu addItem:[NSMenuItem separatorItem]];
    add(ARX_PAGE_MENU_SAVE_AS, titles[ARX_PAGE_MENU_SAVE_AS], web);
    add(ARX_PAGE_MENU_PRINT, titles[ARX_PAGE_MENU_PRINT], web);
    // ABI48 (DEV-818): Share… with the page's address and title, from the app.
    add(ARX_PAGE_MENU_SHARE, titles[ARX_PAGE_MENU_SHARE], web);
    // DEV-927: Cast… as in Chrome's page menu, while the page can cast.
    if (const std::string cast = CastMenuTitle(contents); web && !cast.empty())
      add(kPageMenuCast, cast, true);
    [menu addItem:[NSMenuItem separatorItem]];
    add(ARX_PAGE_MENU_VIEW_SOURCE, titles[ARX_PAGE_MENU_VIEW_SOURCE], web);
  }
  std::shared_ptr<ExtensionMenuItems> extension_items;
  if (params && extensions) {
    extension_items = std::make_shared<ExtensionMenuItems>(contents, *params);
    extension_items->AppendTo(menu, target, @selector(choose:));
  }
  if (!inspect_title.empty()) {
    if (menu.numberOfItems) [menu addItem:[NSMenuItem separatorItem]];
    add(kPageMenuInspect, inspect_title, true);
  }

  const NSPoint point = NSMakePoint(x, view.isFlipped ? y : NSHeight(view.bounds) - y);
  {
    base::CurrentThread::ScopedAllowApplicationTasksInNativeNestedLoop allow;
    [menu popUpMenuPositioningItem:nil atLocation:point inView:view];
  }
  const int chosen = static_cast<int>(target.chosen);
  if (extensions && ExtensionMenuItems::IsCommand(chosen)) *extensions = std::move(extension_items);
  return chosen;
}

bool SavePageAs(content::WebContents* contents, const base::FilePath& path, ArxSavePageKind kind) {
  if (!contents || path.empty() || !path.IsAbsolute() || path.ReferencesParent()) return false;
  if (!WebPage(contents->GetPrimaryMainFrame()->GetLastCommittedURL())) return false;
  content::SavePageType type;
  switch (kind) {
    case ARX_SAVE_PAGE_HTML_ONLY: type = content::SAVE_PAGE_TYPE_AS_ONLY_HTML; break;
    case ARX_SAVE_PAGE_COMPLETE: type = content::SAVE_PAGE_TYPE_AS_COMPLETE_HTML; break;
    case ARX_SAVE_PAGE_MHTML: type = content::SAVE_PAGE_TYPE_AS_MHTML; break;
    default: return false;
  }
  // Chrome's own naming: "Page.html" keeps its resources in "Page_files".
  const base::FilePath resources(path.RemoveFinalExtension().value() + "_files");
  return contents->SavePage(path, resources, type);
}

// DEV-898: Chromium's diagnostic pages the app opens as arx:// addresses. The
// app keeps all but version and gpu behind developer mode. Pages never reach
// these: renderer-initiated navigations and popups only pass AllowedURL.
bool DiagnosticPageURL(const GURL& url) {
  static constexpr std::array<std::string_view, 8> kHosts = {
      "version", "gpu", "net-internals", "process-internals", "media-internals",
      "serviceworker-internals", "webrtc-internals", "inspect"};
  if (!url.is_valid() || !url.SchemeIs(content::kChromeUIScheme) ||
      url.has_username() || url.has_password() || url.has_port() || url.has_query())
    return false;
  for (const auto host : kHosts)
    if (url.host() == host) return true;
  return false;
}

bool UserNavigationURL(const GURL& url) {
  if (!url.is_valid()) return false;
  if (url.SchemeIsFile()) return true;
  if (DiagnosticPageURL(url)) return true;
  if (!url.SchemeIs(content::kViewSourceScheme)) return false;
  const GURL inner(url.GetContent());
  return WebPage(inner) && !inner.has_username() && !inner.has_password();
}

}  // namespace arx
