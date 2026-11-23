#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <optional>
#include <string>
#include <string_view>
#include <vector>
namespace extensions {
using ExtensionId = std::string;
struct Extension {};
enum UnloadedExtensionReason { kUnload };
enum UninstallReason { kUninstall };
using DisableReasonSet = std::vector<int>;
}
namespace content { struct BrowserContext {}; }
namespace base { using FilePath = std::string; }
uint64_t NextRevision() { static uint64_t revision = 0; return ++revision; }
using extensions::ExtensionId;
struct LegacyObserver {
  int changes = 0;
  virtual ~LegacyObserver() = default;
  virtual void OnExtensionPrefsUpdated(const extensions::ExtensionId&) { ++changes; }
  // DEFAULT_FORWARDING
};
struct Inventory {
  uint64_t revision_ = NextRevision();
  std::string last_json_;
  base::FilePath last_fixture_path_;
  bool owned_fixture_ = false;
  size_t diagnostic_count_ = 0;
  std::optional<std::string> snapshot = "ordinary metadata";
  int reads = 0;
  std::optional<std::string> Read(const base::FilePath& fixture_path) {
    last_fixture_path_ = fixture_path;
    ++reads;
    auto json = snapshot;
    if (!json) return std::nullopt;
    // READ_TAIL
  // OBSERVERS
  // CHANGED
};
int main() {
  LegacyObserver legacy;
  legacy.OnExtensionPrefUpdated("id", "active_bit");
  assert(legacy.changes == 1); // existing observers still see exactly one
  legacy.OnExtensionPrefUpdated("id", "granted_permissions.api");
  assert(legacy.changes == 2);
  legacy.OnExtensionPrefsUpdated("id");
  assert(legacy.changes == 3);
  Inventory inventory;
  assert(inventory.Read("exact owned fixture"));
  const auto initial = inventory.revision_;
  for (const auto* noise : {"active_bit", "running", "is_active"}) {
    inventory.OnExtensionPrefUpdated("id", noise);
    inventory.OnExtensionPrefUpdated("id", noise); // same-value write also quiet
    assert(inventory.revision_ == initial);
    assert(inventory.last_fixture_path_ == "exact owned fixture");
  }
  // Hidden security keys are NOT in public metadata. Both legs of an ABA still
  // invalidate, as do unknown/empty keys and legacy key-less notifications.
  for (const auto* key : {"granted_permissions.api", "desired_active_permissions.explicit_host",
       "runtime_granted_permissions.api", "withholding_permissions", "incognito", "allow_file_access",
       "disable_reasons", "manifest", "active_bit.suffix", "unknown", ""}) {
    auto revision = inventory.revision_;
    inventory.OnExtensionPrefUpdated("id", key);
    assert(inventory.revision_ != revision);
    revision = inventory.revision_;
    inventory.OnExtensionPrefUpdated("id", key);
    assert(inventory.revision_ != revision && inventory.snapshot == "ordinary metadata");
  }
  auto revision = inventory.revision_;
  inventory.OnExtensionPrefsUpdated("id"); assert(inventory.revision_ != revision);
  // Every dedicated registry/permission observer stays unconditional even if
  // a transition returns to the same serialized state before the next read.
  auto changed = [&](auto action) {
    auto before = inventory.revision_; action(); assert(inventory.revision_ != before);
    before = inventory.revision_; action(); assert(inventory.revision_ != before);
  };
  changed([&] { inventory.OnExtensionLoaded(nullptr, nullptr); });
  changed([&] { inventory.OnExtensionReady(nullptr, nullptr); });
  changed([&] { inventory.OnExtensionUnloaded(nullptr, nullptr, extensions::kUnload); });
  changed([&] { inventory.OnExtensionEnabled(nullptr, nullptr); });
  changed([&] { inventory.OnExtensionInstalled(nullptr, nullptr, false); });
  changed([&] { inventory.OnExtensionUninstalled(nullptr, nullptr, extensions::kUninstall); });
  changed([&] { inventory.OnExtensionDisableReasonsChanged("id", {}); });
  changed([&] { inventory.OnExtensionRuntimePermissionsChanged("id"); });
  revision = inventory.revision_;
  inventory.snapshot = "changed policy metadata";
  inventory.OnExtensionPrefUpdated("id", "active_bit");
  assert(inventory.revision_ != revision);
  revision = inventory.revision_;
  inventory.snapshot.reset();
  inventory.OnExtensionPrefUpdated("id", "running");
  assert(inventory.revision_ != revision); // failed bounded read is fail closed
  Inventory diagnostics; diagnostics.owned_fixture_ = true;
  for (int i = 0; i < 100; ++i)
    diagnostics.OnExtensionPrefUpdated("id", "\n" + std::string(200, 'x'));
  assert(diagnostics.diagnostic_count_ == 64);
}
