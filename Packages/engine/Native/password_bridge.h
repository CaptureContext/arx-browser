#ifndef ARX_PASSWORD_BRIDGE_H
#define ARX_PASSWORD_BRIDGE_H

#include <cstdint>

#include "chrome/browser/arx/ChromiumBridge.h"

namespace content { class WebContents; }

namespace arx {
// ABI35 (DEV-708). Chromium's password manager, per ordinary profile. Values
// stay in the browser process and the renderer: nothing here hands a password
// to Swift, and replies carry only IDs, usernames, origins and outcomes.
using PasswordSaveOffered = void (*)(uint64_t page, uint64_t token, const char* origin,
                                     const char* username, bool update);
using SignInReply = void (*)(uint64_t request, uint64_t page, ArxSignInStatus status,
                             const uint8_t* json, size_t size);

// Installs the save-prompt hook. Call once the runtime is running.
void StartPasswords(PasswordSaveOffered offered, SignInReply reply);
// Drops every offer and sign-in, and removes the hook.
void StopPasswords();

// Attaches the autofill and password manager clients to an ordinary page.
// Private pages get nothing: their store redirects to the parent profile's.
void AttachPasswordClients(content::WebContents* contents, uint64_t page);
void ForgetPasswordPage(uint64_t page);

bool AnswerPasswordSave(uint64_t page, uint64_t token, ArxPasswordSaveAnswer answer);
void RequestSignInCredentials(content::WebContents* contents, uint64_t page, uint64_t request);
void AttemptSignIn(content::WebContents* contents, uint64_t page, uint64_t request,
                   const char* document, const char* frame, uint32_t credential,
                   uint32_t timeout_ms);
void CancelSignIn(uint64_t request);
}  // namespace arx

#endif
