#ifndef ARX_PROFILE_ERASURE_BRIDGE_H
#define ARX_PROFILE_ERASURE_BRIDGE_H

#include <string>
#include "base/functional/callback.h"
#include "base/files/file_path.h"
#include "chrome/browser/arx/profile_erasure/journal.h"

namespace arx::erasure {
inline constexpr char kBootstrapProfile[] = "Arx-Bootstrap";
inline constexpr char kStrictStartupSwitch[] = "arx-profile-maintenance";

// Separate native entry point setup. Existing Run/RunWithOptions never call it.
// A future append-only ABI can expose this exact opt-in; no Swift live factory
// or command line alone can configure installation/legacy ownership.
bool Configure(const base::FilePath& root, std::string installation,
               std::string legacy_profile, bool attempt_erasure);
bool Enabled();
bool RequiresStrictAcquisition();
void BeforeThreads();
void BeforeProfiles();
void BeforeShutdown();
void AfterNativeRun(int exit_code);

bool ProfilePathAllowed(const base::FilePath& path);
bool ProfileKeyAllowed(const std::string& key);
bool PrivateKeyAllowed(const std::string& key);
void RegisterProfile(const std::string& key, base::OnceCallback<void(bool)> reply);
void QueueProfile(const std::string& key, Storage expected_storage,
                  std::string request_id, uint64_t revision,
                  base::OnceCallback<void(Status, Snapshot)> reply);
Snapshot CurrentSnapshot();
Status CurrentStatus();
}  // namespace arx::erasure
#endif
