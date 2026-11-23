#ifndef ARX_SAFE_STORAGE_HOOKS_H
#define ARX_SAFE_STORAGE_HOOKS_H

// DEV-900 Safe Storage. The "Arx Storage Key" Keychain item holds the key to
// every saved password and cookie; if it is ever replaced, they can't be read.
// Dependency-free apart from base's callback forward declarations, so
// Chromium's os_crypt sources can include it; each setter and name is defined
// next to its call site by `Scripts/engine/safe_storage_overlay.py`.

#include <string>

#include "base/functional/callback_forward.h"

namespace arx {

// DEV-1013. The Safe Storage Keychain item's service ("Arx Storage Key") and
// account ("Arx") names. The outer app's `ArxStorageKeyService` and
// `ArxStorageKeyAccount` Info.plist values replace them, so Arx Dev keeps an
// item of its own and never asks for the installed Arx's.
std::string SafeStorageKeyServiceName();
std::string SafeStorageKeyAccountName();

// Asked on a Keychain worker thread when the key's Keychain item is missing:
// true lets Chromium create a new key. Without a policy it may, as upstream.
// Set once, before threads start.
using SafeStorageKeyCreationPolicy = bool (*)();
void SetSafeStorageKeyCreationPolicy(SafeStorageKeyCreationPolicy policy);

// Called on the UI thread when reading the key failed and its retries ran
// out. `status` is the OSStatus. Loading data stays paused until `retry` reads
// the Keychain again. Without a handler, Chromium shows its error and exits.
// Set once, before threads start.
using SafeStorageUnavailableHandler = void (*)(int status,
                                               base::OnceClosure retry);
void SetSafeStorageUnavailableHandler(SafeStorageUnavailableHandler handler);

}  // namespace arx

#endif
