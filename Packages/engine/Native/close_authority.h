#ifndef ARX_CLOSE_AUTHORITY_H
#define ARX_CLOSE_AUTHORITY_H

#include <cstdint>

#include "ChromiumBridge.h"

namespace arx {

// Per-Page policy. Logical cancellation cannot stop the physical before-unload
// round. Only its tagged completion/reset releases that occupied slot.
// Page additionally validates its captured WeakDocumentPtr before every grant/use.
class CloseAuthority {
 public:
  uint64_t generation() const { return generation_; }
  bool busy() const { return phase_ != Phase::kIdle; }
  bool waiting() const { return phase_ == Phase::kWaiting || phase_ == Phase::kCancelled; }
  uint64_t request() const { return request_; }

  ArxCloseStatus Start(uint64_t request, uint64_t generation) {
    if (!request || !generation || generation != generation_) return ARX_CLOSE_STALE;
    if (busy()) return ARX_CLOSE_BUSY;
    phase_ = Phase::kWaiting;
    request_ = request;
    approved_generation_ = generation;
    return ARX_CLOSE_SUCCESS;
  }

  void Invalidate() {
    // Exhaustion permanently fails closed, rather than reusing an old epoch.
    if (generation_) ++generation_;
    if (phase_ == Phase::kApproved) Clear();
  }

  ArxCloseStatus Decide(bool proceed, bool document_current, uint64_t token) {
    if (!waiting()) return ARX_CLOSE_STALE;
    ArxCloseStatus status = ARX_CLOSE_SUCCESS;
    if (phase_ == Phase::kCancelled) status = ARX_CLOSE_CANCELLED;
    else if (!document_current || !generation_ || approved_generation_ != generation_)
      status = ARX_CLOSE_STALE;
    else if (!proceed) status = ARX_CLOSE_REFUSED;
    else if (!token) status = ARX_CLOSE_UNAVAILABLE;
    if (status != ARX_CLOSE_SUCCESS) { Clear(); return status; }
    phase_ = Phase::kApproved;
    token_ = token;
    return status;
  }

  bool Valid(uint64_t request, uint64_t token, bool document_current) const {
    return phase_ == Phase::kApproved && request && request == request_ &&
        token && token == token_ && generation_ &&
        generation_ == approved_generation_ && document_current;
  }

  ArxCloseStatus Consume(uint64_t request, uint64_t token, bool document_current) {
    const bool valid = Valid(request, token, document_current);
    // A foreign/malformed token cannot revoke another request's valid authority.
    if (request == request_ && token && token == token_) Clear();
    return valid ? ARX_CLOSE_SUCCESS : ARX_CLOSE_STALE;
  }

  // Only the tagged physical reset/destruction callback may release a slot
  // without an ACK. Logical cancellation must retain it until this boundary.
  bool Reset(uint64_t request) {
    if (!request || request != request_ || !waiting()) return false;
    Clear();
    return true;
  }

  void Cancel(uint64_t request) {
    if (!request || request != request_) return;
    if (waiting()) phase_ = Phase::kCancelled;
    else Clear();
  }

 private:
  enum class Phase { kIdle, kWaiting, kCancelled, kApproved };
  void Clear() {
    phase_ = Phase::kIdle;
    request_ = approved_generation_ = token_ = 0;
  }
  Phase phase_ = Phase::kIdle;
  uint64_t generation_ = 1;
  uint64_t request_ = 0, approved_generation_ = 0, token_ = 0;
};

}  // namespace arx
#endif
