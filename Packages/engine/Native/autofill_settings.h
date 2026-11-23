#ifndef ARX_AUTOFILL_SETTINGS_H
#define ARX_AUTOFILL_SETTINGS_H

#include <cstddef>
#include <cstdint>

#include "chrome/browser/arx/ChromiumBridge.h"

class Profile;

namespace arx {
// ABI52 (DEV-893). Settings › Autofill for one ordinary profile: its addresses
// and local payment cards over Chromium's PersonalDataManager. Replies list
// addresses and cards by network, last four digits, name and expiry. A card
// number is read from an AppKit field the caller lends and is never part of a
// reply or a log.
using AutofillDataReply = void (*)(uint64_t request, ArxAutofillDataStatus status,
                                   const uint8_t* json, size_t size);

void StartAutofillSettings(AutofillDataReply reply);
// Replies CANCELLED to every pending request.
void StopAutofillSettings();

// A null profile (unknown, private or stopped) replies UNAVAILABLE.
void ListAutofillData(Profile* profile, uint64_t request);
void SaveAutofillAddress(Profile* profile, uint64_t request, const char* json);
void SaveAutofillCard(Profile* profile, uint64_t request, const char* json, void* number_field);
void RemoveAutofillData(Profile* profile, uint64_t request, const char* id);
void CancelAutofillData(uint64_t request);
}  // namespace arx

#endif
