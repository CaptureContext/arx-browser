#ifndef ARX_SAFE_STORAGE_BRIDGE_H
#define ARX_SAFE_STORAGE_BRIDGE_H

namespace arx::safe_storage {

// DEV-900. Installs Arx's Safe Storage policy: a missing Keychain item never
// becomes a new key while saved passwords, cookies or autofill data exist, and
// a key that can't be read is explained with Try Again, instead of Chromium
// exiting. An unattended run reports `ARX_SAFE_STORAGE_UNAVAILABLE <status>`
// on stderr and exits with 70, a headless run's startup failure, because
// nobody can answer. Call once, on the UI thread,
// before Chromium's threads start (the user data directory must be known).
void Prepare(bool unattended);

}  // namespace arx::safe_storage

#endif
