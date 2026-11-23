#ifndef ARX_UNATTENDED_HOOKS_H
#define ARX_UNATTENDED_HOOKS_H

// ABI22 unattended sign-in prompts. Dependency-free so Chromium's WebAuthn and
// FedCM sources can include it; each setter is defined next to its call site
// by the engine overlay. Both are called on the UI thread.
namespace content { class WebContents; }

namespace arx {
// Returns true when nobody can answer a prompt for `contents` (may be null).
using UnattendedPrompt = bool (*)(content::WebContents* contents);
// A modal WebAuthn request is cancelled before its dialog when this returns true.
void SetUnattendedWebAuthentication(UnattendedPrompt prompt);
// A FedCM request failed because an Arx page cannot show its dialog.
void SetUnattendedFederatedSignIn(UnattendedPrompt prompt);
}  // namespace arx

#endif
