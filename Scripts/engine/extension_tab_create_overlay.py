"""An extension's own page opened with `chrome.tabs.create` opens in Arx (DEV-1314).

`tabs.create` looks for the Chrome browser window to put the tab in, the caller's
or the one `windowId` names. An Arx page has none, so the call answered "No
current window" and nothing opened. 1Password relies on it: until an account is
set up, its toolbar button has no popup, and a click opens its welcome and
sign-in page with `tabs.create`, so the extension seemed not to open at all.

This overlay asks Arx when Chrome finds no window, for a call from an extension
for one page of its own (no `windowId` other than the current window, no split
view). `extension_window_bridge.mm` opens the page as it opens the extension's
own window (DEV-1240), in a new Little Arx, and the call answers once the app has
placed it, with that page's tab, as Chrome answers with the tab it made. Web
addresses and calls that name another window keep Chrome's answer. Anchors are
upstream text in `tabs_api.cc` (Chromium 157). If an anchor changes, the build
stops.
"""
from .overlay import replace_once

SOURCE = "chrome/browser/extensions/api/tabs/tabs_api.cc"

INCLUDE = '#include "chrome/browser/extensions/api/tabs/tabs_util.h"\n'
HOOKS = '#include "chrome/browser/arx/extension_window_hooks.h"  // nogncheck\n'

BAIL = """  // We didn't find a browser. Bail.
  // TODO(https://crbug.com/468223125): This isn't consistent, since sometimes
  // we *will* create a new browser below.
  if (!browser) {
"""

ARX_BAIL = """#if BUILDFLAG(IS_MAC)
  // Arx (DEV-1314): an Arx page has no Chrome browser window. An extension's
  // tab for a page of its own opens where its own window does, in Little Arx,
  // and the answer is that page's tab once the app has placed it.
  if (!browser && extension() && !split_with_tab_id_ &&
      create_properties.window_id.value_or(extension_misc::kCurrentWindowId) ==
          extension_misc::kCurrentWindowId) {
    arx::ExtensionTabOpened opened = base::BindOnce(
        [](scoped_refptr<TabsCreateFunction> function,
           content::WebContents* contents) {
          if (!contents) {
            function->Respond(
                function->Error(ExtensionTabUtil::kNoCurrentWindowError));
            return;
          }
          if (!function->has_callback()) {
            function->Respond(function->NoArguments());
            return;
          }
          function->Respond(function->WithArguments(
              CreateTabObjectHelper(contents, function->extension(),
                                    function->source_context_type(),
                                    /*browser=*/nullptr, /*tab_index=*/-1)
                  .ToValue()));
        },
        base::WrapRefCounted(this));
    if (arx::OpenExtensionTab(browser_context(), *extension(), validated_url_,
                              opened)) {
      return RespondLater();
    }
  }
#endif  // BUILDFLAG(IS_MAC)

""" + BAIL


def patches():
    yield SOURCE, INCLUDE, INCLUDE + '#include "base/functional/bind.h"\n#include "base/memory/scoped_refptr.h"\n' + HOOKS
    yield SOURCE, BAIL, ARX_BAIL


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
