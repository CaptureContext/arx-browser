#ifndef ARX_EXTENSIONS_BRIDGE_H_
#define ARX_EXTENSIONS_BRIDGE_H_

#include <stdint.h>
#include "base/containers/span.h"
#include "base/functional/callback.h"
#include <string>

#include "chrome/browser/arx/ChromiumBridge.h"

class Profile;
class GURL;
namespace base { class FilePath; }
namespace content { class BrowserContext; class WebContents; }

namespace extensions { class Extension; }

namespace arx {
// Initialize runs before ChromeMain; other entry points and callbacks run on
// Chromium's UI sequence. The caller retains each persistent Profile until
// ShutdownExtensions has completed. Fixture files are written at startup only.
bool InitializeExtensions(const ArxEngineCallbacks& callbacks, bool enabled,
                          const base::FilePath& owned_fixture_directory,
                          bool prepare_signed_fixture = false,
                          const std::string& webstore_fixture_origin = {});
void ShutdownExtensions();
void AttachExtensionHelpers(content::WebContents* contents);
// DEV-889. Starts a new private context's split-mode extension background
// pages, as Chrome does when an incognito window opens. Ordinary profiles and
// a disabled extension system are ignored.
void PreparePrivateExtensions(Profile* profile);
void InspectExtensions(Profile* profile, const std::string& profile_key,
                       uint64_t request);
void ManageExtension(Profile* profile, const std::string& profile_key,
                     uint64_t request, uint64_t revision,
                     const std::string& extension_id, ArxExtensionAction action);
void LoadExtensionFixture(Profile* profile, const std::string& profile_key,
                          uint64_t request);
bool ExtensionViewsAvailable();
bool HasExtensionViewWork(const std::string& profile_key);
bool IsOwnedExtensionFixture(const extensions::Extension* extension);
// Whether this run is the extensions smoke's, with its compiled-in fixture.
bool IsExtensionFixtureRun();
bool IsEnabledExtensionPage(Profile* profile, const GURL& url);
// DEV-956. Whether the extension's action, popup and shortcuts work for a page
// in `context`: always in an ordinary profile, and in a private window only
// when the person allows it there and it can run there (a split-mode
// extension with an event page or service worker can't).
bool ExtensionRunsInContext(const extensions::Extension& extension,
                            content::BrowserContext* context);
void OpenExtensionView(Profile* profile, const std::string& profile_key,
    uint64_t request, uint64_t revision, const std::string& extension_id,
    ArxExtensionViewKind kind, uint64_t source_page, uint64_t source_generation);
void CancelExtensionRequest(uint64_t request);
// ABI20 developer folder load. Completion uses extensions_completed.
void LoadUnpackedExtension(Profile* profile, const std::string& profile_key,
                           uint64_t request, uint64_t revision, const std::string& directory);
// An unpacked read retains its profile until Chromium's completion.
bool HasExtensionLoadWork(const std::string& profile_key);
// DEV-880. An inventory or management request still owes this profile's reply.
bool HasExtensionRequestWork(const std::string& profile_key);
// DEV-880. Drops what the bridge keeps for an ordinary profile being released.
void ForgetExtensionProfile(const std::string& profile_key);
void InstallExtensionFixture(Profile* profile, const std::string& profile_key,
                             uint64_t request, uint64_t revision,
                             const std::string& expected_id, uint32_t variant);
void InstallExtensionCRX(Profile* profile, const std::string& profile_key,
                         uint64_t request, uint64_t revision,
                         const std::string& expected_id, const std::string& source_basename,
                         base::span<const uint8_t> bytes);
// ABI44 (DEV-765). A downloaded Chrome Web Store package for a new install of
// exactly `extension_id`. Completion uses extensions_completed, then `observer`.
void InstallWebstoreCRX(Profile* profile, const std::string& profile_key,
                        uint64_t request, uint64_t revision, const std::string& extension_id,
                        const std::string& source_name, base::span<const uint8_t> bytes,
                        base::OnceCallback<void(ArxExtensionStatus)> observer);
// ABI45 (DEV-776). A downloaded store package that updates the installed store
// extension `extension_id`; UP_TO_DATE when it isn't newer.
void UpdateWebstoreCRX(Profile* profile, const std::string& profile_key,
                       uint64_t request, uint64_t revision, const std::string& extension_id,
                       const std::string& source_name, base::span<const uint8_t> bytes,
                       base::OnceCallback<void(ArxExtensionStatus)> observer);
// extensions_completed for a request no extension operation owns.
void ReplyExtensionRequest(uint64_t request, const std::string& profile_key,
                           ArxExtensionStatus status);
}  // namespace arx

#endif  // ARX_EXTENSIONS_BRIDGE_H_
