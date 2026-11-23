#ifndef ARX_CONSENT_AUTHORITY_H_
#define ARX_CONSENT_AUTHORITY_H_

#include <cstdint>
#include <limits>

namespace arx {
// Native document/view proofs supplement this latch; the generation prevents
// ABA if a source navigates, is hidden, transferred, or disabled then reenabled.
class ConsentAuthority {
 public:
  uint64_t generation() const { return generation_; }
  bool enabled() const { return enabled_; }
  bool Current(uint64_t generation) const {
    return enabled_ && generation && generation == generation_;
  }
  void Invalidate() {
    if (generation_ == std::numeric_limits<uint64_t>::max()) {
      generation_ = 0;
      enabled_ = false;
    } else if (generation_) {
      ++generation_;
    }
  }
  void Configure(bool enabled) {
    Invalidate();
    enabled_ = enabled && generation_;
  }
 private:
  uint64_t generation_ = 1;
  bool enabled_ = false;
};
}  // namespace arx
#endif
