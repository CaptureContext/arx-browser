#include "chrome/browser/arx/extension_window_hooks.h"

#import <AppKit/AppKit.h>

#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/location.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/arx_before_unload.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/web_contents.h"
#include "extensions/common/constants.h"
#include "extensions/common/extension.h"
#include "ui/gfx/native_ui_types.h"
#include "url/gurl.h"

// DEV-1240. An extension's own window (chrome.windows.create) opens in Little
// Arx, the way its options page does (DEV-1185): the engine adopts a page for
// the extension's URL and the app shows it in a new Little Arx that takes the
// keyboard. The window's ID is the embedder window ID Little Arx gets once the
// app places the page (ABI22), so windows.get, getCurrent, getAll and the
// page's tab all agree on it. windows.update (focused) and windows.remove act
// on the windows opened here; Chrome's own windows are left to Chrome.
//
// DEV-1314. tabs.create for one of the extension's own pages, when Chrome has
// no browser window for it, opens it the same way and answers with its tab.

namespace arx {
namespace {

// The app places a new page in its Little Arx a turn or two after taking it.
constexpr base::TimeDelta kPlacementPoll = base::Milliseconds(50);
constexpr int kPlacementPolls = 100;  // 5 seconds.
// At most this many extension windows are tracked at once.
constexpr size_t kMaximumWindows = 64;

std::vector<base::WeakPtr<content::WebContents>>& OpenedWindows() {
  static base::NoDestructor<std::vector<base::WeakPtr<content::WebContents>>> opened;
  auto& windows = *opened;
  std::erase_if(windows, [](const base::WeakPtr<content::WebContents>& contents) {
    return !contents || contents->IsBeingDestroyed();
  });
  return windows;
}

std::set<content::WebContents*> ProfilePages(content::BrowserContext* context) {
  std::set<content::WebContents*> pages;
  for (const auto& tab :
       extensions::ExtensionTabUtil::GetEmbedderTabs(context, /*include_incognito=*/false)) {
    if (tab.contents) pages.insert(tab.contents.get());
  }
  return pages;
}

// The embedder window `contents` is placed in, or kUnknownWindowId.
int WindowOf(content::WebContents* contents) {
  const auto tab = extensions::ExtensionTabUtil::GetEmbedderTab(contents);
  return tab && tab->window_id >= 0 ? tab->window_id : extension_misc::kUnknownWindowId;
}

// The page of a window opened here, in `context`, placed in `window_id`.
content::WebContents* OpenedPage(content::BrowserContext* context, int window_id) {
  if (!context || window_id < 0 || !IsEmbedded()) return nullptr;
  for (const auto& contents : OpenedWindows()) {
    if (contents->GetBrowserContext() == context && WindowOf(contents.get()) == window_id)
      return contents.get();
  }
  return nullptr;
}

// Runs `placed` with the page once the app has placed it in a window, or with
// null when it closed or wasn't placed in time.
void AwaitPlacement(base::WeakPtr<content::WebContents> contents, int polls,
                    ExtensionTabOpened placed) {
  const bool live = contents && !contents->IsBeingDestroyed() && IsEmbedded();
  if (live && WindowOf(contents.get()) >= 0) {
    std::move(placed).Run(contents.get());
    return;
  }
  // Closed, or never placed: the extension hears that nothing opened.
  if (!live || polls <= 0) {
    std::move(placed).Run(nullptr);
    return;
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE,
      base::BindOnce(&AwaitPlacement, std::move(contents), polls - 1, std::move(placed)),
      kPlacementPoll);
}

// Adopts `url`, a page of `extension`'s own, in an ordinary Arx profile, and
// returns the page the adoption made; null when Arx doesn't take it.
content::WebContents* AdoptExtensionPage(content::BrowserContext* context,
                                         const extensions::Extension& extension,
                                         const GURL& url) {
  if (!context || !IsEmbedded() || context->IsOffTheRecord()) return nullptr;
  // Only the extension's own pages; a web address keeps Chrome's handling.
  if (!url.is_valid() || !url.SchemeIs(extensions::kExtensionScheme) ||
      url.host() != extension.id() || url.has_username() || url.has_password() ||
      url.has_port()) return nullptr;
  Profile* profile = Profile::FromBrowserContext(context);
  const auto key = CurrentExtensionProfileKey(profile);
  if (!key || OpenedWindows().size() >= kMaximumWindows) return nullptr;

  const auto before = ProfilePages(context);
  // The same adoption chrome.runtime.openOptionsPage() uses: the app shows the
  // page in a new Little Arx on a space of this profile and gives it the keyboard.
  if (!AdoptRuntimeExtensionOptions(profile, *key, &extension, url)) return nullptr;
  // The adoption made exactly one page; it is the one that wasn't there before.
  content::WebContents* page = nullptr;
  for (content::WebContents* contents : ProfilePages(context)) {
    if (before.contains(contents)) continue;
    page = contents;
    if (contents->GetVisibleURL() == url) break;
  }
  return page;
}

}  // namespace

bool OpenExtensionWindow(content::BrowserContext* context,
                         const extensions::Extension& extension,
                         const GURL& url,
                         ExtensionWindowOpened& opened) {
  if (!opened) return false;
  content::WebContents* page = AdoptExtensionPage(context, extension, url);
  if (!page) return false;
  OpenedWindows().push_back(page->GetWeakPtr());
  AwaitPlacement(page->GetWeakPtr(), kPlacementPolls,
      base::BindOnce([](ExtensionWindowOpened opened, content::WebContents* contents) {
        std::move(opened).Run(contents ? WindowOf(contents) : extension_misc::kUnknownWindowId);
      }, std::move(opened)));
  return true;
}

// DEV-1314. The tab opens where the extension's own window does, in a new
// Little Arx, which the person can keep as a tab. It is tracked with the
// windows opened here, so windows.update and windows.remove on its window
// reach it too. `active`, `index`, `pinned` and `openerTabId` aren't applied:
// Little Arx takes the keyboard and keeps its own place.
bool OpenExtensionTab(content::BrowserContext* context,
                      const extensions::Extension& extension,
                      const GURL& url,
                      ExtensionTabOpened& opened) {
  if (!opened) return false;
  content::WebContents* page = AdoptExtensionPage(context, extension, url);
  if (!page) return false;
  OpenedWindows().push_back(page->GetWeakPtr());
  AwaitPlacement(page->GetWeakPtr(), kPlacementPolls, std::move(opened));
  return true;
}

bool UpdateExtensionWindow(content::BrowserContext* context, int window_id, bool focus) {
  content::WebContents* page = OpenedPage(context, window_id);
  if (!page) return false;
  if (!focus) return true;
  NSWindow* window = page->GetNativeView().GetNativeNSView().window;
  if (window) {
    [NSApp activateIgnoringOtherApps:YES];
    if (window.miniaturized) [window deminiaturize:nil];
    [window makeKeyAndOrderFront:nil];
    page->Focus();
  }
  return true;
}

bool RemoveExtensionWindow(content::BrowserContext* context, int window_id) {
  content::WebContents* page = OpenedPage(context, window_id);
  if (!page) return false;
  // As closing a Chrome window: the page's before-unload runs first and may
  // keep it open. Then, as the page's own window.close(), the app closes its
  // Little Arx (page_close_requested). A round already under way (the person
  // closing it, say) is left to finish.
  content::DispatchBeforeUnloadForArx(
      page->GetPrimaryMainFrame(),
      base::BindOnce(
          [](base::WeakPtr<content::WebContents> contents, std::optional<bool> proceed) {
            if (contents && !contents->IsBeingDestroyed() && proceed.value_or(false))
              contents->ClosePage();
          },
          page->GetWeakPtr()));
  return true;
}

}  // namespace arx
