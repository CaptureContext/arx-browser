#ifndef ARX_PASSWORD_SETTINGS_H
#define ARX_PASSWORD_SETTINGS_H

#include <cstdint>

#include "chrome/browser/arx/ChromiumBridge.h"

class Profile;

namespace arx {
// ABI36 (DEV-721). Saved passwords in Arx Settings, one ordinary profile at a
// time, over Chromium's SavedPasswordsPresenter and PasswordImporter. Replies
// carry sites, usernames and counts. A password value is read from an AppKit
// field the caller lends, or written to the pasteboard or a lent field after
// LocalAuthentication; it is never part of a reply.
using SavedPasswordsReply = void (*)(uint64_t request, ArxSavedPasswordsStatus status,
                                     const uint8_t* json, size_t size);

void StartPasswordSettings(SavedPasswordsReply reply);
// Replies CANCELLED to every pending request and drops each profile's presenter.
void StopPasswordSettings();

// A null profile (unknown, private or stopped) replies UNAVAILABLE.
void ListSavedPasswords(Profile* profile, uint64_t request);
void SaveSavedPassword(Profile* profile, uint64_t request, const char* listing,
                       uint32_t credential, const char* url, const char* username,
                       void* password_field);
void RemoveSavedPassword(Profile* profile, uint64_t request, const char* listing,
                         uint32_t credential);
void RevealSavedPassword(Profile* profile, uint64_t request, const char* listing,
                         uint32_t credential, ArxPasswordReveal mode, const char* reason,
                         void* field);
void ImportSavedPasswords(Profile* profile, uint64_t request, const char* path);
void CancelSavedPasswords(uint64_t request);
// DEV-880. Drops the profile's presenter before the profile is released; its
// pending requests reply FAILED. A later request makes a new one.
void ForgetPasswordSettingsProfile(Profile* profile);
}  // namespace arx

#endif
