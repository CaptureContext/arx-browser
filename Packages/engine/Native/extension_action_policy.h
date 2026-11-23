#ifndef ARX_EXTENSION_ACTION_POLICY_H
#define ARX_EXTENSION_ACTION_POLICY_H

#include <cstdint>
#include <cmath>
#include <limits>
#include <set>

namespace arx {
// Retained menu items are one-use, bounded and never recycle identifiers.
// The host separately resolves its exact weak document and enabled Extension.
class ExtensionActionAuthority {
 public:
  uint64_t Issue(uint64_t generation) {
    if (!generation || !next_) return 0;
    if (generation_ != generation) { Clear(); generation_ = generation; }
    if (choices_.size() >= 512) return 0;
    const uint64_t token = next_;
    next_ = next_ == std::numeric_limits<uint64_t>::max() ? 0 : next_ + 1;
    choices_.insert(token);
    return token;
  }
  bool Consume(uint64_t token, uint64_t generation, bool source_current,
               bool extension_current) {
    if (!choices_.contains(token)) return false;
    const bool allowed = generation && generation_ == generation &&
        source_current && extension_current;
    Clear();
    return allowed;
  }
  void Clear() { choices_.clear(); generation_ = 0; }
 private:
  uint64_t next_ = 1, generation_ = 0;
  std::set<uint64_t> choices_;
};
// A native shortcut consumes one physical timestamp/event once. The retained
// NSEvent lives in its host; timestamps also reject reconstructed event replays.
class ExtensionShortcutReplayGuard {
 public:
  bool Consume(uintptr_t event, double timestamp, double host_epoch, double now) {
    if (!event || event == last_event_ || !std::isfinite(timestamp) ||
        !std::isfinite(host_epoch) || !std::isfinite(now) || timestamp <= last_timestamp_ ||
        timestamp < host_epoch || timestamp > now || now - timestamp > 5) return false;
    last_event_ = event;
    last_timestamp_ = timestamp;
    return true;
  }
 private:
  uintptr_t last_event_ = 0;
  double last_timestamp_ = 0;
};
// Posted close work belongs to one popup instance, never its replacement.
class ExtensionPopupEpoch {
 public:
  bool Advance() {
    posted_ = 0;
    if (epoch_ == std::numeric_limits<uint64_t>::max()) return false;
    ++epoch_;
    return true;
  }
  uint64_t ScheduleClose() {
    if (posted_ == epoch_) return 0;
    posted_ = epoch_;
    return epoch_;
  }
  bool Current(uint64_t epoch) const { return epoch && epoch == epoch_; }
 private:
  uint64_t epoch_ = 1, posted_ = 0;
};
}  // namespace arx
#endif
