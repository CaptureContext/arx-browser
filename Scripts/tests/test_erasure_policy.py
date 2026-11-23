"""Execute staged production launch, startup, and published-ledger policy."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine import erasure_overlay
from Scripts.engine.config import PACKAGE


def run_policy(source):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        path = root / "policy.cc"
        path.write_text(source)
        executable = root / "policy"
        result = subprocess.run([
            "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
            "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
            "-I" + str(PACKAGE / "Native"), str(path), "-o", str(executable),
        ], capture_output=True, text=True, timeout=40)
        if result.returncode:
            raise AssertionError(result.stderr)
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout


def replacement_containing(text):
    return next(new for _, _, new in erasure_overlay.patches() if text in new)


class ErasurePolicyTests(unittest.TestCase):
    def test_durable_retirement_rejects_active_private_preparing_and_download_users(self):
        engine = (PACKAGE / "Native/engine_bridge.mm").read_text()
        # DEV-880: retirement shares its in-use check with idle profile release.
        policy = "bool OrdinaryProfileInUse(" + engine.split("bool OrdinaryProfileInUse(", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
        policy += "bool ProfileErasureMayQueue(" + engine.split("bool ProfileErasureMayQueue(", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
        source = r'''
#include <cassert>
#include <map>
#include <memory>
#include <set>
#include <string>
struct Profile {
  bool download = false;
  Profile* original = nullptr;
  Profile* GetOriginalProfile() { return original ? original : this; }
};
struct KeepAlive { Profile* value; Profile* profile() { return value; } };
struct Contents { Profile* value; Profile* GetBrowserContext() { return value; } };
struct Page { Contents value; Contents* contents() { return &value; } };
struct Runtime {
  bool running = true;
  std::map<std::string, int> preparing_profiles;
  std::map<std::string, Profile*> private_profiles;
  std::map<Profile*, int> retired_private_profiles;
  std::map<std::string, std::unique_ptr<KeepAlive>> profiles;
  std::map<int, std::unique_ptr<Page>> pages;
};
Runtime& State() { static Runtime value; return value; }
void CheckThread() {}
bool DownloadsRetainProfile(Profile* profile) { return profile->download; }
std::set<std::string> physical_installs, physical_loads, physical_consent, physical_extension_views;
bool PageConsentRetainsProfile(const std::string& key) { return physical_consent.contains(key); }
bool HasExtensionInstallWork(const std::string& key) { return physical_installs.contains(key); }
bool HasExtensionViewWork(const std::string& key) { return physical_extension_views.contains(key); }
bool HasExtensionLoadWork(const std::string& key) { return physical_loads.contains(key); }
std::set<std::string> physical_requests;
bool HasExtensionRequestWork(const std::string& key) { return physical_requests.contains(key); }
'''
        source += policy
        source += r'''
int main() {
  auto& state = State();
  Profile target, survivor;
  physical_extension_views.insert("target");
  assert(!ProfileErasureMayQueue("target")); // The API reply may outlive its offered page/map row.
  physical_extension_views.clear();
  physical_extension_views.insert("survivor");
  assert(ProfileErasureMayQueue("target"));
  physical_extension_views.clear();
  assert(ProfileErasureMayQueue("target"));
  physical_installs.insert("target");
  assert(!ProfileErasureMayQueue("target")); // No live profile entry yet.
  physical_installs.clear();
  assert(ProfileErasureMayQueue("target"));
  physical_installs.insert("survivor");
  assert(ProfileErasureMayQueue("target"));
  physical_installs.clear();
  physical_loads.insert("target");
  assert(!ProfileErasureMayQueue("target")); // An unpacked read retains the profile.
  physical_loads.clear();
  physical_loads.insert("survivor");
  assert(ProfileErasureMayQueue("target"));
  physical_loads.clear();
  physical_consent.insert("target");
  assert(!ProfileErasureMayQueue("target")); // Work survives the closed page/map entry.
  physical_consent.clear();
  physical_consent.insert("survivor");
  assert(ProfileErasureMayQueue("target"));
  physical_consent.clear();
  physical_requests.insert("target");
  assert(!ProfileErasureMayQueue("target")); // An inventory request still owes its reply.
  physical_requests.clear();
  state.running = false; assert(!ProfileErasureMayQueue("target")); state.running = true;
  state.private_profiles["target"] = &target;
  assert(!ProfileErasureMayQueue("target")); state.private_profiles.clear();
  state.preparing_profiles["target"] = 1;
  assert(!ProfileErasureMayQueue("target")); state.preparing_profiles["target"] = 0;
  state.profiles["target"] = std::make_unique<KeepAlive>(&target);
  physical_installs.insert("target");
  assert(!ProfileErasureMayQueue("target")); physical_installs.clear();
  physical_extension_views.insert("target");
  assert(!ProfileErasureMayQueue("target")); physical_extension_views.clear();
  target.download = true; assert(!ProfileErasureMayQueue("target")); target.download = false;
  state.pages[1] = std::make_unique<Page>(Contents{&target});
  assert(!ProfileErasureMayQueue("target"));
  state.pages[1]->value.value = &survivor;
  assert(ProfileErasureMayQueue("target"));
  // DEV-889: a private window's context is its opener's child, while open and
  // while it's being destroyed.
  Profile opened{false, &target}, elsewhere{false, &survivor};
  state.private_profiles["private"] = &opened;
  assert(!ProfileErasureMayQueue("target")); state.private_profiles.clear();
  state.retired_private_profiles[&opened] = 1;
  assert(!ProfileErasureMayQueue("target")); state.retired_private_profiles.clear();
  state.private_profiles["private"] = &elsewhere;
  state.retired_private_profiles[&elsewhere] = 1;
  assert(ProfileErasureMayQueue("target"));
}
'''
        run_policy(source)

    def test_launch_tracker_handles_missing_owners_and_unresolved_launches(self):
        fixture = Path(__file__).parent / "fixtures/child_launch_tracker.cc"
        self.assertIn("ARX_ERASURE_LAUNCH_POLICY_SUCCESS", run_policy(fixture.read_text()))

    def test_startup_fallback_does_not_inherit_strict_authority(self):
        # Compile the actual generated methods, while the singleton OS outcomes
        # are controlled. No existing browser's locks or processes are touched.
        strict = replacement_containing("ProcessSingleton::StrictCreationResult ProcessSingleton::CreateWithoutRecovery()")
        strict = strict.split("#if BUILDFLAG(IS_MAC)\n", 1)[1].split("\n#endif", 1)[0]
        chrome = replacement_containing("ChromeProcessSingleton::CreateForArxMaintenance() {")
        chrome = chrome.split("#if BUILDFLAG(IS_MAC)\n", 1)[1].split("\n#endif", 1)[0]
        conflict = replacement_containing("strict_lock_conflict_ = true;").split("    if (base::IsLink", 1)[0]
        source = r'''
#include <cassert>
#define CHECK(x) assert(x)
struct ProcessSingleton {
  enum NotifyResult { PROCESS_NONE, PROCESS_NOTIFIED, PROFILE_IN_USE, LOCK_ERROR };
  enum class StrictCreationResult { kCreated, kLockConflict, kFailed };
  bool deny_lock_recovery_ = false, strict_lock_conflict_ = false;
  bool conflict = false, creation_ok = true;
  StrictCreationResult CreateWithoutRecovery();
  bool Create();
};
struct ChromeProcessSingleton {
  bool is_singleton_instance_ = false, created_without_recovery_ = false;
  int recoveries = 0;
  ProcessSingleton process_singleton_;
  ProcessSingleton::NotifyResult ordinary_result = ProcessSingleton::PROCESS_NONE;
  ProcessSingleton::NotifyResult CreateForArxMaintenance();
  ProcessSingleton::NotifyResult NotifyOtherProcessOrCreate() {
    assert(!process_singleton_.deny_lock_recovery_);
    assert(!created_without_recovery_);
    ++recoveries;
    is_singleton_instance_ = ordinary_result == ProcessSingleton::PROCESS_NONE;
    return ordinary_result;
  }
};
'''
        source += strict + "\n" + chrome + "\n"
        source += "bool ProcessSingleton::Create() { if (conflict) {\n" + conflict + "\n} return creation_ok; }\n"
        source += r'''
int main() {
  {
    ChromeProcessSingleton singleton;
    assert(singleton.CreateForArxMaintenance() == ProcessSingleton::PROCESS_NONE);
    assert(singleton.is_singleton_instance_ && singleton.created_without_recovery_);
    assert(singleton.recoveries == 0 && !singleton.process_singleton_.deny_lock_recovery_);
  }
  {
    ChromeProcessSingleton singleton;
    singleton.process_singleton_.conflict = true;
    assert(singleton.CreateForArxMaintenance() == ProcessSingleton::PROCESS_NONE);
    assert(singleton.is_singleton_instance_ && !singleton.created_without_recovery_);
    assert(singleton.recoveries == 1 && !singleton.process_singleton_.deny_lock_recovery_);
  }
  {
    ChromeProcessSingleton singleton;
    singleton.process_singleton_.conflict = true;
    singleton.ordinary_result = ProcessSingleton::PROCESS_NOTIFIED;
    assert(singleton.CreateForArxMaintenance() == ProcessSingleton::PROCESS_NOTIFIED);
    assert(!singleton.is_singleton_instance_ && !singleton.created_without_recovery_);
  }
  {
    ChromeProcessSingleton singleton;
    singleton.process_singleton_.creation_ok = false;
    assert(singleton.CreateForArxMaintenance() == ProcessSingleton::LOCK_ERROR);
    assert(!singleton.is_singleton_instance_ && !singleton.created_without_recovery_);
    assert(singleton.recoveries == 0 && !singleton.process_singleton_.deny_lock_recovery_);
  }
}
'''
        run_policy(source)

    def test_strict_lock_creation_rejects_matching_stale_pid_target(self):
        lock_policy = replacement_containing("  bool created_lock;")
        source = r'''
#include <cassert>
#include <filesystem>
#include <string>
#include <unistd.h>
#define BUILDFLAG(x) 1
namespace fs = std::filesystem;
namespace base {
bool CreateSymbolicLink(const fs::path& target, const fs::path& path) {
  std::error_code error;
  fs::create_symlink(target, path, error);
  return !error;
}
}
int compatibility_calls = 0;
bool SymlinkPath(const fs::path& target, const fs::path& path) {
  ++compatibility_calls;
  // The upstream compatibility behavior deliberately accepts a matching PID
  // target after an EEXIST result; strict acquisition must never enter it.
  return base::CreateSymbolicLink(target, path) || fs::read_symlink(path) == target;
}
bool CreateLock(bool deny_lock_recovery_, const fs::path& lock_path_) {
  const fs::path symlink_content("fixture-host-123");
'''
        source += lock_policy + "return false; } return true; }\n"
        source += r'''
int main() {
  char pattern[] = "/private/tmp/arx-strict-lock-owned-XXXXXX";
  char* directory = mkdtemp(pattern);
  assert(directory);
  const fs::path root(directory), lock = root / "SingletonLock";
  assert(CreateLock(true, lock));
  assert(compatibility_calls == 0);
  assert(!CreateLock(true, lock));
  assert(compatibility_calls == 0);
  assert(fs::read_symlink(lock) == "fixture-host-123");
  assert(CreateLock(false, lock));
  assert(compatibility_calls == 1);
  fs::remove_all(root);
}
'''
        run_policy(source)

    def test_profile_loader_rejects_private_quarantine_names(self):
        bridge = (PACKAGE / "Native/profile_erasure/bridge.cc").read_text()
        path_policy = "bool ProfilePathAllowed(" + bridge.split("bool ProfilePathAllowed(", 1)[1].split("void RegisterProfile", 1)[0]
        registered = "std::string ProfileID(" + bridge.split("std::string ProfileID(", 1)[1].split("struct WorkerResult", 1)[0]
        header = (PACKAGE / "Native/profile_erasure/bridge.h").read_text()
        bootstrap = next(line for line in header.splitlines() if "kBootstrapProfile[]" in line)
        source = r'''
#include "profile_erasure/journal.h"
#include <cassert>
#include <filesystem>
#include <set>
using namespace arx::erasure;
namespace base {
struct FilePath {
  std::filesystem::path path;
  explicit FilePath(std::filesystem::path path) : path(std::move(path)) {}
  FilePath DirName() const { return FilePath(path.parent_path()); }
  FilePath BaseName() const { return FilePath(path.filename()); }
  std::string value() const { return path.string(); }
  bool operator==(const FilePath&) const = default;
};
}
namespace chrome { constexpr char kSystemProfileDir[] = "System Profile"; }
struct State {
  bool enabled = true, active = true, startup_complete = true;
  base::FilePath root{"/owned/Browser"};
  std::string legacy = "22222222-2222-2222-2222-222222222222";
  std::set<std::string> retiring, requested_profiles;
  Snapshot snapshot;
};
State& Current() { static State state; return state; }
bool Enabled() { return Current().enabled; }
bool ProfileKeyAllowed(const std::string& key);
'''
        source += bootstrap + "\n" + registered + path_policy
        source += r'''
int main() {
  auto& state = Current();
  const std::string survivor = "33333333-3333-3333-3333-333333333333";
  const std::string retired = "44444444-4444-4444-4444-444444444444";
  state.snapshot.records = {
    {state.legacy, Storage::kLegacyDefault, "", false, false},
    {survivor, Storage::kOrdinary, "", false, false},
    {retired, Storage::kOrdinary, "request", true, false},
  };
  state.requested_profiles = {state.legacy, survivor, retired};
  assert(ProfilePathAllowed(base::FilePath("/owned/Browser/Default")));
  assert(ProfilePathAllowed(base::FilePath("/owned/Browser/Arx-" + survivor)));
  assert(!ProfilePathAllowed(base::FilePath("/owned/Browser/Arx-" + retired)));
  assert(!ProfilePathAllowed(base::FilePath("/owned/Browser/.arx-erasing-" + survivor)));
  assert(!ProfilePathAllowed(base::FilePath("/owned/Browser/.arx-profile-erasure-v1")));
  assert(!ProfilePathAllowed(base::FilePath("/another/Browser/Arx-" + survivor)));
  state.requested_profiles.clear();
  assert(!ProfilePathAllowed(base::FilePath("/owned/Browser/Arx-" + survivor)));
  state.active = false;
  assert(!ProfilePathAllowed(base::FilePath("/owned/Browser/Default")));
  assert(ProfilePathAllowed(base::FilePath("/owned/Browser/Arx-Bootstrap")));
  state.startup_complete = false;
  assert(!ProfilePathAllowed(base::FilePath("/owned/Browser/Arx-Bootstrap")));
}
'''
        run_policy(source)

    def test_worker_result_revokes_authority_without_ui_journal_reads(self):
        bridge = (PACKAGE / "Native/profile_erasure/bridge.cc").read_text()
        result_policy = bridge.split("struct WorkerResult {", 1)[1].split("}  // namespace", 1)[0]
        admission = bridge.split("bool ProfileKeyAllowed(const std::string& key) {", 1)[1].split("void RegisterProfile", 1)[0]
        registered = bridge.split("std::string ProfileID(", 1)[1].split("struct WorkerResult", 1)[0]
        source = r'''
#include "profile_erasure/journal.h"
#include <cassert>
#include <memory>
#include <set>
#include <utility>
using namespace arx::erasure;
struct Ledger {
  bool usable = true;
  Snapshot snapshot;
  bool CanUseLedger() const { return usable; }
  Snapshot GetSnapshot() const { return snapshot; }
};
struct State {
  bool enabled = false, active = false;
  std::unique_ptr<Ledger> journal;
  std::string legacy = "legacy";
  std::set<std::string> retiring;
  Snapshot snapshot;
  Status status = Status::kPending;
};
State& Current() { static State state; return state; }
bool Enabled() { return Current().enabled; }
'''
        source += "std::string ProfileID(" + registered
        source += "struct WorkerResult {" + result_policy
        source += "bool ProfileKeyAllowed(const std::string& key) {" + admission
        source += r'''
int main() {
  auto& state = Current();
  assert(ProfileKeyAllowed("unknown") && PrivateKeyAllowed("unknown"));
  state.enabled = true;
  state.active = true;
  state.journal = std::make_unique<Ledger>();
  state.journal->snapshot.durable = true;
  state.journal->snapshot.may_erase = true;
  state.journal->snapshot.records = {
    {"legacy", Storage::kLegacyDefault, "", false, false},
    {"survivor", Storage::kOrdinary, "", false, false},
    {"retired", Storage::kOrdinary, "request", true, true},
  };
  Publish(CollectResult(Status::kPending));
  assert(state.active && ProfileKeyAllowed("") && ProfileKeyAllowed("survivor"));
  assert(!ProfileKeyAllowed("retired") && !ProfileKeyAllowed("unknown"));
  assert(!PrivateKeyAllowed("survivor") && !PrivateKeyAllowed("retired"));
  assert(PrivateKeyAllowed("fresh-private"));
  state.retiring.insert("survivor");
  assert(!ProfileKeyAllowed("survivor") && !PrivateKeyAllowed("survivor"));
  state.journal->snapshot.records[2].verified = false;
  const auto cleanup_blocked = CollectResult(Status::kOwnershipChanged);
  assert(cleanup_blocked.snapshot.durable && cleanup_blocked.ledger_usable);
  assert(cleanup_blocked.snapshot.records[2].retired);
  assert(cleanup_blocked.snapshot.records[2].request_id == "request");
  assert(cleanup_blocked.snapshot.records[2].progress == Progress::kBlocked);
  assert(!cleanup_blocked.snapshot.records[0].retired && cleanup_blocked.snapshot.records[0].request_id.empty());
  assert(cleanup_blocked.snapshot.records[0].progress == Progress::kActive);
  state.journal->usable = false;
  const auto result = CollectResult(Status::kOwnershipChanged);
  assert(!result.ledger_usable && !result.snapshot.durable && !result.snapshot.may_erase);
  for (const auto& record : result.snapshot.records) assert(!record.verified);
  Publish(result);
  assert(!state.active && !ProfileKeyAllowed("") && !PrivateKeyAllowed("fresh-private"));
  state.journal.reset();
  Publish(CollectResult(Status::kIO));
  assert(!state.active && !state.snapshot.durable && state.snapshot.records.empty());
}
'''
        run_policy(source)
