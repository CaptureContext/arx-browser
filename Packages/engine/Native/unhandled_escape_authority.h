#ifndef ARX_UNHANDLED_ESCAPE_AUTHORITY_H
#define ARX_UNHANDLED_ESCAPE_AUTHORITY_H

#include <cstdint>

namespace arx {

// A single outstanding physical key. Retaining its NSEvent alongside this
// policy prevents pointer reuse. A newer key supersedes an unreturned ACK.
// Page separately validates both captured WeakDocumentPtrs and actual focus.
class UnhandledEscapeAuthority {
 public:
  void Observe(uintptr_t event, uint64_t generation, int64_t now) {
    event_ = event;
    generation_ = generation;
    observed_ = now;
  }

  bool Consume(uintptr_t event, uint64_t generation, int64_t now) {
    if (!event || event != event_) return false;
    const bool valid = generation && generation == generation_ &&
        now >= observed_ && now - observed_ <= 5000;
    Clear();
    return valid;
  }

  void Clear() { event_ = 0; generation_ = 0; observed_ = 0; }

 private:
  uintptr_t event_ = 0;
  uint64_t generation_ = 0;
  int64_t observed_ = 0;
};

}  // namespace arx
#endif
