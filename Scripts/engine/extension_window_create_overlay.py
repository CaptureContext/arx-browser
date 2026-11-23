"""An extension's own window opens in Little Arx (DEV-1240).

`chrome.windows.create` builds a Chrome browser window for the new page. An Arx
page has none, and extensions that open a window of their own (1Password's
pop-out and unlock window) showed nothing. This overlay asks Arx first, for a
call from an extension for one page of its own in an ordinary profile:
`extension_window_bridge.mm` adopts the page as Arx adopts an options page and
the app shows it in a new Little Arx that takes the keyboard. The call answers
once the app has placed it, with that Little Arx as an embedder window (ABI22),
so the ID matches what `windows.get`, `getCurrent` and the page's tab report.

`windows.update` with `focused: true` brings such a window forward, and
`windows.remove` closes its page as the page's own `window.close()` would.
Every other call keeps Chrome's handling. Anchors are upstream text in
`windows_api.cc` (Chromium 157), after `extension_windows_overlay.py`, whose
`EmbedderWindowValues` helper builds the answer. If an anchor changes, the
build stops.
"""
from .overlay import replace_once

SOURCE = "chrome/browser/extensions/api/tabs/windows_api.cc"

INCLUDE = '#include "chrome/browser/extensions/api/tabs/windows_util.h"\n'
HOOKS = '#include "chrome/browser/arx/extension_window_hooks.h"  // nogncheck\n'

CREATE = "  // Create a new BrowserWindow if possible.\n"
CONSTRUCTOR = "WindowsCreateFunction::WindowsCreateFunction() = default;\n"
UPDATE = "      windows::Update::Params::Create(args());\n  EXTENSION_FUNCTION_VALIDATE(params);\n"
REMOVE = "      windows::Remove::Params::Create(args());\n  EXTENSION_FUNCTION_VALIDATE(params);\n"


def patches():
    yield SOURCE, INCLUDE, INCLUDE + '#include "base/functional/bind.h"\n#include "base/memory/scoped_refptr.h"\n' + HOOKS
    yield SOURCE, CONSTRUCTOR, '''#if BUILDFLAG(IS_MAC)
namespace {

// Arx (DEV-1240): `window_id`, with WINDOW_ID_CURRENT resolved to the embedder
// window of the calling page, as windows.getCurrent resolves it.
int ArxExtensionWindowId(ExtensionFunction& function, int window_id) {
  if (window_id != extension_misc::kCurrentWindowId) {
    return window_id;
  }
  return ExtensionTabUtil::GetEmbedderWindows(
             function.browser_context(), function.GetSenderWebContents(),
             function.include_incognito_information())
      .current;
}

}  // namespace
#endif  // BUILDFLAG(IS_MAC)

''' + CONSTRUCTOR
    yield SOURCE, CREATE, '''#if BUILDFLAG(IS_MAC)
  // Arx (DEV-1240): an extension's window for a page of its own opens in
  // Little Arx; there's no Chrome browser window to put it in. The answer is
  // that window once the app has placed the page.
  if (extension() && !(create_data_ && create_data_->tab_id) &&
      !is_locked_fullscreen && window_profile == calling_profile &&
      urls_.size() == 1 && !isolated_web_app_url_info_.has_value()) {
    arx::ExtensionWindowOpened opened = base::BindOnce(
        [](scoped_refptr<WindowsCreateFunction> function, int window_id) {
          base::ListValue windows =
              window_id < 0 ? base::ListValue()
                            : EmbedderWindowValues(
                                  *function, EmbedderWindowSelection::kId,
                                  window_id, /*populate=*/true,
                                  WindowController::kNoWindowFilter);
          if (windows.empty()) {
            function->Respond(
                function->Error(ExtensionTabUtil::kBrowserWindowNotAllowed));
            return;
          }
          function->Respond(
              function->WithArguments(std::move(windows.front())));
        },
        base::WrapRefCounted(this));
    if (arx::OpenExtensionWindow(browser_context(), *extension(),
                                 urls_.front(), opened)) {
      return RespondLater();
    }
  }
#endif  // BUILDFLAG(IS_MAC)

''' + CREATE
    yield SOURCE, UPDATE, UPDATE + '''#if BUILDFLAG(IS_MAC)
  // Arx (DEV-1240): a window an extension opened in Little Arx comes forward;
  // its size, position and state stay Little Arx's.
  const int arx_window = ArxExtensionWindowId(*this, params->window_id);
  if (arx::UpdateExtensionWindow(browser_context(), arx_window,
                                 params->update_info.focused.value_or(false) ||
                                     params->update_info.draw_attention.value_or(false))) {
    base::ListValue windows = EmbedderWindowValues(
        *this, EmbedderWindowSelection::kId, arx_window,
        /*populate=*/false, WindowController::kNoWindowFilter);
    if (!windows.empty()) {
      return RespondNow(WithArguments(std::move(windows.front())));
    }
  }
#endif  // BUILDFLAG(IS_MAC)
'''
    yield SOURCE, REMOVE, REMOVE + '''#if BUILDFLAG(IS_MAC)
  // Arx (DEV-1240): a window an extension opened in Little Arx closes its page.
  if (arx::RemoveExtensionWindow(browser_context(),
                                 ArxExtensionWindowId(*this, params->window_id))) {
    return RespondNow(NoArguments());
  }
#endif  // BUILDFLAG(IS_MAC)
'''


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
