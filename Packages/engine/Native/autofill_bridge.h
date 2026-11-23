#ifndef ARX_AUTOFILL_BRIDGE_H
#define ARX_AUTOFILL_BRIDGE_H

#include <cstddef>
#include <cstdint>

#include "chrome/browser/arx/ChromiumBridge.h"

class PrefService;
namespace content { class WebContents; }

namespace arx {
// ABI52 (DEV-875, DEV-893). Chromium's autofill suggestions (saved passwords,
// addresses, payment cards) for an ordinary page, drawn by the app. Native
// keeps the suggestions and their delegate; the app gets titles, labels and
// the field's bounds, never a password, card number or one-time code, and
// answers with an index. Fills that need it ask the device owner first.
using AutofillSuggestionsChanged = void (*)(uint64_t page, uint64_t session,
                                            const uint8_t* json, size_t size);

// Installs the embedder in every ChromeAutofillClient. Call once the runtime runs.
void StartAutofill(AutofillSuggestionsChanged changed);
// Hides every page's suggestions and removes the embedder.
void StopAutofill();

// An ordinary page with autofill clients; private pages never come here.
void AttachAutofillPage(content::WebContents* contents, uint64_t page);
void ForgetAutofillPage(uint64_t page);

// False when the session or index isn't current. A choice within 500 ms of
// the list appearing is ignored, as Chrome's popup ignores it, and the list stays.
bool AcceptAutofillSuggestion(uint64_t page, uint64_t session, uint32_t index);
void SelectAutofillSuggestion(uint64_t page, uint64_t session, int32_t index);
void DismissAutofillSuggestions(uint64_t page, uint64_t session);
// The reasons are the app's localized LocalAuthentication prompts, at most
// 256 bytes; a missing one refuses fills that need it.
// ABI52 (DEV-893). App-wide; both on until set. Applies to the profile of
// every attached page now, and through ApplyAutofillProducts as pages attach.
void SetAutofillProducts(bool addresses, bool cards);
// Writes the address and card switches into an ordinary profile's prefs, with
// Chrome's own card reauthentication off: Arx asks the device owner itself.
void ApplyAutofillProducts(PrefService* prefs);
void SetAutofillAuthentication(ArxAutofillAuthentication mode, const char* password_reason,
                               const char* card_reason);
}  // namespace arx

#endif
