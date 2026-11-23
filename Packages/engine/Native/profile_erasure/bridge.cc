#include "chrome/browser/arx/profile_erasure/bridge.h"
#include "chrome/browser/arx/engine_bridge.h"

#include <memory>
#include <set>
#include <utility>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/no_destructor.h"
#include "base/run_loop.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/threading/platform_thread.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/chrome_process_singleton.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/common/chrome_paths_internal.h"
#include "chrome/common/chrome_constants.h"
#include "content/public/browser/child_process_launcher_utils.h"

namespace arx::erasure {
namespace {
struct State {
  bool enabled = false, attempt_erasure = false, active = false, shutdown_started = false;
  bool startup_complete = false;
  base::FilePath root, cache;
  std::string installation, legacy;
  scoped_refptr<base::SequencedTaskRunner> worker;
  std::unique_ptr<Journal> journal;  // Access only on the worker until ChromeMain returns.
  std::set<std::string> retiring, requested_profiles;
  size_t pending_operations = 0;
  Snapshot snapshot;
  Status status = Status::kPending;
};
State& Current() { static base::NoDestructor<State> value; return *value; }
std::string ProfileID(const std::string& key) { return key.empty() ? Current().legacy : key; }
bool Registered(const std::string& profile) {
  for (const auto& item : Current().snapshot.records)
    if (item.profile_id == profile) return true;
  return false;
}
struct WorkerResult {
  Status status;
  Snapshot snapshot;
  bool ledger_usable;
};
WorkerResult CollectResult(Status status) {
  auto* journal = Current().journal.get();
  const bool usable = journal && journal->CanUseLedger();
  Snapshot snapshot = journal ? journal->GetSnapshot() : Snapshot{};
  if (!usable) {
    snapshot.durable = false;
    snapshot.may_erase = false;
    for (auto& record : snapshot.records) {
      record.verified = false;
      if (record.retired) record.progress = Progress::kBlocked;
    }
  } else if (status != Status::kOK && status != Status::kPending && status != Status::kVerified) {
    for (auto& record : snapshot.records)
      if (record.retired && !record.verified) record.progress = Progress::kBlocked;
  }
  return {status, std::move(snapshot), usable};
}
void Publish(const WorkerResult& result) {
  Current().status = result.status;
  Current().snapshot = result.snapshot;
  if (!result.ledger_usable) Current().active = false;
}
}  // namespace

bool Configure(const base::FilePath& root, std::string installation,
               std::string legacy_profile, bool attempt_erasure) {
  auto& state = Current();
  if (state.enabled || !root.IsAbsolute() ||
      !base::Uuid::ParseLowercase(installation).is_valid() ||
      !base::Uuid::ParseLowercase(legacy_profile).is_valid()) return false;
  state.enabled = true;
  state.root = root;
  chrome::GetUserCacheDirectory(root, &state.cache);
  state.installation = std::move(installation);
  state.legacy = std::move(legacy_profile);
  state.attempt_erasure = attempt_erasure;
  return true;
}
bool Enabled() { return Current().enabled; }
bool RequiresStrictAcquisition() { return Enabled() && Current().attempt_erasure; }
void BeforeThreads() {
  if (Enabled()) content::BeginArxChildLaunchObservation();
}
void BeforeProfiles() {
  auto& state = Current();
  if (!state.enabled) return;
  auto* manager = g_browser_process->profile_manager();
  manager->SetArxProfileCreationGuard(base::BindRepeating(&ProfilePathAllowed));
  // The singleton must protect this exact root, not another RunWithOptions
  // path. No target may have loaded through another startup hook beforehand.
  if (manager->user_data_dir() != state.root ||
      !ChromeProcessSingleton::IsSingletonInstance() || !manager->GetLoadedProfiles().empty()) {
    state.status = Status::kBusy;
    return;
  }
  bool strict = ChromeProcessSingleton::GetInstance()->WasCreatedWithoutRecovery();
  state.worker = base::ThreadPool::CreateSequencedTaskRunner(
      {base::MayBlock(), base::TaskPriority::USER_BLOCKING,
       base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  base::RunLoop barrier(base::RunLoop::Type::kNestableTasksAllowed);
  // The IO watcher was started in PostCreateThreads. Pump the UI sequence while
  // the worker performs IO so ProcessSingletonStartupLock can ACK/queue callers.
  bool posted = state.worker->PostTaskAndReplyWithResult(FROM_HERE, base::BindOnce([](bool strict) {
    auto& state = Current();
    Status status = PrepareOwnedDirectory(state.cache.value());
    if (status == Status::kOK) {
      state.journal = Journal::Open(state.root.value(), state.cache.value(),
                                    state.installation, state.legacy, &status);
    }
    // Generic Configure has no root-creation/singleton-admission transaction.
    // A new ledger on an old root must never bootstrap deletion authority.
    if (state.journal) status = state.journal->RequirePriorCleanBoundary();
    if (status == Status::kOK) status = state.journal->BeginRun(CurrentProcessIdentity(), strict);
    if (status == Status::kOK) {
      // Existing roots never obtain generic clean-lineage deletion authority.
      // Per-target quarantine has its own consent + authoritative boot boundary.
      status = state.journal->ResumeQuarantinedAfterBoot();
      if (status == Status::kPending || status == Status::kVerified)
        status = state.journal->StageForNextBoot();
    }
    if (state.journal) state.journal->FinishStartup();
    return CollectResult(status);
  }, strict), base::BindOnce([](base::RepeatingClosure quit, WorkerResult result) {
    Publish(result);
    Current().active = result.ledger_usable;
    Current().startup_complete = true;
    quit.Run();
  }, barrier.QuitClosure()));
  if (posted) barrier.Run();
  else state.status = Status::kPending;
}
void BeforeShutdown() {
  auto& state = Current();
  if (!state.enabled) return;
  state.active = false;
  state.shutdown_started = true;
}
void AfterNativeRun(int exit_code) {
  auto& state = Current();
  if (!state.enabled) return;
  // ChromeMain has completed its ThreadPool/BLOCK_SHUTDOWN work. No native
  // profile writer may remain; any missing process identity leaves a dirty run.
  const auto children = content::FinishArxChildLaunchObservation();
  if (exit_code == 0 && state.shutdown_started && state.journal && children.complete) {
    bool captured = true;
    for (const auto& child : children.identities) {
      if (state.journal->TrackChild({child.pid, child.seconds, child.microseconds}) != Status::kOK)
        captured = false;
    }
    if (captured) {
      const auto end = base::TimeTicks::Now() + base::Seconds(2);
      while (state.journal->FinishCleanRun() == Status::kPending && base::TimeTicks::Now() < end)
        base::PlatformThread::Sleep(base::Milliseconds(20));
    }
  }
  state.journal.reset();
}
bool ProfilePathAllowed(const base::FilePath& path) {
  auto& state = Current();
  if (!state.enabled) return true;
  if (!state.startup_complete || path.DirName() != state.root) return false;
  const auto name = path.BaseName().value();
  if (name == kBootstrapProfile || name == chrome::kSystemProfileDir) return true;
  if (!state.active) return false;
  std::string key;
  if (name != "Default") {
    if (!name.starts_with("Arx-")) return false;
    key = name.substr(4);
  }
  // Only an explicitly registered profile can load; background autoload and
  // old Local State entries cannot recreate unknown or retired identities.
  return state.requested_profiles.contains(ProfileID(key)) && ProfileKeyAllowed(key);
}
bool ProfileKeyAllowed(const std::string& key) {
  if (!Enabled()) return true;
  if (!Current().active || Current().retiring.contains(ProfileID(key))) return false;
  for (const auto& record : Current().snapshot.records)
    if (record.profile_id == ProfileID(key)) return !record.retired;
  return false;
}
bool PrivateKeyAllowed(const std::string& key) {
  return !Enabled() || (Current().active && !Registered(key) && !Current().retiring.contains(key));
}
void RegisterProfile(const std::string& key, base::OnceCallback<void(bool)> reply) {
  auto& state = Current();
  if (!state.enabled) { std::move(reply).Run(true); return; }
  if (!state.active || !state.worker || state.pending_operations >= 16 ||
      state.retiring.contains(ProfileID(key)) || (!key.empty() && !base::Uuid::ParseLowercase(key).is_valid())) {
    std::move(reply).Run(false);
    return;
  }
  ++state.pending_operations;
  auto profile = ProfileID(key);
  auto storage = key.empty() ? Storage::kLegacyDefault : Storage::kOrdinary;
  auto replies = base::SplitOnceCallback(base::BindOnce(
      [](std::string key, base::OnceCallback<void(bool)> reply, WorkerResult result) {
        --Current().pending_operations;
        Publish(result);
        if (Current().active && result.status == Status::kOK)
          Current().requested_profiles.insert(ProfileID(key));
        std::move(reply).Run(Current().active && result.status == Status::kOK && ProfileKeyAllowed(key));
      }, key, std::move(reply)));
  bool posted = state.worker->PostTaskAndReplyWithResult(
      FROM_HERE, base::BindOnce([](std::string profile, Storage storage) {
        return CollectResult(Current().journal->RegisterProfile(profile, storage));
      }, profile, storage), std::move(replies.first));
  if (!posted) std::move(replies.second).Run({Status::kPending, {}, false});
}
void QueueProfile(const std::string& key, Storage expected_storage,
                  std::string request_id, uint64_t revision,
                  base::OnceCallback<void(Status, Snapshot)> reply) {
  auto& state = Current();
  if (!state.active || !state.worker || state.pending_operations >= 16 ||
      !arx::ProfileErasureMayQueue(key)) {
    std::move(reply).Run(Status::kBusy, state.snapshot);
    return;
  }
  const auto profile = ProfileID(key);
  const auto storage = key.empty() ? Storage::kLegacyDefault : Storage::kOrdinary;
  if (storage != expected_storage || revision != state.snapshot.revision ||
      !ProfileKeyAllowed(key) || !base::Uuid::ParseLowercase(request_id).is_valid()) {
    std::move(reply).Run(Status::kStale, state.snapshot);
    return;
  }
  ++state.pending_operations;
  state.retiring.insert(profile);
  auto replies = base::SplitOnceCallback(base::BindOnce(
      [](std::string profile, base::OnceCallback<void(Status, Snapshot)> reply, WorkerResult result) {
        --Current().pending_operations;
        if (result.snapshot.durable) Current().retiring.erase(profile);
        Publish(result);
        std::move(reply).Run(result.status, std::move(result.snapshot));
      }, profile, std::move(reply)));
  bool posted = state.worker->PostTaskAndReplyWithResult(
      FROM_HERE, base::BindOnce([](std::string profile, Storage storage,
                                  std::string request, uint64_t revision) {
        return CollectResult(Current().journal->Queue(profile, storage, request, revision));
      }, profile, expected_storage, std::move(request_id), revision), std::move(replies.first));
  if (!posted) std::move(replies.second).Run({Status::kPending, {}, false});
}
Snapshot CurrentSnapshot() { return Current().snapshot; }
Status CurrentStatus() { return Current().status; }
}  // namespace arx::erasure
