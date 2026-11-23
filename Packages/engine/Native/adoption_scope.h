#ifndef ARX_ADOPTION_SCOPE_H
#define ARX_ADOPTION_SCOPE_H

#include <cstdint>
#include <map>

namespace arx {
// Synchronous child offers can reenter the embedder. Keep an explicitly closed
// source alive until Chromium's caller has unwound; never defer atomic close
// consumption while reporting success. Native IDs do not recycle.
class AdoptionScope {
 public:
  bool Begin(uint64_t source) {
    if (!source || (scopes_.size() >= 16 && !scopes_.contains(source))) return false;
    auto& scope = scopes_[source];
    if (scope.depth >= 16) return false;
    ++scope.depth;
    return true;
  }
  bool Busy(uint64_t source) const { return scopes_.contains(source); }
  bool DestroyRequested(uint64_t source) const {
    auto found = scopes_.find(source);
    return found != scopes_.end() && found->second.destroy;
  }
  bool DeferDestroy(uint64_t source) {
    auto found = scopes_.find(source);
    if (found == scopes_.end()) return false;
    found->second.destroy = true;
    return true;
  }
  // Returns true only when this exact source's outermost offer requested close.
  bool End(uint64_t source) {
    auto found = scopes_.find(source);
    if (found == scopes_.end()) return false;
    if (--found->second.depth) return false;
    const bool destroy = found->second.destroy;
    scopes_.erase(found);
    return destroy;
  }
 private:
  struct Scope { unsigned depth = 0; bool destroy = false; };
  std::map<uint64_t, Scope> scopes_;
};
}  // namespace arx
#endif
