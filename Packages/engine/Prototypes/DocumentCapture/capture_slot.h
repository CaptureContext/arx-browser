#ifndef ARX_DOCUMENT_CAPTURE_SLOT_H_
#define ARX_DOCUMENT_CAPTURE_SLOT_H_

#include "base/check.h"
#include "base/unguessable_token.h"

namespace arx::capture {
// UI-sequence only. The lease lives through physical renderer/compositor/encoder
// drainage, independently of a logical completion or cancellation callback.
inline base::UnguessableToken& PhysicalOwner() {
  static base::UnguessableToken owner;
  return owner;
}
inline bool Busy() { return !PhysicalOwner().is_empty(); }
class Lease final {
 public:
  Lease() {
    CHECK(!Busy());
    PhysicalOwner() = token_;
  }
  ~Lease() { CHECK(PhysicalOwner() == token_); PhysicalOwner() = {}; }
  Lease(const Lease&) = delete;
  Lease& operator=(const Lease&) = delete;
 private:
  const base::UnguessableToken token_ = base::UnguessableToken::Create();
};
}  // namespace arx::capture
#endif
