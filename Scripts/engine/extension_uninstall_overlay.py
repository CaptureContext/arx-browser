"""Let the embedder confirm `chrome.management.uninstall` itself (DEV-889).

The Chrome Web Store's **Remove from Chrome** button calls
`chrome.management.uninstall(id, {showConfirmDialog: true})`, and so can an
extension that removes another one. Chrome answers with its Views
`ExtensionUninstallDialog`, anchored to a Chrome browser window that Arx
doesn't have, so the button did nothing useful.

`ChromeManagementAPIDelegate::SetEmbedderUninstallConfirmation` installs a plain
function that gets the requesting page, the extension to remove, the extension
asking (null for the store page) and a completion. When it returns true it owns
the request: it must run the completion exactly once, with true only after it
started the uninstall itself. Chrome's policy checks (`UserMayModifySettings`,
`MustRemainInstalled`) and the user-gesture check still run first, in
`ManagementUninstallFunctionBase::Uninstall`. Without a hook, or when it
returns false, Chrome's dialog runs as before. If an anchor changes, the build
stops.
"""
from .overlay import replace_once

HEADER = "chrome/browser/extensions/api/management/chrome_management_api_delegate.h"
SOURCE = "chrome/browser/extensions/api/management/chrome_management_api_delegate.cc"

INCLUDE = '#include "extensions/common/extension_id.h"\n'
ARX_INCLUDE = '''#include "extensions/common/extension_id.h"

#include "base/functional/callback.h"
'''

SETTER = """  ChromeManagementAPIDelegate();
  ~ChromeManagementAPIDelegate() override;
"""

ARX_SETTER = """  ChromeManagementAPIDelegate();
  ~ChromeManagementAPIDelegate() override;

  // Arx (DEV-889): the embedder may confirm a management.uninstall request
  // instead of Chrome's dialog. True takes the request: `done` must then run
  // exactly once, with true only once the embedder started the uninstall.
  // `initiator` is the extension asking, or null for a page such as the Chrome
  // Web Store. Install on the UI thread. Null (the default) keeps Chrome's.
  using EmbedderUninstallConfirmation =
      bool (*)(content::WebContents* sender,
               const Extension& target,
               const Extension* initiator,
               base::OnceCallback<void(bool did_start_uninstall,
                                       const std::u16string& error)> done);
  static void SetEmbedderUninstallConfirmation(
      EmbedderUninstallConfirmation confirmation);
"""

CONSTRUCTOR = "ChromeManagementAPIDelegate::ChromeManagementAPIDelegate() = default;\n"

ARX_CONSTRUCTOR = """namespace {

// Arx (DEV-889).
ChromeManagementAPIDelegate::EmbedderUninstallConfirmation
    g_embedder_uninstall_confirmation = nullptr;

// Keeps nothing alive: the function holds its own reference until it hears
// back, and the embedder's completion carries another.
class EmbedderUninstallDialogDelegate : public UninstallDialogDelegate {};

}  // namespace

// static
void ChromeManagementAPIDelegate::SetEmbedderUninstallConfirmation(
    EmbedderUninstallConfirmation confirmation) {
  g_embedder_uninstall_confirmation = confirmation;
}

ChromeManagementAPIDelegate::ChromeManagementAPIDelegate() = default;
"""

DELEGATE = """    bool show_programmatic_uninstall_ui) const {
  return std::make_unique<ManagementUninstallFunctionUninstallDialogDelegate>(
      function, target_extension, show_programmatic_uninstall_ui);
}
"""

ARX_DELEGATE = """    bool show_programmatic_uninstall_ui) const {
  // Arx (DEV-889): the embedder confirms in its own UI.
  if (g_embedder_uninstall_confirmation && target_extension) {
    auto done = base::BindOnce(
        &ManagementUninstallFunctionBase::OnExtensionUninstallDialogClosed,
        base::WrapRefCounted(function));
    if (g_embedder_uninstall_confirmation(function->GetSenderWebContents(),
                                          *target_extension,
                                          function->extension(),
                                          std::move(done))) {
      return std::make_unique<EmbedderUninstallDialogDelegate>();
    }
  }
  return std::make_unique<ManagementUninstallFunctionUninstallDialogDelegate>(
      function, target_extension, show_programmatic_uninstall_ui);
}
"""


def patches():
    yield HEADER, INCLUDE, ARX_INCLUDE
    yield HEADER, SETTER, ARX_SETTER
    yield SOURCE, CONSTRUCTOR, ARX_CONSTRUCTOR
    yield SOURCE, DELEGATE, ARX_DELEGATE


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
