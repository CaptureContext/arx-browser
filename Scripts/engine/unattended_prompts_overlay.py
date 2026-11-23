"""Refuse sign-in prompts nobody can answer and bound unattended shutdown (ABI22).

Applied after `http_auth_overlay`, whose inserted hook the main-frame edit
reuses. The WebAuthn and FedCM hooks are declared in the dependency-free
`chrome/browser/arx/unattended_hooks.h` and defined next to their call sites.
"""
from .overlay import replace_once

AUTH_SOURCE = "chrome/browser/ui/login/http_auth_coordinator.cc"
WEBAUTHN_SOURCE = "chrome/browser/webauthn/chrome_authenticator_request_delegate.cc"
FEDCM_SOURCE = "chrome/browser/ui/webid/identity_dialog_controller.cc"
WATCHDOG_HEADER = "chrome/browser/shutdown_watchdog_mac.h"
WATCHDOG_SOURCE = "chrome/browser/shutdown_watchdog_mac.cc"

HOOKS = '#include "chrome/browser/arx/unattended_hooks.h"  // nogncheck\n'


def patches():
    # A primary main-frame challenge is cancelled like an extension would: the
    # server's 401/407 body commits and no login prompt is built over it.
    yield AUTH_SOURCE, "    coordinator_->CreateLoginTabHelper(web_contents_.get());\n    if (did_cancel_from_extension_) {\n", '''    coordinator_->CreateLoginTabHelper(web_contents_.get());
    // ABI22: an embedder with nobody to answer cancels the main-frame challenge
    // too; the response body commits instead of a prompt over a blank page.
    if (!did_cancel_from_extension_ && EmbeddedPromptCancellation()) {
      auto cancellation = EmbeddedPromptCancellation();
      did_cancel_from_extension_ = cancellation.Run(web_contents_.get());
    }
    if (did_cancel_from_extension_) {
'''

    yield WEBAUTHN_SOURCE, '#include "chrome/browser/webauthn/chrome_authenticator_request_delegate.h"\n', '#include "chrome/browser/webauthn/chrome_authenticator_request_delegate.h"\n\n' + HOOKS
    yield WEBAUTHN_SOURCE, "void ChromeAuthenticatorRequestDelegate::RegisterProfilePrefs(\n", '''namespace {
arx::UnattendedPrompt g_unattended_web_authentication = nullptr;
}  // namespace

void arx::SetUnattendedWebAuthentication(UnattendedPrompt prompt) {
  g_unattended_web_authentication = prompt;
}

void ChromeAuthenticatorRequestDelegate::RegisterProfilePrefs(
'''
    yield WEBAUTHN_SOURCE, '''  if (MaybeHandleImmediateMediation(tai, passwords)) {
    std::move(immediate_not_found_callback_).Run();
    return;
  }
''', '''  if (MaybeHandleImmediateMediation(tai, passwords)) {
    std::move(immediate_not_found_callback_).Run();
    return;
  }

  // Arx: an embedder with nobody to answer cancels a modal request before any
  // dialog is built; the page sees NotAllowedError. Autofill and other
  // conditional requests show no dialog and stay pending.
  const UIPresentation presentation = dialog_controller_->ui_presentation();
  content::RenderFrameHost* frame = GetRenderFrameHost();
  if ((presentation == UIPresentation::kModal ||
       presentation == UIPresentation::kModalImmediate) &&
      g_unattended_web_authentication && cancel_callback_ && frame &&
      g_unattended_web_authentication(
          content::WebContents::FromRenderFrameHost(frame))) {
    // Cancelling destroys `this`; the callback is bound to a weak request.
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, std::move(cancel_callback_));
    return;
  }
'''

    yield FEDCM_SOURCE, '#include "chrome/browser/ui/webid/identity_dialog_controller.h"\n', '#include "chrome/browser/ui/webid/identity_dialog_controller.h"\n\n' + HOOKS
    yield FEDCM_SOURCE, '#include "base/functional/bind.h"\n', '#include "base/functional/bind.h"\n#include "base/task/sequenced_task_runner.h"\n'
    yield FEDCM_SOURCE, "bool IdentityDialogController::TrySetAccountView() {\n", '''namespace {
arx::UnattendedPrompt g_unattended_federated_sign_in = nullptr;
}  // namespace

void arx::SetUnattendedFederatedSignIn(UnattendedPrompt prompt) {
  g_unattended_federated_sign_in = prompt;
}

bool IdentityDialogController::TrySetAccountView() {
'''
    yield FEDCM_SOURCE, '''  if (!tab || tab->GetBrowserWindowInterface()->GetType() ==
                  BrowserWindowInterface::Type::TYPE_DEVTOOLS) {
    return false;
  }
''', '''  if (!tab || tab->GetBrowserWindowInterface()->GetType() ==
                  BrowserWindowInterface::Type::TYPE_DEVTOOLS) {
    // Arx: an embedder page has no Chrome tab, so no FedCM dialog can show.
    // Upstream leaves the request pending; an embedder with nobody to answer
    // dismisses it instead (no embargo), so the page's promise rejects.
    if (!tab && g_unattended_federated_sign_in &&
        g_unattended_federated_sign_in(rp_web_contents_) && on_dismiss_) {
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(std::move(on_dismiss_), DismissReason::kOther));
    }
    return false;
  }
'''

    yield WATCHDOG_HEADER, "namespace shutdown_watchdog {\n\n", '''namespace shutdown_watchdog {

// Arx: an embedder may give a slow shutdown longer than the default emergency
// timeout (`timeout_seconds` > 0) and learn of an expiry first. `expired` runs
// on the watchdog thread just before the process is terminated with
// `exit_code`; it must not block.
void SetEmbedderPolicy(int timeout_seconds, void (*expired)(int exit_code));

'''
    yield WATCHDOG_SOURCE, "// Emergency deadline once shutdown has been requested. Deliberately equal to\n", '''// Arx: the embedder's emergency timeout and expiry report, if any.
std::atomic_int g_embedder_timeout_seconds{0};
std::atomic<void (*)(int)> g_embedder_expired{nullptr};

void ReportEmbedderExpiry(int exit_code) {
  if (auto* expired = g_embedder_expired.load(std::memory_order_acquire)) {
    expired(exit_code);
  }
}

// Emergency deadline once shutdown has been requested. Deliberately equal to
'''
    yield WATCHDOG_SOURCE, "base::TimeDelta GetEmergencyTimeout() {\n", '''base::TimeDelta GetEmergencyTimeout() {
  if (const int seconds =
          g_embedder_timeout_seconds.load(std::memory_order_acquire);
      seconds > 0) {
    return base::Seconds(seconds);
  }
'''
    yield WATCHDOG_SOURCE, '''            "Teardown watchdog expired; recording dump and terminating.");
    base::debug::DumpWithoutCrashing();
    _exit(content::RESULT_CODE_HUNG);''', '''            "Teardown watchdog expired; recording dump and terminating.");
    ReportEmbedderExpiry(content::RESULT_CODE_HUNG);
    base::debug::DumpWithoutCrashing();
    _exit(content::RESULT_CODE_HUNG);'''
    yield WATCHDOG_SOURCE, '''          "SIGTERM shutdown watchdog expired; recording dump and re-raising.");
  base::debug::DumpWithoutCrashing();''', '''          "SIGTERM shutdown watchdog expired; recording dump and re-raising.");
  ReportEmbedderExpiry(128 + SIGTERM);
  base::debug::DumpWithoutCrashing();'''
    yield WATCHDOG_SOURCE, "void BlockOnSigtermShutdown() {\n", '''void SetEmbedderPolicy(int timeout_seconds, void (*expired)(int exit_code)) {
  g_embedder_timeout_seconds.store(timeout_seconds, std::memory_order_release);
  g_embedder_expired.store(expired, std::memory_order_release);
}

void BlockOnSigtermShutdown() {
'''


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
