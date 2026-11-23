#ifndef ARX_GESTURES_SELECTION_H_
#define ARX_GESTURES_SELECTION_H_

#include <algorithm>
#include <cmath>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "ownership.h"

namespace arx::gestures {

struct HistoryEntry {
  int index = -1;
  int identity = 0;
  std::string title;
  std::string url;
};

// A snapshot of only this WebContents' navigation controller, nearest first.
// Indices alone never authorize a jump; the controller rechecks every native
// identity immediately before consuming the gesture and calling GoToIndex.
class Selection {
 public:
  bool Begin(Identity gesture, std::vector<HistoryEntry> entries) {
    Reset();
    if (entries.empty() || entries.size() > 256) return false;
    std::set<int> identities;
    for (const auto& entry : entries) {
      if (!entry.identity || entry.index < 0 ||
          !identities.insert(entry.identity).second) return false;
    }
    gesture_ = gesture;
    entries_ = std::move(entries);
    selected_ = 0;
    return true;
  }

  bool Update(Identity gesture, double rows) {
    if (!Current(gesture) || !std::isfinite(rows)) return false;
    selected_ = static_cast<size_t>(std::clamp(
        std::round(rows), 0.0, static_cast<double>(entries_.size() - 1)));
    return true;
  }

  bool Step(Identity gesture, int delta) {
    return Update(gesture, static_cast<double>(selected_) + delta);
  }

  std::optional<HistoryEntry> Target(Identity gesture) const {
    if (!Current(gesture)) return std::nullopt;
    return entries_[selected_];
  }

  void Reset() {
    gesture_.reset();
    entries_.clear();
    selected_ = 0;
  }

  bool Current(Identity gesture) const { return gesture_ == gesture; }
  const std::vector<HistoryEntry>& entries() const { return entries_; }
  size_t selected() const { return selected_; }

 private:
  std::optional<Identity> gesture_;
  std::vector<HistoryEntry> entries_;
  size_t selected_ = 0;
};

}  // namespace arx::gestures
#endif  // ARX_GESTURES_SELECTION_H_
