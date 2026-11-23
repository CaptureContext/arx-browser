#ifndef ARX_EXTENSIONS_INSTALL_BRIDGE_H_
#define ARX_EXTENSIONS_INSTALL_BRIDGE_H_

#include <stdint.h>
#include <string>

#include "base/containers/span.h"
#include "base/functional/callback.h"
#include "chrome/browser/arx/ChromiumBridge.h"

class Profile;
namespace arx {
using ExtensionInstallValidation = base::RepeatingCallback<bool(
    Profile*, const std::string&, uint64_t)>;
using ExtensionInstallCompletion = base::OnceCallback<void(ArxExtensionStatus)>;

// UI sequence; no caller path survives intake. Physical work retains the profile
// slot and private staged CRX through Chromium completion and file-sequence drain.
// A non-empty `webstore_id` (DEV-765) installs a Chrome Web Store package: a new
// install of exactly that ID, verified against the store's publisher key and
// marked as from the store. `expected_id` is empty for it, or (ABI45, DEV-776)
// the same ID for a store update: the installed store extension, replaced only
// by a newer store package, and ARX_EXTENSION_UP_TO_DATE when it isn't newer.
bool BeginExtensionInstall(Profile* profile, const std::string& key,
                           uint64_t request, uint64_t revision,
                           const std::string& expected_id,
                           const std::string& webstore_id,
                           const std::string& source_basename,
                           base::span<const uint8_t> bytes,
                           const ArxEngineCallbacks& callbacks,
                           ExtensionInstallValidation validate,
                           ExtensionInstallCompletion complete);
bool ResolveExtensionInstall(Profile* profile, const std::string& key,
                             uint64_t request, uint64_t token, bool accept);
bool CancelExtensionInstall(uint64_t request);
bool HasExtensionInstallWork(const std::string& key);
void ShutdownExtensionInstalls();
}  // namespace arx
#endif
