#ifndef ARX_WEBSTORE_INSTALL_BRIDGE_H_
#define ARX_WEBSTORE_INSTALL_BRIDGE_H_

#include <stdint.h>
#include <string>

#include "chrome/browser/arx/ChromiumBridge.h"

class Profile;

namespace arx {
// ABI44 (DEV-765). The Chrome Web Store's Add to Chrome in an ordinary page asks
// the app (webstore_install_requested); the app then has native download,
// verify and review the real package through the same staged install as a
// local CRX (extensions_install_bridge). Configure runs before ChromeMain; an
// empty fixture origin means Google's store. Every other entry point runs on
// Chromium's UI sequence.
void ConfigureWebstoreInstalls(const ArxEngineCallbacks& callbacks, bool enabled,
                               const std::string& fixture_origin);
// `profile` is the native profile for `profile_key`, or null when there is none.
void InstallWebstoreExtension(Profile* profile, const std::string& profile_key,
                              uint64_t request, uint64_t revision, uint64_t token);
// ABI45 (DEV-776). Updates an installed store extension from the store; see
// update_webstore_extension. `profile` is null when the key has no profile.
void UpdateWebstoreExtension(Profile* profile, const std::string& profile_key,
                             uint64_t request, uint64_t revision, const std::string& extension_id);
// ABI47 (DEV-845). Installs a store item by ID with no store page; see
// install_webstore_extension_by_id. `profile` is null when the key has no profile.
void InstallWebstoreExtensionByID(Profile* profile, const std::string& profile_key,
                                  uint64_t request, uint64_t revision,
                                  const std::string& extension_id);
void DeclineWebstoreInstall(uint64_t token);
// cancel_extension_request for an install or update that is still downloading.
bool CancelWebstoreDownload(uint64_t request);
void ShutdownWebstoreInstalls();
}  // namespace arx
#endif
