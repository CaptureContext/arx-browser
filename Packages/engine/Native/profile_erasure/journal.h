#ifndef ARX_PROFILE_ERASURE_JOURNAL_H
#define ARX_PROFILE_ERASURE_JOURNAL_H

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace arx::erasure {

// This module is native-only. Paths are root inputs, never per-request inputs.
// Chromium supplies the cache root using GetUserCacheDirectory(user_data_dir).
enum class Status {
  kOK, kBusy, kInvalid, kCorrupt, kOwnershipChanged, kNotRegistered,
  kRetired, kStale, kLimit, kIO, kPending, kVerified,
};
enum class Storage { kOrdinary, kLegacyDefault };
enum class Phase { kOriginal, kQuarantined, kRemoved };
enum class Progress { kActive, kAwaitingStartup, kQuarantinePending, kRestartRequired,
                      kVerificationPending, kErased, kBlocked };
enum class Boundary { kQueued, kRenamed, kQuarantineRecorded, kQuarantineSealed, kRemoved, kRemovalRecorded, kVerified };

struct ProcessIdentity {
  int32_t pid = 0;
  uint64_t seconds = 0;
  uint64_t microseconds = 0;
  bool operator==(const ProcessIdentity&) const = default;
};

// A missing or unreadable process is not conflated with a proven exit.
enum class ProcessState { kSameProcess, kExited, kUnknown };
Status PrepareOwnedDirectory(const std::string& path);
ProcessIdentity CurrentProcessIdentity();
ProcessState ReadProcessState(const ProcessIdentity& identity);
// Authoritative Darwin kernel boot-session UUID, normalized to lowercase.
// An unavailable, malformed, or nil UUID returns empty; uptime is never used.
std::string CurrentBootSession();
using BootSessionReader = std::function<std::string()>;

struct Record {
  std::string profile_id;
  Storage storage = Storage::kOrdinary;
  std::string request_id;
  bool retired = false;
  bool verified = false;
  Progress progress = Progress::kActive;  // Derived snapshot state, never persisted.
};

struct Snapshot {
  uint64_t revision = 0;
  bool may_erase = false;
  bool durable = false;
  std::vector<Record> records;
};

// Creation provenance only: this is not proof of continuous writer admission or
// singleton ownership and cannot authorize deletion or establish a clean run.
// The factory creates unpredictable new children under existing owned parents;
// it never adopts existing data/cache roots or removes anything on failure.
class CreatedRoots {
 public:
  static std::unique_ptr<CreatedRoots> Create(
      const std::string& data_parent, const std::string& cache_parent, Status* status);
  ~CreatedRoots();
  CreatedRoots(CreatedRoots&&) noexcept;
  CreatedRoots& operator=(CreatedRoots&&) noexcept;
  CreatedRoots(const CreatedRoots&) = delete;
  CreatedRoots& operator=(const CreatedRoots&) = delete;

  const std::string& root() const;
  const std::string& cache() const;
  Status Validate() const;

 private:
  struct Impl;
  explicit CreatedRoots(std::unique_ptr<Impl> implementation);
  std::unique_ptr<Impl> impl_;
};

class Journal {
 public:
  static constexpr size_t kMaximumProfiles = 128;
  static constexpr size_t kMaximumChildren = 256;
  static constexpr size_t kMaximumJournalBytes = 128 * 1024;

  // Caller must already own Chromium's actual ProcessSingleton. The additional
  // journal flock serializes the tail of clean native shutdown after Chromium
  // releases its singleton; it is never accepted as profile deletion authority.
  // Initial clean bootstrap additionally requires caller proof of exclusive
  // root creation and continuous writer admission. Generic bridge startup has
  // no such proof and must call RequirePriorCleanBoundary before BeginRun.
  static std::unique_ptr<Journal> Open(
      const std::string& root, const std::string& cache_root,
      const std::string& installation_id, const std::string& legacy_profile_id,
      Status* status, BootSessionReader read_boot_session = CurrentBootSession);
  ~Journal();
  Journal(const Journal&) = delete;
  Journal& operator=(const Journal&) = delete;

  // Only a strict (non-recovering) singleton acquisition plus the previous
  // owner's clean receipt and proven exit enables deletion in this run.
  Status BeginRun(const ProcessIdentity& owner, bool strict_singleton);
  // A one-way restriction, called before BeginRun. An empty/missing ledger on
  // an already-used root is not initial ownership proof. The bridge applies
  // this until native creation and singleton admission form one transaction.
  Status RequirePriorCleanBoundary();
  Status TrackChild(const ProcessIdentity& child);
  void FinishStartup();
  // Missing prior shutdown proof is sticky. An orderly later run cannot prove
  // absence of orphan helpers from an earlier crash. A pristine journal still
  // requires the embedder to prove that the root has no unjournaled writers.
  Status FinishCleanRun();
  Status RegisterProfile(const std::string& profile_id, Storage storage);
  Status Queue(const std::string& profile_id, Storage storage,
               const std::string& request_id, uint64_t expected_revision);
  bool IsRetired(const std::string& profile_id) const;
  Snapshot GetSnapshot() const;
  bool CanUseLedger() const;

  // Runs only before profile creation, on one native worker. False at a
  // checkpoint simulates interruption without inventing success. The same
  // owner may retry; after owner death a clean receipt is required again.
  Status Execute(const std::function<bool(Boundary)>& checkpoint = {});
  // Both operations require actual singleton ownership, no loaded profiles,
  // and an open startup boundary. Staging renames only durably consented exact
  // targets, then seals the boot UUID after both roots' quarantine publication.
  // It never unlinks target contents. Resumption removes only sealed private
  // quarantine inodes after an authoritative boot-session change; original-path
  // recreation remains untouched and denies success.
  Status StageForNextBoot(const std::function<bool(Boundary)>& checkpoint = {});
  Status ResumeQuarantinedAfterBoot(const std::function<bool(Boundary)>& checkpoint = {});

 private:
  struct Impl;
  explicit Journal(std::unique_ptr<Impl> implementation);
  std::unique_ptr<Impl> impl_;
};

}  // namespace arx::erasure
#endif
