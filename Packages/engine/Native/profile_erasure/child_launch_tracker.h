#ifndef ARX_PROFILE_ERASURE_CHILD_LAUNCH_TRACKER_H
#define ARX_PROFILE_ERASURE_CHILD_LAUNCH_TRACKER_H

#include <algorithm>
#include <cstdint>
#include <mutex>
#include <set>
#include <vector>

namespace arx::erasure {

struct ChildIdentity {
  int32_t pid = 0;
  uint64_t seconds = 0;
  uint64_t microseconds = 0;
  bool operator==(const ChildIdentity&) const = default;
};

// Shared by the actual content launch hooks and the isolated policy harness.
// Tokens exist before dispatch to the launcher sequence, independently of the
// weak owner. Missing callbacks and unreadable identities permanently deny a
// clean receipt; neither a missing host nor a failed post proves process exit.
class ChildLaunchTracker {
 public:
  static constexpr size_t kMaximumChildren = 256;
  struct Snapshot {
    bool complete = false;
    std::vector<ChildIdentity> identities;
  };

  void StartObservation() {
    std::lock_guard guard(lock_);
    if (started_) {
      complete_ = false;
      return;
    }
    started_ = true;
    observing_ = true;
  }
  bool IsObserving() {
    std::lock_guard guard(lock_);
    return observing_;
  }
  void StartLaunch(const void* token) {
    std::lock_guard guard(lock_);
    if (!observing_) return;
    if (!token || pending_.size() == kMaximumChildren ||
        !pending_.insert(token).second) complete_ = false;
  }
  void DidNotLaunch(const void* token) { Complete(token, {}, false, true); }
  void Launched(const void* token, ChildIdentity identity) {
    Complete(token, identity, true,
             identity.pid > 0 && identity.seconds > 0 && identity.microseconds < 1000000);
  }
  void Unknown(const void* token) { Complete(token, {}, false, false); }
  Snapshot FinishObservation() {
    std::lock_guard guard(lock_);
    const bool complete = observing_ && complete_ && pending_.empty();
    observing_ = false;
    return {complete, identities_};
  }

 private:
  void Complete(const void* token, ChildIdentity identity, bool launched, bool known) {
    std::lock_guard guard(lock_);
    if (!observing_) return;
    if (pending_.erase(token) != 1 || !known) complete_ = false;
    if (!launched || !known ||
        std::find(identities_.begin(), identities_.end(), identity) != identities_.end()) return;
    if (identities_.size() == kMaximumChildren) {
      complete_ = false;
      return;
    }
    identities_.push_back(identity);
  }
  std::mutex lock_;
  bool started_ = false;
  bool observing_ = false;
  bool complete_ = true;
  std::set<const void*> pending_;
  std::vector<ChildIdentity> identities_;
};

}  // namespace arx::erasure
#endif
