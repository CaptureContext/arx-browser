#ifndef ARX_LINK_CONTEXT_POLICY_H
#define ARX_LINK_CONTEXT_POLICY_H

#include <cmath>
#include <cstdint>

namespace arx {

// Pure admission/lifetime policy. Page independently retains and rechecks both
// source-frame and primary WeakDocumentPtr identities before exposing a token.
class LinkContextAuthority {
 public:
  bool Open(uint64_t token, uint64_t generation, bool coordinates_verified,
            double x, double y, double width, double height) {
    token_ = generation_ = 0;
    if (!token || !generation || !coordinates_verified || !std::isfinite(x) ||
        !std::isfinite(y) || !std::isfinite(width) || !std::isfinite(height) ||
        width <= 0 || height <= 0 || x < 0 || y < 0 || x >= width || y >= height)
      return false;
    token_ = token;
    generation_ = generation;
    return true;
  }

  bool Current(uint64_t token, uint64_t generation, bool documents_current) const {
    return token && token == token_ && generation && generation == generation_ &&
        documents_current;
  }

  bool Dismiss(uint64_t token) {
    if (!token || token != token_) return false;
    token_ = generation_ = 0;
    return true;
  }

  uint64_t token() const { return token_; }

 private:
  uint64_t token_ = 0, generation_ = 0;
};

}  // namespace arx
#endif
