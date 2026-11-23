#ifndef ARX_INSPECTION_CLICK_POLICY_H_
#define ARX_INSPECTION_CLICK_POLICY_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <map>
#include <string>

namespace arx::inspection {
inline constexpr size_t kMaximumClickReceipts = 4096;
inline constexpr size_t kMaximumScopeClickReceipts = 256;
inline constexpr size_t kMaximumPhysicalClicks = 16;

enum class Dispatch { kNone = 0, kDispatched = 1, kPossible = 2, kUnchanged = 3 };
struct ClickBinding {
  uint64_t page;
  std::string scope, snapshot, reference;
  uint32_t kind = 0;  // 0 click, 1 replace text, 2 select value, 3 nearest-container scroll.
  std::array<uint8_t, 32> payload_digest{};
  bool operator==(const ClickBinding&) const = default;
};
struct ClickReceipt {
  ClickBinding binding;
  Dispatch disposition = Dispatch::kNone;
};

// Never evict receipts during this runtime. Expiry/reconnect must not make an
// operation replayable; exhaustion fails closed until a new runtime starts.
class ClickReceipts final {
 public:
  const ClickReceipt* Find(const std::string& operation) const {
    auto found = receipts_.find(operation);
    return found == receipts_.end() ? nullptr : &found->second;
  }
  bool Reserve(const std::string& operation, const ClickBinding& binding) {
    if (receipts_.contains(operation) || receipts_.size() >= kMaximumClickReceipts)
      return false;
    auto count = scope_counts_.find(binding.scope);
    if (count != scope_counts_.end() && count->second >= kMaximumScopeClickReceipts)
      return false;
    receipts_.emplace(operation, ClickReceipt{binding});
    ++scope_counts_[binding.scope];
    return true;
  }
  void Record(const std::string& operation, Dispatch disposition) {
    auto found = receipts_.find(operation);
    if (found != receipts_.end()) found->second.disposition = disposition;
  }
  Dispatch Duplicate(const std::string& operation, const ClickBinding& binding) const {
    auto* found = Find(operation);
    return found && found->binding == binding ? found->disposition : Dispatch::kPossible;
  }
  void Clear() { receipts_.clear(); scope_counts_.clear(); }
 private:
  std::map<std::string, ClickReceipt> receipts_;
  std::map<std::string, size_t> scope_counts_;
};
}  // namespace arx::inspection
#endif
