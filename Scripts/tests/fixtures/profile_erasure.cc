#include "profile_erasure/journal.h"

#include <cassert>
#include <filesystem>
#include <fstream>
#include <fcntl.h>
#include <iostream>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <iterator>
#include <vector>

using namespace arx::erasure;
namespace fs = std::filesystem;
constexpr char kInstallation[] = "11111111-1111-1111-1111-111111111111";
constexpr char kLegacy[] = "22222222-2222-2222-2222-222222222222";
constexpr char kProfile[] = "33333333-3333-3333-3333-333333333333";
constexpr char kSurvivor[] = "44444444-4444-4444-4444-444444444444";
constexpr char kRequest[] = "55555555-5555-5555-5555-555555555555";
constexpr char kRequest2[] = "66666666-6666-6666-6666-666666666666";

struct Fixture {
  fs::path owned, root, cache;
  explicit Fixture(bool same_cache = false) {
    // Never accepts a path from argv or the environment. Every mutation below
    // stays beneath this native-created, owner-only, canonical temporary root.
    char pattern[] = "/private/tmp/arx-erasure-owned-XXXXXX";
    char* made = mkdtemp(pattern);
    assert(made);
    owned = made;
    root = owned / "Browser";
    cache = same_cache ? root : owned / "Cache";
    fs::create_directory(root);
    fs::create_directory(cache);
    chmod(root.c_str(), 0700); chmod(cache.c_str(), 0700);
    for (const auto& parent : {root, cache}) {
      for (const auto& name : {std::string("Default"), "Arx-" + std::string(kProfile), "Arx-" + std::string(kSurvivor)}) {
        fs::create_directories(parent / name / "Storage");
        std::ofstream(parent / name / "Storage" / "data") << name;
      }
    }
  }
  ~Fixture() { fs::remove_all(owned); }
  std::unique_ptr<Journal> Open(Status expected = Status::kOK,
                                BootSessionReader read_boot_session = CurrentBootSession) {
    Status status;
    auto journal = Journal::Open(root, cache, kInstallation, kLegacy, &status, std::move(read_boot_session));
    assert(status == expected);
    assert(bool(journal) == (status == Status::kOK));
    return journal;
  }
  void Seed(bool clean = true, bool legacy = false) {
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
      auto journal = Open();
      assert(journal->BeginRun(CurrentProcessIdentity(), true) == Status::kOK);
      assert(!journal->GetSnapshot().may_erase);
      assert(journal->RegisterProfile(kLegacy, Storage::kLegacyDefault) == Status::kOK);
      assert(journal->RegisterProfile(kProfile, Storage::kOrdinary) == Status::kOK);
      assert(journal->RegisterProfile(kSurvivor, Storage::kOrdinary) == Status::kOK);
      auto before = journal->GetSnapshot();
      assert(journal->Queue(legacy ? kLegacy : kProfile,
                            legacy ? Storage::kLegacyDefault : Storage::kOrdinary,
                            kRequest, before.revision) == Status::kOK);
      assert(journal->Execute() == Status::kPending);
      if (clean) assert(journal->FinishCleanRun() == Status::kOK);
      journal.reset();
      _exit(0);
    }
    int status;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  }
  std::unique_ptr<Journal> Restart(bool strict = true,
                                   BootSessionReader read_boot_session = CurrentBootSession) {
    auto journal = Open(Status::kOK, std::move(read_boot_session));
    assert(journal->BeginRun(CurrentProcessIdentity(), strict) == Status::kOK);
    return journal;
  }
  void VerifySurvivor(bool legacy_erased = false) {
    for (const auto& parent : {root, cache}) {
      assert(fs::is_regular_file(parent / ("Arx-" + std::string(kSurvivor)) / "Storage/data"));
      assert(fs::exists(parent / (legacy_erased ? "Arx-" + std::string(kProfile) : "Default")));
    }
  }
};

void Clean(bool same_cache, bool legacy) {
  Fixture fixture(same_cache);
  fixture.Seed(true, legacy);
  auto journal = fixture.Restart();
  assert(journal->GetSnapshot().may_erase);
  assert(journal->Execute() == Status::kVerified);
  for (const auto& parent : {fixture.root, fixture.cache}) {
    assert(!fs::exists(parent / (legacy ? "Default" : "Arx-" + std::string(kProfile))));
    assert(!fs::exists(parent / (".arx-erasing-" + std::string(kRequest))));
  }
  auto snapshot = journal->GetSnapshot();
  assert(snapshot.records[legacy ? 0 : 1].verified);
  assert(journal->RegisterProfile(legacy ? kLegacy : kProfile,
                                  legacy ? Storage::kLegacyDefault : Storage::kOrdinary) == Status::kRetired);
  fixture.VerifySurvivor(legacy);
  assert(journal->FinishCleanRun() == Status::kOK);
  journal.reset();
  auto next = fixture.Open();
  assert(next->IsRetired(legacy ? kLegacy : kProfile));
}
void Interruptions() {
  for (Boundary boundary : {Boundary::kRenamed, Boundary::kQuarantineRecorded,
                            Boundary::kRemoved, Boundary::kRemovalRecorded, Boundary::kVerified}) {
    Fixture fixture;
    fixture.Seed();
    auto journal = fixture.Restart();
    bool stopped = false;
    assert(journal->Execute([&](Boundary current) {
      if (!stopped && current == boundary) { stopped = true; return false; }
      return true;
    }) == Status::kPending);
    assert(stopped);
    assert(journal->Execute() == Status::kVerified);
    fixture.VerifySurvivor();
  }
}
void CrashPending() {
  Fixture fixture;
  fixture.Seed(false);
  auto journal = fixture.Restart();
  assert(!journal->GetSnapshot().may_erase);
  assert(journal->Execute() == Status::kPending);
  // A pending erasure does not prohibit surviving-profile startup.
  assert(journal->RegisterProfile(kSurvivor, Storage::kOrdinary) == Status::kOK);
  assert(journal->RegisterProfile(kProfile, Storage::kOrdinary) == Status::kRetired);
  fixture.VerifySurvivor();
  assert(fs::exists(fixture.root / ("Arx-" + std::string(kProfile))));
}
constexpr char kBoot0[] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
constexpr char kBoot1[] = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
constexpr char kBoot2[] = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";

void BootProgress() {
  Fixture fixture;
  fixture.Seed(false);
  std::string boot = kBoot0;
  auto journal = fixture.Restart(false, [&] { return boot; });
  auto progress = [&] { return journal->GetSnapshot().records[1].progress; };
  assert(progress() == Progress::kAwaitingStartup);
  assert(journal->StageForNextBoot([](Boundary value) { return value != Boundary::kRenamed; }) == Status::kPending);
  assert(progress() == Progress::kQuarantinePending);
  assert(journal->StageForNextBoot() == Status::kPending);
  assert(progress() == Progress::kRestartRequired);
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kPending);
  assert(progress() == Progress::kRestartRequired);
  boot = kBoot1;
  assert(progress() == Progress::kVerificationPending);
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kVerified);
  assert(progress() == Progress::kErased);
  assert(journal->StageForNextBoot() == Status::kPending);
  assert(progress() == Progress::kErased);
  fixture.VerifySurvivor();
}

struct OwnedWriter {
  pid_t child = -1;
  int command = -1, reply = -1;
  explicit OwnedWriter(const fs::path& path) {
    int commands[2], replies[2];
    assert(pipe(commands) == 0 && pipe(replies) == 0);
    child = fork();
    assert(child >= 0);
    if (child == 0) {
      close(commands[1]); close(replies[0]);
      int file = open(path.c_str(), O_WRONLY | O_APPEND);
      assert(file >= 0 && write(replies[1], "R", 1) == 1);
      char byte;
      while (read(commands[0], &byte, 1) == 1 && byte == 'W') {
        assert(write(file, "writer", 6) == 6 && fsync(file) == 0);
        assert(write(replies[1], "W", 1) == 1);
      }
      close(file); close(commands[0]); close(replies[1]);
      _exit(0);
    }
    close(commands[0]); close(replies[1]);
    command = commands[1]; reply = replies[0];
    char ready;
    assert(read(reply, &ready, 1) == 1 && ready == 'R');
  }
  void Write() {
    char done;
    assert(write(command, "W", 1) == 1);
    assert(read(reply, &done, 1) == 1 && done == 'W');
  }
  void Stop() {
    if (child < 0) return;
    close(command); close(reply);
    int result;
    assert(waitpid(child, &result, 0) == child && WIFEXITED(result) && WEXITSTATUS(result) == 0);
    child = -1;
  }
  ~OwnedWriter() { Stop(); }
};
fs::path Quarantined(const fs::path& parent) { return parent / (".arx-erasing-" + std::string(kRequest)); }
std::string RetiredName(bool legacy = false) { return legacy ? "Default" : "Arx-" + std::string(kProfile); }
void VerifyQuarantined(Fixture& fixture, bool legacy = false) {
  for (const auto& parent : {fixture.root, fixture.cache}) {
    assert(!fs::exists(parent / RetiredName(legacy)));
    assert(fs::is_regular_file(Quarantined(parent) / "Storage/data"));
  }
}
void BootQuarantine(bool same_cache, bool legacy, bool clean_prior = false) {
  Fixture fixture(same_cache);
  fixture.Seed(clean_prior, legacy);
  OwnedWriter writer(fixture.root / RetiredName(legacy) / "Storage/data");
  std::string boot = kBoot0;
  bool sealing = true;
  auto journal = fixture.Restart(true, [&] {
    if (sealing) VerifyQuarantined(fixture, legacy);
    return boot;
  });
  assert(journal->StageForNextBoot() == Status::kPending);
  sealing = false;
  VerifyQuarantined(fixture, legacy);
  writer.Write();
  assert(fs::file_size(Quarantined(fixture.root) / "Storage/data") >= 6);
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kPending);
  assert(journal->Execute() == Status::kPending);
  VerifyQuarantined(fixture, legacy);
  writer.Stop();
  journal.reset();
  boot = kBoot1;
  journal = fixture.Restart(false, [&] { return boot; });
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kVerified);
  for (const auto& parent : {fixture.root, fixture.cache}) {
    assert(!fs::exists(parent / RetiredName(legacy)) && !fs::exists(Quarantined(parent)));
  }
  assert(journal->GetSnapshot().records[legacy ? 0 : 1].verified);
  assert(journal->RegisterProfile(kSurvivor, Storage::kOrdinary) == Status::kOK);
  assert(journal->RegisterProfile(legacy ? kLegacy : kProfile,
                                  legacy ? Storage::kLegacyDefault : Storage::kOrdinary) == Status::kRetired);
  fixture.VerifySurvivor(legacy);
}
void BootPartialDoesNotBypass() {
  Fixture fixture;
  fixture.Seed(true);
  std::string boot = kBoot0;
  auto journal = fixture.Restart(true, [&] { return boot; });
  assert(journal->GetSnapshot().may_erase);
  assert(journal->StageForNextBoot([](Boundary event) {
    return event != Boundary::kRenamed;
  }) == Status::kPending);
  assert(journal->Execute() == Status::kPending);
  assert(fs::is_regular_file(Quarantined(fixture.root) / "Storage/data"));
  assert(fs::is_regular_file(fixture.cache / RetiredName() / "Storage/data"));
  journal.reset();
  boot = kBoot1;
  journal = fixture.Restart(false, [&] { return boot; });
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kPending);
  assert(journal->StageForNextBoot() == Status::kPending);
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kPending);
  boot = kBoot2;
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kVerified);
}
void BootStagingSaveFailure() {
  Fixture fixture;
  fixture.Seed(false);
  auto journal = fixture.Restart(false, [] { return std::string(kBoot0); });
  fs::create_directory(fixture.root / ".arx-profile-erasure-writing");
  assert(journal->StageForNextBoot() == Status::kOwnershipChanged);
  assert(!journal->GetSnapshot().durable);
  for (const auto& parent : {fixture.root, fixture.cache}) {
    assert(fs::is_regular_file(parent / RetiredName() / "Storage/data"));
    assert(!fs::exists(Quarantined(parent)));
  }
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kPending);
}
void BootStageInterruptions() {
  for (const auto& [boundary, ordinal] : {
      std::pair{Boundary::kRenamed, 1}, {Boundary::kRenamed, 2},
      {Boundary::kQuarantineRecorded, 1}, {Boundary::kQuarantineRecorded, 2},
      {Boundary::kQuarantineSealed, 1}}) {
    Fixture fixture;
    fixture.Seed(false);
    std::string boot = kBoot0;
    size_t reads = 0;
    auto journal = fixture.Restart(false, [&] { ++reads; return boot; });
    int seen = 0;
    assert(journal->StageForNextBoot([&](Boundary event) {
      return event != boundary || ++seen != ordinal;
    }) == Status::kPending);
    const bool sealed = boundary == Boundary::kQuarantineSealed;
    assert(reads == (sealed ? 1 : 0));
    journal.reset();
    boot = kBoot1;
    journal = fixture.Restart(false, [&] { return boot; });
    if (sealed) {
      assert(journal->ResumeQuarantinedAfterBoot() == Status::kVerified);
    } else {
      assert(journal->ResumeQuarantinedAfterBoot() == Status::kPending);
      // The missing seal is never backdated to the boot in which an earlier
      // rename might have happened. Finish staging now and wait another boot.
      assert(journal->StageForNextBoot() == Status::kPending);
      VerifyQuarantined(fixture);
      assert(journal->ResumeQuarantinedAfterBoot() == Status::kPending);
      boot = kBoot2;
      assert(journal->ResumeQuarantinedAfterBoot() == Status::kVerified);
    }
    fixture.VerifySurvivor();
  }
}
void BootResumeInterruptions() {
  for (const auto& [boundary, ordinal] : {
      std::pair{Boundary::kRemoved, 1}, {Boundary::kRemoved, 2},
      {Boundary::kRemovalRecorded, 1}, {Boundary::kRemovalRecorded, 2},
      {Boundary::kVerified, 1}}) {
    Fixture fixture;
    fixture.Seed(false);
    std::string boot = kBoot0;
    auto journal = fixture.Restart(false, [&] { return boot; });
    assert(journal->StageForNextBoot() == Status::kPending);
    boot = kBoot1;
    int seen = 0;
    assert(journal->ResumeQuarantinedAfterBoot([&](Boundary event) {
      return event != boundary || ++seen != ordinal;
    }) == Status::kPending);
    journal.reset();
    journal = fixture.Restart(false, [&] { return boot; });
    assert(journal->ResumeQuarantinedAfterBoot() == Status::kVerified);
    assert(journal->GetSnapshot().records[1].verified);
    fixture.VerifySurvivor();
  }
}
void BootRecreation(bool cache) {
  Fixture fixture;
  fixture.Seed(false);
  std::string boot = kBoot0;
  auto journal = fixture.Restart(false, [&] { return boot; });
  assert(journal->StageForNextBoot() == Status::kPending);
  auto recreated = (cache ? fixture.cache : fixture.root) / RetiredName();
  fs::create_directory(recreated);
  std::ofstream(recreated / "keep") << "new original identity";
  boot = kBoot1;
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kOwnershipChanged);
  assert(fs::is_regular_file(recreated / "keep"));
  assert(fs::is_regular_file(Quarantined(fixture.root) / "Storage/data"));
  assert(fs::is_regular_file(Quarantined(fixture.cache) / "Storage/data"));
  assert(!journal->GetSnapshot().records[1].verified);
}
void BootLateRecreation() {
  Fixture fixture;
  fixture.Seed(false);
  std::string boot = kBoot0;
  auto journal = fixture.Restart(false, [&] { return boot; });
  assert(journal->StageForNextBoot() == Status::kPending);
  boot = kBoot1;
  bool recreated = false;
  assert(journal->ResumeQuarantinedAfterBoot([&](Boundary event) {
    if (!recreated && event == Boundary::kRemovalRecorded) {
      recreated = true;
      fs::create_directory(fixture.cache / RetiredName());
      std::ofstream(fixture.cache / RetiredName() / "keep") << "later original";
    }
    return true;
  }) == Status::kOwnershipChanged);
  assert(recreated && fs::is_regular_file(fixture.cache / RetiredName() / "keep"));
  assert(fs::is_regular_file(Quarantined(fixture.cache) / "Storage/data"));
  assert(!journal->GetSnapshot().records[1].verified);
}
void BootQuarantineReplacement(bool cache) {
  Fixture fixture;
  fixture.Seed(false);
  std::string boot = kBoot0;
  auto journal = fixture.Restart(false, [&] { return boot; });
  assert(journal->StageForNextBoot() == Status::kPending);
  auto replaced = Quarantined(cache ? fixture.cache : fixture.root);
  fs::rename(replaced, fixture.owned / "PreservedQuarantine");
  fs::create_directory(replaced);
  std::ofstream(replaced / "keep") << "replacement quarantine";
  boot = kBoot1;
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kOwnershipChanged);
  assert(fs::is_regular_file(replaced / "keep"));
  assert(fs::is_regular_file(fixture.owned / "PreservedQuarantine/Storage/data"));
  assert(!journal->GetSnapshot().records[1].verified);
}
void BootUnavailable() {
  Fixture fixture;
  fixture.Seed(false);
  std::string boot;
  auto journal = fixture.Restart(false, [&] { return boot; });
  assert(journal->StageForNextBoot() == Status::kPending);
  VerifyQuarantined(fixture);
  journal.reset();
  boot = kBoot1;
  journal = fixture.Restart(false, [&] { return boot; });
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kPending);
  assert(journal->StageForNextBoot() == Status::kPending);
  for (const auto& invalid : {std::string{}, std::string("malformed"),
                             std::string("00000000-0000-0000-0000-000000000000"),
                             std::string("CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"), std::string(kBoot1)}) {
    boot = invalid;
    assert(journal->ResumeQuarantinedAfterBoot() == Status::kPending);
    VerifyQuarantined(fixture);
  }
  boot = kBoot2;
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kVerified);
}
void BootStartupSealed() {
  Fixture fixture;
  fixture.Seed(false);
  std::string boot = kBoot0;
  auto journal = fixture.Restart(false, [&] { return boot; });
  assert(journal->StageForNextBoot() == Status::kPending);
  assert(journal->RegisterProfile(kSurvivor, Storage::kOrdinary) == Status::kOK);
  boot = kBoot1;
  assert(journal->StageForNextBoot() == Status::kPending);
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kPending);
  VerifyQuarantined(fixture);
}
void BootSealFailure() {
  Fixture fixture;
  fixture.Seed(false);
  auto journal = fixture.Restart(false, [&] {
    VerifyQuarantined(fixture);
    fs::create_directory(fixture.root / ".arx-profile-erasure-writing");
    return std::string(kBoot0);
  });
  assert(journal->StageForNextBoot() == Status::kOwnershipChanged);
  assert(!journal->GetSnapshot().durable && !journal->GetSnapshot().records[1].verified);
  assert(journal->ResumeQuarantinedAfterBoot() == Status::kPending);
  VerifyQuarantined(fixture);
}
void OldSchemaRejected() {
  Fixture fixture;
  fixture.Seed(false);
  auto path = fixture.root / ".arx-profile-erasure-v1";
  std::fstream bytes(path, std::ios::in | std::ios::out | std::ios::binary);
  bytes.seekp(16); bytes.put(1); bytes.close();
  assert(!fixture.Open(Status::kOwnershipChanged));
  fixture.VerifySurvivor();
  assert(fs::exists(fixture.root / RetiredName()));
}
// Rewrites the current (volume UUID) ledger as version 2, which persisted
// st_dev. Each device is replaced with a value no live volume has, as happens
// when macOS renumbers volumes after a reboot or OS update.
struct LedgerBytes {
  std::vector<uint8_t> in, out;
  size_t at = 0;
  uint64_t Integer() {
    uint64_t value = 0;
    for (int i = 0; i < 8; ++i) value |= uint64_t(in.at(at + i)) << (i * 8);
    Copy(8);
    return value;
  }
  void Copy(size_t count) { out.insert(out.end(), in.begin() + at, in.begin() + at + count); at += count; }
  void Put(uint64_t value) { for (int i = 0; i < 8; ++i) out.push_back(uint8_t(value >> (i * 8))); }
  void String() { Copy(Integer()); }
  void Identity() {
    at += 16;  // Volume UUID.
    uint64_t inode = 0;
    for (int i = 0; i < 8; ++i) inode |= uint64_t(in.at(at + i)) << (i * 8);
    Put(inode ? 0x7fff0000ULL : 0);
    Copy(8);
  }
};
std::vector<uint8_t> ReadLedger(const fs::path& path) {
  std::ifstream file(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(file), {}};
}
void WriteLedger(const fs::path& path, const std::vector<uint8_t>& bytes) {
  std::ofstream file(path, std::ios::binary | std::ios::trunc);
  file.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
}
void DowngradeToDeviceLedger(const fs::path& path) {
  LedgerBytes ledger;
  ledger.in = ReadLedger(path);
  ledger.String();
  assert(ledger.Integer() == 3);
  ledger.out.resize(ledger.out.size() - 8);
  ledger.Put(2);
  ledger.String(); ledger.String();
  ledger.Identity(); ledger.Identity();
  ledger.Integer();                                   // Revision.
  ledger.Copy(24);                                    // Owner.
  ledger.Integer();                                   // Clean.
  for (auto count = ledger.Integer(); count; --count) ledger.Copy(24);
  for (auto count = ledger.Integer(); count; --count) {
    ledger.String(); ledger.Integer(); ledger.String(); ledger.Integer(); ledger.Integer();
    for (int target = 0; target < 2; ++target) { ledger.Identity(); ledger.Integer(); }
    ledger.Integer(); ledger.String();
  }
  assert(ledger.at + 8 == ledger.in.size());
  uint64_t hash = 14695981039346656037ULL;
  for (auto byte : ledger.out) { hash ^= byte; hash *= 1099511628211ULL; }
  ledger.Put(hash);
  WriteLedger(path, ledger.out);
}
uint64_t LedgerVersion(const fs::path& path) {
  auto bytes = ReadLedger(path);
  uint64_t version = 0;
  for (int i = 0; i < 8; ++i) version |= uint64_t(bytes.at(16 + i)) << (i * 8);
  return version;
}
void DeviceRenumbering(bool same_cache) {
  Fixture fixture(same_cache);
  fixture.Seed();
  auto path = fixture.root / ".arx-profile-erasure-v1";
  DowngradeToDeviceLedger(path);
  assert(LedgerVersion(path) == 2);
  auto journal = fixture.Restart();
  assert(LedgerVersion(path) == 3);
  assert(journal->GetSnapshot().may_erase);
  assert(journal->IsRetired(kProfile));
  assert(journal->Execute() == Status::kVerified);
  assert(!fs::exists(fixture.root / RetiredName()));
  fixture.VerifySurvivor();
}
void DeviceLedgerReplacedTarget() {
  // Migration binds by inode: a replaced target still blocks erasure.
  Fixture fixture;
  fixture.Seed();
  DowngradeToDeviceLedger(fixture.root / ".arx-profile-erasure-v1");
  auto target = fixture.root / RetiredName();
  fs::rename(target, fixture.owned / "Original");
  fs::create_directory(target);
  std::ofstream(target / "replacement") << "keep";
  auto journal = fixture.Restart();
  assert(journal->Execute() == Status::kOwnershipChanged);
  assert(fs::exists(target / "replacement"));
  fixture.VerifySurvivor();
}
void ForeignVolume() {
  Fixture fixture;
  fixture.Seed(false);
  auto path = fixture.root / ".arx-profile-erasure-v1";
  auto bytes = ReadLedger(path);
  // Root identity volume starts after magic, version, installation and legacy.
  const size_t volume = 16 + 8 + (8 + 36) * 2;
  bytes.at(volume) ^= 0xff;
  WriteLedger(path, bytes);
  assert(!fixture.Open(Status::kOwnershipChanged));
  assert(fs::exists(fixture.root / RetiredName()));
  fixture.VerifySurvivor();
}
void KernelBootReader() {
  const auto first = CurrentBootSession(), second = CurrentBootSession();
  if (!first.empty() && !second.empty()) {
    assert(first == second && first.size() == 36);
    for (size_t index = 0; index < first.size(); ++index) {
      if (index == 8 || index == 13 || index == 18 || index == 23) assert(first[index] == '-');
      else assert((first[index] >= '0' && first[index] <= '9') || (first[index] >= 'a' && first[index] <= 'f'));
    }
    std::cout << "ARX_KERNEL_BOOT_SESSION_AVAILABLE canonical stable\n";
  } else {
    std::cout << "ARX_KERNEL_BOOT_SESSION_UNAVAILABLE fail-closed\n";
  }
}
std::pair<fs::path, fs::path> CreationParents(Fixture& fixture) {
  auto data = fixture.owned / "CreationData", cache = fixture.owned / "CreationCache";
  fs::create_directory(data); fs::create_directory(cache);
  chmod(data.c_str(), 0700); chmod(cache.c_str(), 0700);
  return {data, cache};
}
void CreatedRootPolicy() {
  Fixture fixture;
  auto [data, cache] = CreationParents(fixture);
  Status status;
  auto created = CreatedRoots::Create(data, cache, &status);
  assert(status == Status::kOK && created && created->Validate() == Status::kOK);
  assert(fs::path(created->root()).parent_path() == data);
  assert(fs::path(created->cache()).parent_path() == cache);
  assert(fs::path(created->root()).filename() == fs::path(created->cache()).filename());
  assert(fs::is_empty(created->root()) && fs::is_empty(created->cache()));
  for (const auto& path : {created->root(), created->cache()}) {
    struct stat info;
    assert(lstat(path.c_str(), &info) == 0 && S_ISDIR(info.st_mode));
    assert((info.st_mode & 0777) == 0700 && info.st_uid == geteuid());
  }
  // Directory creation is not a writer-admission proof. A generic configured
  // startup must still deny a clean bootstrap, even for this new pair.
  auto journal = Journal::Open(created->root(), created->cache(), kInstallation, kLegacy, &status);
  assert(status == Status::kOK && journal);
  assert(journal->RequirePriorCleanBoundary() == Status::kOK);
  assert(journal->BeginRun(CurrentProcessIdentity(), true) == Status::kOK);
  assert(journal->RegisterProfile(kSurvivor, Storage::kOrdinary) == Status::kOK);
  assert(journal->FinishCleanRun() == Status::kPending);
  assert(created->Validate() == Status::kOK);
  const auto root_path = created->root(), cache_path = created->cache();
  created.reset();
  assert(fs::is_directory(root_path) && fs::is_directory(cache_path));
  fixture.VerifySurvivor();
}
void CreatedSameParent() {
  Fixture fixture;
  auto [data, cache] = CreationParents(fixture);
  Status status;
  auto first = CreatedRoots::Create(data, data, &status);
  assert(status == Status::kOK && first && first->root() == first->cache());
  auto second = CreatedRoots::Create(data, data, &status);
  assert(status == Status::kOK && second && first->root() != second->root());
  assert(first->Validate() == Status::kOK && second->Validate() == Status::kOK);
  assert(!CreatedRoots::Create(data, cache, nullptr));
}
void CreatedReplacement(bool replace_cache, bool replace_parent) {
  Fixture fixture;
  auto [data, cache] = CreationParents(fixture);
  Status status;
  auto created = CreatedRoots::Create(data, cache, &status);
  assert(status == Status::kOK && created);
  fs::path path = replace_cache ? created->cache() : created->root();
  if (replace_parent) path = replace_cache ? cache : data;
  fs::rename(path, fixture.owned / "PreservedCreation");
  fs::create_directory(path); chmod(path.c_str(), 0700);
  assert(created->Validate() == Status::kOwnershipChanged);
  assert(fs::is_directory(fixture.owned / "PreservedCreation"));
  assert(fs::is_directory(path));
}
void CreatedParentPolicy() {
  Fixture fixture;
  auto [data, cache] = CreationParents(fixture);
  Status status;
  fs::create_directory_symlink(data, fixture.owned / "CreationAlias");
  assert(!CreatedRoots::Create(fixture.owned / "CreationAlias", cache, &status));
  assert(status == Status::kOwnershipChanged && fs::is_empty(data) && fs::is_empty(cache));
  assert(!CreatedRoots::Create(data, cache / "Missing", &status));
  assert(fs::is_empty(data) && fs::is_empty(cache));
  assert(!CreatedRoots::Create(data.string() + "/../CreationData", cache, &status));
  assert(!CreatedRoots::Create(data.string() + "/", cache, &status));
  chmod(cache.c_str(), 0777);
  assert(!CreatedRoots::Create(data, cache, &status));
  assert(status == Status::kOwnershipChanged && fs::is_empty(data));
  chmod(cache.c_str(), 0700);
  auto created = CreatedRoots::Create(data, cache, &status);
  assert(created && status == Status::kOK);
  chmod(created->cache().c_str(), 0755);
  assert(created->Validate() == Status::kOwnershipChanged);
  chmod(created->cache().c_str(), 0777);
  assert(created->Validate() == Status::kOwnershipChanged);
  chmod(created->cache().c_str(), 0700);
}
void CreatedFailurePreservesPaths() {
  Fixture fixture;
  auto [data, cache] = CreationParents(fixture);
  std::ofstream(cache / "keep") << "existing cache parent data";
  chmod(cache.c_str(), 0500);
  Status status;
  auto created = CreatedRoots::Create(data, cache, &status);
  assert(!created && status == Status::kIO);
  chmod(cache.c_str(), 0700);
  assert(fs::is_regular_file(cache / "keep"));
  size_t count = 0;
  for (const auto& child : fs::directory_iterator(data)) {
    ++count;
    assert(child.is_directory() && fs::is_empty(child.path()));
  }
  assert(count == 1);
  fixture.VerifySurvivor();
}
void CreatedProcessAndMove() {
  Fixture fixture;
  auto [data, cache] = CreationParents(fixture);
  Status status;
  auto created = CreatedRoots::Create(data, cache, &status);
  assert(created && status == Status::kOK);
  pid_t child = fork();
  assert(child >= 0);
  if (child == 0) {
    assert(created->Validate() == Status::kOwnershipChanged);
    _exit(0);
  }
  int result;
  assert(waitpid(child, &result, 0) == child && WIFEXITED(result) && WEXITSTATUS(result) == 0);
  assert(created->Validate() == Status::kOK);
  const auto original = created->root();
  CreatedRoots moved(std::move(*created));
  assert(moved.Validate() == Status::kOK && created->Validate() == Status::kOwnershipChanged);
  auto second = CreatedRoots::Create(data, cache, &status);
  assert(second && status == Status::kOK);
  const auto second_root = second->root();
  *second = std::move(moved);
  assert(second->root() == original && second->Validate() == Status::kOK);
  assert(moved.Validate() == Status::kOwnershipChanged && fs::is_directory(second_root));
}
void UnprovenInitialBoundary() {
  Fixture fixture;
  pid_t child = fork();
  assert(child >= 0);
  if (child == 0) {
    auto journal = fixture.Open();
    assert(journal->RequirePriorCleanBoundary() == Status::kOK);
    assert(journal->BeginRun(CurrentProcessIdentity(), true) == Status::kOK);
    assert(journal->RequirePriorCleanBoundary() == Status::kInvalid);
    assert(journal->CanUseLedger());
    assert(journal->RegisterProfile(kSurvivor, Storage::kOrdinary) == Status::kOK);
    assert(journal->FinishCleanRun() == Status::kPending);
    journal.reset();
    _exit(0);
  }
  int result;
  assert(waitpid(child, &result, 0) == child && WIFEXITED(result) && WEXITSTATUS(result) == 0);
  auto journal = fixture.Restart();
  assert(!journal->GetSnapshot().may_erase && journal->Execute() == Status::kPending);
  assert(journal->RegisterProfile(kSurvivor, Storage::kOrdinary) == Status::kOK);
  assert(journal->FinishCleanRun() == Status::kPending);
  fixture.VerifySurvivor();
}
void OrdinaryRecovery() {
  Fixture fixture;
  fixture.Seed();
  auto journal = fixture.Restart(false);
  assert(journal->CanUseLedger());
  assert(!journal->GetSnapshot().may_erase);
  assert(journal->Execute() == Status::kPending);
  assert(journal->RegisterProfile(kSurvivor, Storage::kOrdinary) == Status::kOK);
  assert(journal->RegisterProfile(kProfile, Storage::kOrdinary) == Status::kRetired);
  for (const auto& parent : {fixture.root, fixture.cache})
    assert(fs::is_regular_file(parent / ("Arx-" + std::string(kProfile)) / "Storage/data"));
  fixture.VerifySurvivor();
  assert(journal->FinishCleanRun() == Status::kOK);
}
void UnrecordedHelper() {
  Fixture fixture;
  int control[2];
  assert(pipe(control) == 0);
  pid_t helper = fork();
  assert(helper >= 0);
  if (helper == 0) {
    close(control[1]);
    char byte;
    // Native-created fixture child remains alive until its owned pipe closes.
    assert(read(control[0], &byte, 1) == 0);
    close(control[0]);
    _exit(0);
  }
  close(control[0]);
  fixture.Seed(false);
  pid_t orderly_owner = fork();
  assert(orderly_owner >= 0);
  if (orderly_owner == 0) {
    auto journal = fixture.Restart(false);
    assert(journal->CanUseLedger());
    assert(journal->RegisterProfile(kSurvivor, Storage::kOrdinary) == Status::kOK);
    assert(journal->FinishCleanRun() == Status::kPending);
    journal.reset();
    _exit(0);
  }
  int result;
  assert(waitpid(orderly_owner, &result, 0) == orderly_owner &&
         WIFEXITED(result) && WEXITSTATUS(result) == 0);
  // The orderly successor must not manufacture authority while an unrecorded
  // helper from the dirty boundary could still be writing profile storage.
  assert(waitpid(helper, &result, WNOHANG) == 0);
  auto journal = fixture.Restart();
  assert(!journal->GetSnapshot().may_erase);
  assert(journal->Execute() == Status::kPending);
  assert(journal->FinishCleanRun() == Status::kPending);
  fixture.VerifySurvivor();
  assert(fs::exists(fixture.root / ("Arx-" + std::string(kProfile))));
  close(control[1]);
  assert(waitpid(helper, &result, 0) == helper && WIFEXITED(result) && WEXITSTATUS(result) == 0);
  // Even this test's knowledge of that helper's exit does not constitute a
  // persisted production recovery proof for all previously unknown writers.
  assert(journal->FinishCleanRun() == Status::kPending);
}
void ForeignAuthority() {
  Fixture fixture;
  fixture.Seed();
  auto journal = fixture.Open();
  auto foreign = CurrentProcessIdentity();
  foreign.seconds++;
  assert(journal->BeginRun(foreign, true) == Status::kInvalid);
  assert(journal->BeginRun(CurrentProcessIdentity(), false) == Status::kOK);
  assert(journal->Execute() == Status::kPending);
  fixture.VerifySurvivor();
  auto second = fixture.Open(Status::kBusy);
}
void RootReplacement() {
  Fixture fixture;
  fixture.Seed();
  auto journal = fixture.Restart();
  fs::rename(fixture.root, fixture.owned / "Original");
  fs::create_directory(fixture.root);
  assert(journal->Execute() == Status::kOwnershipChanged);
  assert(fs::exists(fixture.owned / "Original" / ("Arx-" + std::string(kProfile))));
}
void TargetReplacement() {
  Fixture fixture;
  fixture.Seed();
  auto journal = fixture.Restart();
  auto target = fixture.root / ("Arx-" + std::string(kProfile));
  fs::rename(target, fixture.owned / "Original");
  fs::create_directory(target);
  std::ofstream(target / "replacement") << "keep";
  assert(journal->Execute() == Status::kOwnershipChanged);
  assert(fs::exists(target / "replacement"));
  fixture.VerifySurvivor();
}
void Symlinks() {
  Fixture fixture;
  fixture.Seed();
  auto journal = fixture.Restart();
  auto target = fixture.root / ("Arx-" + std::string(kProfile));
  fs::create_directory(fixture.owned / "Outside");
  std::ofstream(fixture.owned / "Outside/keep") << "keep";
  fs::create_directory_symlink(fixture.owned / "Outside", target / "linked");
  assert(journal->Execute() == Status::kOwnershipChanged);
  assert(fs::exists(fixture.owned / "Outside/keep"));
  assert(!journal->GetSnapshot().records[1].verified);
  journal.reset();
  fs::create_directory_symlink(fixture.root, fixture.owned / "Alias");
  Status status;
  assert(!Journal::Open((fixture.owned / "Alias").string(), fixture.cache,
                        kInstallation, kLegacy, &status));
  assert(status == Status::kOwnershipChanged);
}
void LedgerAndMapping() {
  Fixture fixture;
  fixture.Seed();
  Status status;
  assert(!Journal::Open(fixture.root, fixture.cache, kInstallation, kProfile, &status));
  assert(status == Status::kOwnershipChanged);
  auto journal = fixture.Restart();
  auto revision = journal->GetSnapshot().revision;
  journal->FinishStartup();
  assert(journal->Queue(kSurvivor, Storage::kLegacyDefault, kRequest2, revision) == Status::kInvalid);
  assert(journal->Queue(kSurvivor, Storage::kOrdinary, kRequest2, revision - 1) == Status::kStale);
  assert(journal->Queue(kSurvivor, Storage::kOrdinary, kRequest, revision) == Status::kInvalid);
  assert(journal->RegisterProfile(kProfile, Storage::kOrdinary) == Status::kRetired);
  assert(journal->Execute() == Status::kPending);
  journal.reset();
  std::fstream bytes(fixture.root / ".arx-profile-erasure-v1", std::ios::in | std::ios::out | std::ios::binary);
  bytes.seekp(30); bytes.put('!'); bytes.close();
  assert(!Journal::Open(fixture.root, fixture.cache, kInstallation, kLegacy, &status));
  assert(status == Status::kOwnershipChanged || status == Status::kCorrupt);
}
void LateRecreation() {
  Fixture fixture;
  fixture.Seed();
  auto journal = fixture.Restart();
  bool injected = false;
  assert(journal->Execute([&](Boundary boundary) {
    if (!injected && boundary == Boundary::kRemovalRecorded) {
      injected = true;
      fs::create_directory(fixture.root / ("Arx-" + std::string(kProfile)));
    }
    return true;
  }) == Status::kOwnershipChanged);
  assert(!journal->GetSnapshot().records[1].verified);
  fixture.VerifySurvivor();
}
void InterruptedRestart() {
  Fixture fixture;
  fixture.Seed();
  pid_t worker = fork();
  assert(worker >= 0);
  if (worker == 0) {
    auto journal = fixture.Restart();
    assert(journal->Execute([](Boundary boundary) {
      return boundary != Boundary::kRenamed;
    }) == Status::kPending);
    // Exit without a clean receipt, like an interrupted owner process.
    _exit(0);
  }
  int result;
  assert(waitpid(worker, &result, 0) == worker && WIFEXITED(result) && WEXITSTATUS(result) == 0);
  worker = fork();
  assert(worker >= 0);
  if (worker == 0) {
    auto journal = fixture.Restart();
    assert(journal->Execute() == Status::kPending);
    assert(journal->RegisterProfile(kSurvivor, Storage::kOrdinary) == Status::kOK);
    // This owner cannot account for a helper orphaned by its predecessor.
    assert(journal->FinishCleanRun() == Status::kPending);
    journal.reset();
    _exit(0);
  }
  assert(waitpid(worker, &result, 0) == worker && WIFEXITED(result) && WEXITSTATUS(result) == 0);
  auto journal = fixture.Restart();
  assert(!journal->GetSnapshot().may_erase);
  assert(journal->Execute() == Status::kPending);
  assert(journal->FinishCleanRun() == Status::kPending);
  assert(fs::is_directory(fixture.root / (".arx-erasing-" + std::string(kRequest))));
  fixture.VerifySurvivor();
}
void CacheAndHardLink() {
  Fixture fixture;
  fixture.Seed();
  fs::create_directory(fixture.owned / "OtherCache");
  Status status;
  assert(!Journal::Open(fixture.root, fixture.owned / "OtherCache", kInstallation, kLegacy, &status));
  assert(status == Status::kOwnershipChanged);
  auto journal = fixture.Restart();
  std::ofstream(fixture.owned / "shared") << "keep";
  fs::create_hard_link(fixture.owned / "shared", fixture.root / ("Arx-" + std::string(kProfile)) / "linked");
  assert(journal->Execute() == Status::kOwnershipChanged);
  assert(fs::exists(fixture.owned / "shared"));
  fixture.VerifySurvivor();
}
void Bounds() {
  Fixture fixture;
  auto journal = fixture.Restart();
  for (size_t i = 0; i < Journal::kMaximumProfiles; ++i) {
    char id[37];
    snprintf(id, sizeof(id), "00000000-0000-0000-0000-%012zx", i);
    assert(journal->RegisterProfile(id, Storage::kOrdinary) == Status::kOK);
  }
  assert(journal->RegisterProfile(kProfile, Storage::kOrdinary) == Status::kLimit);
  assert(journal->FinishCleanRun() == Status::kOK);
  assert(journal->Queue(kProfile, Storage::kOrdinary, kRequest, journal->GetSnapshot().revision) == Status::kInvalid);
}
void VerifiedFailure() {
  Fixture fixture;
  fixture.Seed();
  auto journal = fixture.Restart();
  assert(journal->Execute() == Status::kVerified);
  assert(journal->GetSnapshot().records[1].verified);
  fs::create_directory(fixture.root / ("Arx-" + std::string(kProfile)));
  assert(journal->Execute() == Status::kOwnershipChanged);
  assert(!journal->GetSnapshot().records[1].verified);
}
void VerifiedRootReplacement() {
  Fixture fixture;
  fixture.Seed();
  auto journal = fixture.Restart();
  assert(journal->Execute() == Status::kVerified);
  fs::rename(fixture.root, fixture.owned / "Original");
  fs::create_directory(fixture.root);
  assert(journal->Execute() == Status::kOwnershipChanged);
  assert(!journal->GetSnapshot().records[1].verified);
  assert(!journal->GetSnapshot().durable);
}
void FailedReceiptPublication() {
  Fixture fixture;
  fixture.Seed();
  auto journal = fixture.Restart();
  bool substituted = false;
  Status result = journal->Execute([&](Boundary boundary) {
    // The final removal is durable, but replace the lock before the verified
    // receipt can publish. A caller must see failure and verified=false.
    if (boundary == Boundary::kRemovalRecorded &&
        !fs::exists(fixture.cache / ("Arx-" + std::string(kProfile)))) {
      fs::rename(fixture.root / ".arx-profile-erasure-lock", fixture.root / "old-lock");
      std::ofstream(fixture.root / ".arx-profile-erasure-lock") << "substituted";
      substituted = true;
    }
    return true;
  });
  assert(substituted && result == Status::kOwnershipChanged);
  assert(!journal->GetSnapshot().records[1].verified);
  assert(!journal->GetSnapshot().durable);
  fixture.VerifySurvivor();
}
void RootAncestry() {
  Fixture fixture;
  auto nested = fixture.root / "Nested";
  fs::create_directory(nested);
  Status status;
  assert(!Journal::Open(fixture.root, nested, kInstallation, kLegacy, &status));
  assert(status == Status::kOwnershipChanged);
  auto alias = fixture.owned / "bROWSER" / "Nested";
  // APFS may be case-sensitive. When this alias resolves, inode ancestry must
  // still reject it; lowercasing paths would be wrong on case-sensitive disks.
  if (fs::exists(alias)) {
    assert(!Journal::Open(fixture.root, alias, kInstallation, kLegacy, &status));
    assert(status == Status::kOwnershipChanged);
  }
  auto created = fixture.owned / "New/Cache";
  assert(PrepareOwnedDirectory(created) == Status::kOK);
  fs::create_directory_symlink(fixture.root, fixture.owned / "Link");
  assert(PrepareOwnedDirectory(fixture.owned / "Link/Outside") == Status::kOwnershipChanged);
  assert(!fs::exists(fixture.root / "Outside"));
}
void Children() {
  Fixture fixture;
  fixture.Seed();
  auto journal = fixture.Restart();
  assert(journal->TrackChild(CurrentProcessIdentity()) == Status::kOK);
  assert(journal->FinishCleanRun() == Status::kPending);
  fixture.VerifySurvivor();
}
int main(int argc, char** argv) {
  assert(argc == 2);
  std::string scenario = argv[1];
  if (scenario == "clean") Clean(false, false);
  else if (scenario == "same-cache") Clean(true, false);
  else if (scenario == "legacy") Clean(false, true);
  else if (scenario == "interruptions") Interruptions();
  else if (scenario == "crash-pending") CrashPending();
  else if (scenario == "authority") ForeignAuthority();
  else if (scenario == "ordinary-recovery") OrdinaryRecovery();
  else if (scenario == "created-root") CreatedRootPolicy();
  else if (scenario == "created-same-parent") CreatedSameParent();
  else if (scenario == "created-data-replacement") CreatedReplacement(false, false);
  else if (scenario == "created-cache-replacement") CreatedReplacement(true, false);
  else if (scenario == "created-parent-replacement") CreatedReplacement(false, true);
  else if (scenario == "created-cache-parent-replacement") CreatedReplacement(true, true);
  else if (scenario == "created-parent-policy") CreatedParentPolicy();
  else if (scenario == "created-failure") CreatedFailurePreservesPaths();
  else if (scenario == "created-process-move") CreatedProcessAndMove();
  else if (scenario == "unproven-initial-boundary") UnprovenInitialBoundary();
  else if (scenario == "boot-quarantine") BootQuarantine(false, false);
  else if (scenario == "boot-same-cache") BootQuarantine(true, false);
  else if (scenario == "boot-legacy") BootQuarantine(false, true);
  else if (scenario == "boot-no-full-bypass") BootQuarantine(false, false, true);
  else if (scenario == "boot-partial-no-bypass") BootPartialDoesNotBypass();
  else if (scenario == "boot-staging-save-failure") BootStagingSaveFailure();
  else if (scenario == "boot-stage-interruptions") BootStageInterruptions();
  else if (scenario == "boot-resume-interruptions") BootResumeInterruptions();
  else if (scenario == "boot-data-recreated") BootRecreation(false);
  else if (scenario == "boot-cache-recreated") BootRecreation(true);
  else if (scenario == "boot-late-recreation") BootLateRecreation();
  else if (scenario == "boot-qdata-replaced") BootQuarantineReplacement(false);
  else if (scenario == "boot-qcache-replaced") BootQuarantineReplacement(true);
  else if (scenario == "boot-unavailable") BootUnavailable();
  else if (scenario == "boot-startup-sealed") BootStartupSealed();
  else if (scenario == "boot-seal-failure") BootSealFailure();
  else if (scenario == "boot-old-schema") OldSchemaRejected();
  else if (scenario == "device-renumbering") DeviceRenumbering(false);
  else if (scenario == "device-renumbering-same-cache") DeviceRenumbering(true);
  else if (scenario == "device-ledger-replaced-target") DeviceLedgerReplacedTarget();
  else if (scenario == "foreign-volume") ForeignVolume();
  else if (scenario == "boot-kernel") KernelBootReader();
  else if (scenario == "boot-progress") BootProgress();
  else if (scenario == "unrecorded-helper") UnrecordedHelper();
  else if (scenario == "root-replacement") RootReplacement();
  else if (scenario == "target-replacement") TargetReplacement();
  else if (scenario == "symlinks") Symlinks();
  else if (scenario == "ledger") LedgerAndMapping();
  else if (scenario == "late-recreation") LateRecreation();
  else if (scenario == "children") Children();
  else if (scenario == "interrupted-restart") InterruptedRestart();
  else if (scenario == "cache-hardlink") CacheAndHardLink();
  else if (scenario == "bounds") Bounds();
  else if (scenario == "verified-failure") VerifiedFailure();
  else if (scenario == "verified-root") VerifiedRootReplacement();
  else if (scenario == "failed-receipt") FailedReceiptPublication();
  else if (scenario == "root-ancestry") RootAncestry();
  else assert(false);
  std::cout << "ARX_ERASURE_POLICY_SUCCESS " << scenario << '\n';
}
