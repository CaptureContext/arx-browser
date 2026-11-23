"""Route the Chrome Web Store's Add to Chrome into Arx's own review (DEV-765).

`webstorePrivate.beginInstallWithManifest3` normally shows Chrome's install
dialog, which needs a Chrome browser window and shows the store's manifest
before any package exists. When the embedder sets a handler, the function still
parses the store's data and runs Chromium's policy check, then hands the page's
WebContents and the item ID to the handler and answers the page with its
result. The embedder downloads, verifies and reviews the real package itself.
Once it reports success, `completeInstall` for that profile and ID succeeds
once without Chrome's pending approval. Without a handler nothing changes.

Helium's store fixup also renames the store's button from "Add to Chrome" to
"Add to Helium"; Arx names itself instead.
"""

from .overlay import replace_once

HEADER = "extensions/browser/api/webstore_private/webstore_private_api.h"
SOURCE = "extensions/browser/api/webstore_private/webstore_private_api.cc"
STORE_SCRIPT = "components/extstore_fixups/chrome-webstore.js"

API_DECLARATION = """  static void EnsureAssociatedFactoryBuilt();
};
"""

ARX_API_DECLARATION = """  static void EnsureAssociatedFactoryBuilt();

  // Arx: an embedder that reviews and installs store items itself. The reply
  // answers beginInstallWithManifest3; it must run exactly once, on the UI
  // thread. A null handler restores Chrome's dialog.
  using EmbedderInstallReply = base::OnceCallback<void(
      api::webstore_private::Result result, const std::string& error)>;
  using EmbedderInstallHandler = base::RepeatingCallback<void(
      content::WebContents* contents, const std::string& extension_id,
      EmbedderInstallReply reply)>;
  static void SetEmbedderInstallHandler(EmbedderInstallHandler handler);
  // The embedder installed `extension_id` in `browser_context`; the store's
  // following completeInstall for it succeeds once.
  static void RecordEmbedderInstall(content::BrowserContext* browser_context,
                                    const std::string& extension_id);
};
"""

FUNCTION_DECLARATION = """  void OnFrictionPromptDone(bool result);
  void OnInstallPromptDone(
      ExtensionInstallPromptClient::DoneCallbackPayload payload);
"""

ARX_FUNCTION_DECLARATION = """  void OnFrictionPromptDone(bool result);
  // Arx: the embedder's answer replaces Chrome's install prompt.
  void OnEmbedderInstallDone(api::webstore_private::Result result,
                             const std::string& error);
  void OnInstallPromptDone(
      ExtensionInstallPromptClient::DoneCallbackPayload payload);
"""

API_DEFINITION = """void WebstorePrivateApi::EnsureAssociatedFactoryBuilt() {
  PendingApprovalsShutdownNotifierFactory::GetInstance();
}
"""

ARX_API_DEFINITION = """void WebstorePrivateApi::EnsureAssociatedFactoryBuilt() {
  PendingApprovalsShutdownNotifierFactory::GetInstance();
}

namespace {
WebstorePrivateApi::EmbedderInstallHandler& ArxEmbedderInstallHandler() {
  static base::NoDestructor<WebstorePrivateApi::EmbedderInstallHandler> handler;
  return *handler;
}

struct ArxEmbedderInstall {
  raw_ptr<content::BrowserContext> browser_context;
  std::string extension_id;
  base::TimeTicks recorded;
};

std::vector<ArxEmbedderInstall>& ArxEmbedderInstalls() {
  static base::NoDestructor<std::vector<ArxEmbedderInstall>> installs;
  return *installs;
}

bool ConsumeArxEmbedderInstall(content::BrowserContext* browser_context,
                               const std::string& extension_id) {
  auto& installs = ArxEmbedderInstalls();
  const auto now = base::TimeTicks::Now();
  std::erase_if(installs, [now](const ArxEmbedderInstall& install) {
    return now - install.recorded > base::Minutes(2);
  });
  for (auto it = installs.begin(); it != installs.end(); ++it) {
    if (it->browser_context == browser_context &&
        it->extension_id == extension_id) {
      installs.erase(it);
      return true;
    }
  }
  return false;
}
}  // namespace

// static
void WebstorePrivateApi::SetEmbedderInstallHandler(
    EmbedderInstallHandler handler) {
  ArxEmbedderInstallHandler() = std::move(handler);
  if (ArxEmbedderInstallHandler().is_null()) {
    ArxEmbedderInstalls().clear();
  }
}

// static
void WebstorePrivateApi::RecordEmbedderInstall(
    content::BrowserContext* browser_context,
    const std::string& extension_id) {
  auto& installs = ArxEmbedderInstalls();
  if (installs.size() >= 16) {
    installs.erase(installs.begin());
  }
  installs.push_back({browser_context, extension_id, base::TimeTicks::Now()});
}
"""

STATUS_CHECK = """    std::u16string blocked_message) {
  content::WebContents* web_contents = GetSenderWebContents();
  if (install_status == kBlockedByPolicy) {
"""

ARX_STATUS_CHECK = """    std::u16string blocked_message) {
  content::WebContents* web_contents = GetSenderWebContents();
  if (!ArxEmbedderInstallHandler().is_null()) {
    // Arx: the embedder downloads, verifies and reviews the real package in
    // its own sheet. Chrome's dialogs and enterprise request flows don't apply.
    if (install_status == kBlockedByPolicy) {
      Respond(BuildResponse(api::webstore_private::Result::kBlockedByPolicy,
                            kWebstoreBlockByPolicy));
      return;
    }
    if (!web_contents || install_status == kCanRequest ||
        install_status == kRequestPending) {
      Respond(BuildResponse(api::webstore_private::Result::kUserCancelled,
                            kWebstoreUserCancelledError));
      return;
    }
    ArxEmbedderInstallHandler().Run(
        web_contents, details().id,
        base::BindOnce(&WebstorePrivateBeginInstallWithManifest3Function::
                           OnEmbedderInstallDone,
                       this));
    return;
  }
  if (install_status == kBlockedByPolicy) {
"""

PROMPT_DONE = """void WebstorePrivateBeginInstallWithManifest3Function::OnInstallPromptDone(
    ExtensionInstallPromptClient::DoneCallbackPayload payload) {
"""

ARX_PROMPT_DONE = """void WebstorePrivateBeginInstallWithManifest3Function::OnEmbedderInstallDone(
    api::webstore_private::Result result,
    const std::string& error) {
  // The embedder's own installation is finished; let the next request in.
  scoped_active_install_.reset();
  Respond(BuildResponse(result, error));
}

void WebstorePrivateBeginInstallWithManifest3Function::OnInstallPromptDone(
    ExtensionInstallPromptClient::DoneCallbackPayload payload) {
"""

COMPLETE = """  approval_ = g_pending_approvals.Get().PopApproval(browser_context(),
                                                    params->expected_id);
  if (!approval_) {
"""

ARX_COMPLETE = """  approval_ = g_pending_approvals.Get().PopApproval(browser_context(),
                                                    params->expected_id);
  // Arx: the embedder already installed this item for this profile.
  if (!approval_ &&
      ConsumeArxEmbedderInstall(browser_context(), params->expected_id)) {
    return RespondNow(NoArguments());
  }
  if (!approval_) {
"""

BUTTON = "el.nodeValue.replace(CHROME_NAME_REGEX, 'Helium')"
ARX_BUTTON = "el.nodeValue.replace(CHROME_NAME_REGEX, 'Arx')"


def patches():
    yield HEADER, API_DECLARATION, ARX_API_DECLARATION
    yield HEADER, FUNCTION_DECLARATION, ARX_FUNCTION_DECLARATION
    yield SOURCE, API_DEFINITION, ARX_API_DEFINITION
    yield SOURCE, STATUS_CHECK, ARX_STATUS_CHECK
    yield SOURCE, PROMPT_DONE, ARX_PROMPT_DONE
    yield SOURCE, COMPLETE, ARX_COMPLETE
    yield STORE_SCRIPT, BUTTON, ARX_BUTTON


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
