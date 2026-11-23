#ifndef ARX_EXTENSION_INSTALL_AUTHORITY_H_
#define ARX_EXTENSION_INSTALL_AUTHORITY_H_

#include <stdint.h>
#include <string>
#include <utility>

namespace arx {
// Stored only in the native installation operation. Public prompt metadata is
// descriptive; it cannot reconstruct a consumed or replaced native authority.
class ExtensionInstallAuthority {
 public:
  ExtensionInstallAuthority(std::string profile, uint64_t revision,
                            std::string digest, std::string id,
                            std::string version, uint64_t token)
      : profile_(std::move(profile)), revision_(revision),
        digest_(std::move(digest)), id_(std::move(id)),
        version_(std::move(version)), token_(token) {}

  bool Consume(const std::string& profile, uint64_t revision,
               const std::string& digest, const std::string& id,
               const std::string& version, uint64_t token) {
    if (!token_ || token != token_) return false;
    const bool matches = profile == profile_ && revision == revision_ &&
        digest == digest_ && id == id_ && version == version_;
    // An attempt consumes this prompt even if its proof has gone stale.
    token_ = 0;
    return matches;
  }
  void Invalidate() { token_ = 0; }

 private:
  const std::string profile_;
  const uint64_t revision_;
  const std::string digest_;
  const std::string id_;
  const std::string version_;
  uint64_t token_;
};
}  // namespace arx
#endif
