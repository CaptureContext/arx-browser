#ifndef ARX_CREDENTIAL_IMPORT_H
#define ARX_CREDENTIAL_IMPORT_H

#include <cstddef>
#include <cstdint>

#include "chrome/browser/arx/ChromiumBridge.h"

class Profile;

namespace arx {
// ABI46 (DEV-650, DEV-830). Writes decrypted passwords and cookies from another
// Chromium browser into one ordinary profile, reads cookies back and undoes a
// batch. Records are copied before a call returns. Replies carry keys and
// counts only; nothing here logs or replies with a password or cookie value.
using CredentialImportReply = void (*)(uint64_t request, ArxCredentialImportStatus status,
                                       const uint8_t* json, size_t size);
// The ordinary profile for a key, or null for a private, unknown or stopped one.
// Looked up again at every asynchronous step, so a profile that went away in
// between replies UNAVAILABLE instead of being touched.
using CredentialImportProfile = Profile* (*)(const char* key);

void StartCredentialImport(CredentialImportReply reply, CredentialImportProfile profile);
// Replies CANCELLED to every pending request.
void StopCredentialImport();

void ImportPasswordRecords(uint64_t request, const char* profile_key,
                           const ArxImportedPassword* records, size_t count);
void ImportCookies(uint64_t request, const char* profile_key, const ArxImportedCookie* cookies,
                   size_t count);
void CheckCookies(uint64_t request, const char* profile_key, const char* keys);
void UndoCredentialImport(uint64_t request, const char* profile_key, const char* keys);
}  // namespace arx

#endif
