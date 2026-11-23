#include "journal.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdlib.h>
#include <sys/attr.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <limits>
#include <set>
#include <utility>

namespace arx::erasure {
namespace {
constexpr char kLedger[] = ".arx-profile-erasure-v1";
constexpr char kLock[] = ".arx-profile-erasure-lock";
constexpr char kTemporary[] = ".arx-profile-erasure-writing";
constexpr char kMagic[] = "ARXERASE";
// Version 3 persists volume UUIDs instead of st_dev. macOS assigns st_dev at
// mount time, so it changes across reboots and OS updates; version 2 ledgers
// are read by inode against the live roots and rewritten as version 3.
constexpr uint32_t kVersion = 3;
constexpr uint32_t kDeviceVersion = 2;

struct FD {
  explicit FD(int value = -1) : value(value) {}
  ~FD() { if (value >= 0) close(value); }
  FD(FD&& other) noexcept : value(std::exchange(other.value, -1)) {}
  FD& operator=(FD&& other) noexcept {
    if (value >= 0) close(value);
    value = std::exchange(other.value, -1);
    return *this;
  }
  FD(const FD&) = delete;
  FD& operator=(const FD&) = delete;
  int value;
};
struct Identity {
  uint64_t device = 0, inode = 0;
  bool operator==(const Identity&) const = default;
  bool present() const { return inode != 0; }
};
Identity IdentityOf(const struct stat& value) {
  return {static_cast<uint64_t>(value.st_dev), value.st_ino};
}
// Stable across reboots, unlike st_dev. Live comparisons keep using Identity.
using Volume = std::array<uint8_t, 16>;
bool VolumeOf(int fd, Volume* volume) {
  struct attrlist request{};
  request.bitmapcount = ATTR_BIT_MAP_COUNT;
  request.volattr = ATTR_VOL_INFO | ATTR_VOL_UUID;
  struct __attribute__((packed)) {
    uint32_t length;
    uint8_t value[16];
  } reply{};
  if (fgetattrlist(fd, &request, &reply, sizeof(reply), 0) || reply.length != sizeof(reply)) return false;
  std::memcpy(volume->data(), reply.value, volume->size());
  return *volume != Volume{};
}
bool UUID(const std::string& value) {
  if (value.size() != 36) return false;
  for (size_t i = 0; i < value.size(); ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (value[i] != '-') return false;
    } else if (!((value[i] >= '0' && value[i] <= '9') ||
                 (value[i] >= 'a' && value[i] <= 'f'))) return false;
  }
  return true;
}
bool BootUUID(const std::string& value) {
  return UUID(value) && value != "00000000-0000-0000-0000-000000000000";
}
bool ValidProcess(const ProcessIdentity& value) {
  return value.pid > 0 && value.seconds > 0 && value.microseconds < 1000000;
}
FD OpenDirectory(const std::string& path) {
  if (path.empty() || path.front() != '/' || path.back() == '/') return FD();
  FD directory(open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  size_t offset = 1;
  while (directory.value >= 0 && offset < path.size()) {
    size_t end = path.find('/', offset);
    std::string component = path.substr(offset, end - offset);
    if (component.empty() || component == "." || component == "..") return FD();
    directory = FD(openat(directory.value, component.c_str(),
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (end == std::string::npos) break;
    offset = end + 1;
  }
  return directory;
}
bool IsAncestor(int ancestor, int descendant, bool* result) {
  struct stat ancestor_info;
  if (fstat(ancestor, &ancestor_info)) return false;
  FD current(dup(descendant));
  for (size_t depth = 0; depth < 256 && current.value >= 0; ++depth) {
    struct stat info, parent_info;
    if (fstat(current.value, &info)) return false;
    if (IdentityOf(info) == IdentityOf(ancestor_info)) { *result = true; return true; }
    FD parent(openat(current.value, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (parent.value < 0 || fstat(parent.value, &parent_info)) return false;
    if (IdentityOf(info) == IdentityOf(parent_info)) { *result = false; return true; }
    current = std::move(parent);
  }
  return false;
}
bool OwnedDirectory(int fd, Identity* identity) {
  struct stat value;
  if (fstat(fd, &value) || !S_ISDIR(value.st_mode) || value.st_uid != geteuid() ||
      (value.st_mode & (S_IWGRP | S_IWOTH))) return false;
  *identity = IdentityOf(value);
  return true;
}
bool SameDirectory(const std::string& path, const Identity& expected) {
  auto directory = OpenDirectory(path);
  Identity actual;
  return directory.value >= 0 && OwnedDirectory(directory.value, &actual) && actual == expected;
}
Status Entry(int parent, const std::string& name, Identity* identity, bool directory) {
  struct stat value;
  if (fstatat(parent, name.c_str(), &value, AT_SYMLINK_NOFOLLOW)) {
    if (errno == ENOENT) { *identity = {}; return Status::kOK; }
    return Status::kIO;
  }
  if (value.st_uid != geteuid() || (value.st_mode & (S_IWGRP | S_IWOTH)) ||
      (directory ? !S_ISDIR(value.st_mode) : !S_ISREG(value.st_mode)) ||
      (!directory && value.st_nlink != 1)) return Status::kOwnershipChanged;
  *identity = IdentityOf(value);
  return Status::kOK;
}

struct Writer {
  std::vector<uint8_t> bytes;
  void Integer(uint64_t value) {
    for (int i = 0; i < 8; ++i) bytes.push_back(static_cast<uint8_t>(value >> (i * 8)));
  }
  void String(const std::string& value) {
    Integer(value.size());
    bytes.insert(bytes.end(), value.begin(), value.end());
  }
  void IdentityValue(const Identity& value, const Volume& volume) {
    const Volume stored = value.present() ? volume : Volume{};
    bytes.insert(bytes.end(), stored.begin(), stored.end());
    Integer(value.inode);
  }
  void Process(const ProcessIdentity& value) {
    Integer(value.pid); Integer(value.seconds); Integer(value.microseconds);
  }
};
struct Reader {
  const std::vector<uint8_t>& bytes;
  size_t position = 0;
  bool valid = true;
  uint64_t Integer() {
    if (position > bytes.size() || bytes.size() - position < 8) { valid = false; return 0; }
    uint64_t result = 0;
    for (int i = 0; i < 8; ++i) result |= uint64_t(bytes[position++]) << (i * 8);
    return result;
  }
  std::string String(size_t maximum = 36) {
    uint64_t size = Integer();
    if (!valid || size > maximum || size > bytes.size() - position) { valid = false; return {}; }
    std::string result(bytes.begin() + position, bytes.begin() + position + size);
    position += size;
    return result;
  }
  Volume VolumeValue() {
    Volume result{};
    if (position > bytes.size() || bytes.size() - position < result.size()) { valid = false; return result; }
    std::copy_n(bytes.begin() + position, result.size(), result.begin());
    position += result.size();
    return result;
  }
  // Rebinds a persisted identity to the live device of the root it lives in.
  bool IdentityValue(uint64_t version, const Volume& volume, uint64_t device, Identity* identity) {
    Volume stored{};
    if (version == kDeviceVersion) Integer();  // Boot-specific st_dev; not comparable.
    else stored = VolumeValue();
    const uint64_t inode = Integer();
    if (!inode) {
      *identity = {};
      return stored == Volume{};
    }
    *identity = {device, inode};
    return version == kDeviceVersion || stored == volume;
  }
  ProcessIdentity Process() {
    uint64_t pid = Integer();
    if (pid > std::numeric_limits<int32_t>::max()) valid = false;
    return {static_cast<int32_t>(pid), Integer(), Integer()};
  }
};
uint64_t Checksum(const std::vector<uint8_t>& bytes, size_t count) {
  // Corruption detection, not authentication. Ownership comes from openat,
  // owner-only journal files, inode checks and the actual native singleton.
  uint64_t hash = 14695981039346656037ULL;
  for (size_t i = 0; i < count; ++i) { hash ^= bytes[i]; hash *= 1099511628211ULL; }
  return hash;
}
struct Target {
  Identity identity;
  Phase phase = Phase::kOriginal;
};
struct Item {
  Record record;
  Target data, cache;
  bool boot_staged = false;
  std::string quarantine_boot;
};
std::string ProfileName(const Record& record) {
  return record.storage == Storage::kLegacyDefault ? "Default" : "Arx-" + record.profile_id;
}
std::string QuarantineName(const Record& record) {
  return ".arx-erasing-" + record.request_id;
}

struct Budget {
  size_t entries = 100000;
  std::chrono::steady_clock::time_point end =
      std::chrono::steady_clock::now() + std::chrono::seconds(30);
  bool Take() { return entries-- > 0 && std::chrono::steady_clock::now() < end; }
};
Status RemoveContents(int directory, uint64_t device, size_t depth, Budget& budget) {
  if (depth > 64) return Status::kLimit;
  FD duplicate(dup(directory));
  if (duplicate.value < 0) return Status::kIO;
  DIR* stream = fdopendir(duplicate.value);
  if (!stream) return Status::kIO;
  duplicate.value = -1;
  Status result = Status::kOK;
  errno = 0;
  while (auto* entry = readdir(stream)) {
    std::string name(entry->d_name);
    if (name == "." || name == "..") continue;
    if (!budget.Take()) { result = Status::kLimit; break; }
    struct stat before;
    if (fstatat(directory, name.c_str(), &before, AT_SYMLINK_NOFOLLOW)) { result = Status::kIO; break; }
    if (before.st_uid != geteuid() || uint64_t(before.st_dev) != device ||
        (before.st_mode & (S_IWGRP | S_IWOTH)) ||
        (!S_ISDIR(before.st_mode) && (!S_ISREG(before.st_mode) || before.st_nlink != 1))) {
      result = Status::kOwnershipChanged;
      break;
    }
    if (S_ISDIR(before.st_mode)) {
      FD child(openat(directory, name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
      struct stat opened;
      if (child.value < 0 || fstat(child.value, &opened) || IdentityOf(opened) != IdentityOf(before)) {
        result = Status::kOwnershipChanged;
        break;
      }
      result = RemoveContents(child.value, device, depth + 1, budget);
      if (result != Status::kOK) break;
    }
    struct stat current;
    if (fstatat(directory, name.c_str(), &current, AT_SYMLINK_NOFOLLOW) ||
        IdentityOf(current) != IdentityOf(before) || current.st_mode != before.st_mode) {
      result = Status::kOwnershipChanged;
      break;
    }
    if (unlinkat(directory, name.c_str(), S_ISDIR(before.st_mode) ? AT_REMOVEDIR : 0)) {
      result = Status::kIO;
      break;
    }
    errno = 0;
  }
  if (result == Status::kOK && errno != 0) result = Status::kIO;
  closedir(stream);
  if (result == Status::kOK && fsync(directory)) return Status::kIO;
  return result;
}
}  // namespace

Status PrepareOwnedDirectory(const std::string& path) {
  if (path.empty() || path.front() != '/' || path.back() == '/') return Status::kInvalid;
  FD directory(open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  size_t offset = 1;
  while (directory.value >= 0 && offset < path.size()) {
    size_t end = path.find('/', offset);
    std::string name = path.substr(offset, end - offset);
    if (name.empty() || name == "." || name == "..") return Status::kInvalid;
    int next = openat(directory.value, name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (next < 0 && errno == ENOENT) {
      if (mkdirat(directory.value, name.c_str(), 0700) || fsync(directory.value)) return Status::kIO;
      next = openat(directory.value, name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    }
    directory = FD(next);
    if (end == std::string::npos) break;
    offset = end + 1;
  }
  Identity identity;
  return directory.value >= 0 && OwnedDirectory(directory.value, &identity)
      ? Status::kOK : Status::kOwnershipChanged;
}
ProcessIdentity CurrentProcessIdentity() {
  struct proc_bsdinfo info;
  if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return {};
  return {getpid(), info.pbi_start_tvsec, info.pbi_start_tvusec};
}
ProcessState ReadProcessState(const ProcessIdentity& identity) {
  if (!ValidProcess(identity)) return ProcessState::kUnknown;
  struct proc_bsdinfo info;
  errno = 0;
  int size = proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
  if (size == sizeof(info)) {
    return info.pbi_start_tvsec == identity.seconds && info.pbi_start_tvusec == identity.microseconds
        ? ProcessState::kSameProcess : ProcessState::kExited;
  }
  return size == 0 && errno == ESRCH ? ProcessState::kExited : ProcessState::kUnknown;
}
std::string CurrentBootSession() {
  std::array<char, 37> value{};
  size_t size = value.size();
  if (sysctlbyname("kern.bootsessionuuid", value.data(), &size, nullptr, 0) ||
      size != value.size() || value.back() != '\0') return {};
  std::string session(value.data(), value.size() - 1);
  for (auto& character : session)
    if (character >= 'A' && character <= 'F') character += 'a' - 'A';
  return BootUUID(session) ? session : std::string{};
}

struct CreatedRoots::Impl {
  std::string data_parent_path, cache_parent_path, root_path, cache_path;
  FD data_parent, cache_parent, root, cache;
  Identity data_parent_identity, cache_parent_identity, root_identity, cache_identity;
  ProcessIdentity creator;
};
CreatedRoots::CreatedRoots(std::unique_ptr<Impl> implementation) : impl_(std::move(implementation)) {}
CreatedRoots::~CreatedRoots() = default;
CreatedRoots::CreatedRoots(CreatedRoots&&) noexcept = default;
CreatedRoots& CreatedRoots::operator=(CreatedRoots&&) noexcept = default;
const std::string& CreatedRoots::root() const { return impl_->root_path; }
const std::string& CreatedRoots::cache() const { return impl_->cache_path; }
Status CreatedRoots::Validate() const {
  if (!impl_ || impl_->creator != CurrentProcessIdentity()) return Status::kOwnershipChanged;
  Identity root, cache;
  struct stat root_info, cache_info;
  if (!OwnedDirectory(impl_->root.value, &root) || root != impl_->root_identity ||
      !OwnedDirectory(impl_->cache.value, &cache) || cache != impl_->cache_identity ||
      fstat(impl_->root.value, &root_info) || (root_info.st_mode & 0777) != 0700 ||
      fstat(impl_->cache.value, &cache_info) || (cache_info.st_mode & 0777) != 0700 ||
      !SameDirectory(impl_->data_parent_path, impl_->data_parent_identity) ||
      !SameDirectory(impl_->cache_parent_path, impl_->cache_parent_identity) ||
      !SameDirectory(impl_->root_path, root) || !SameDirectory(impl_->cache_path, cache))
    return Status::kOwnershipChanged;
  return Status::kOK;
}
std::unique_ptr<CreatedRoots> CreatedRoots::Create(
    const std::string& data_parent, const std::string& cache_parent, Status* status) {
  if (!status) return nullptr;
  *status = Status::kOwnershipChanged;
  auto impl = std::make_unique<Impl>();
  impl->data_parent_path = data_parent; impl->cache_parent_path = cache_parent;
  impl->data_parent = OpenDirectory(data_parent);
  impl->cache_parent = OpenDirectory(cache_parent);
  impl->creator = CurrentProcessIdentity();
  if (!ValidProcess(impl->creator) || impl->data_parent.value < 0 || impl->cache_parent.value < 0 ||
      !OwnedDirectory(impl->data_parent.value, &impl->data_parent_identity) ||
      !OwnedDirectory(impl->cache_parent.value, &impl->cache_parent_identity)) return nullptr;
  std::string name;
  for (size_t attempt = 0; attempt < 16; ++attempt) {
    std::array<uint8_t, 16> random;
    arc4random_buf(random.data(), random.size());
    name = "Arx-Owned-";
    for (auto byte : random) {
      constexpr char digits[] = "0123456789abcdef";
      name += digits[byte >> 4]; name += digits[byte & 15];
    }
    if (mkdirat(impl->data_parent.value, name.c_str(), 0700) == 0) break;
    *status = errno == EEXIST ? Status::kBusy : Status::kIO;
    if (*status != Status::kBusy || attempt == 15) return nullptr;
  }
  // A failed second creation leaves the new first directory alone. Cleanup
  // must never remove a path whose later ownership has not been established.
  impl->root_path = data_parent + "/" + name;
  impl->cache_path = cache_parent + "/" + name;
  impl->root = FD(openat(impl->data_parent.value, name.c_str(),
                         O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (impl->data_parent_identity != impl->cache_parent_identity) {
    if (mkdirat(impl->cache_parent.value, name.c_str(), 0700)) {
      *status = errno == EEXIST ? Status::kBusy : Status::kIO;
      return nullptr;
    }
  }
  impl->cache = FD(openat(impl->cache_parent.value, name.c_str(),
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
  if (impl->root.value < 0 || impl->cache.value < 0 ||
      !OwnedDirectory(impl->root.value, &impl->root_identity) ||
      !OwnedDirectory(impl->cache.value, &impl->cache_identity)) return nullptr;
  if (fsync(impl->data_parent.value) || fsync(impl->cache_parent.value)) {
    *status = Status::kIO;
    return nullptr;
  }
  auto created = std::unique_ptr<CreatedRoots>(new CreatedRoots(std::move(impl)));
  *status = created->Validate();
  return *status == Status::kOK ? std::move(created) : nullptr;
}

struct Journal::Impl {
  std::string root_path, cache_path, installation, legacy;
  FD root, cache, lock;
  Identity root_identity, cache_identity, ledger_identity, lock_identity;
  Volume root_volume{}, cache_volume{};
  uint64_t revision = 0;
  ProcessIdentity owner;
  std::vector<ProcessIdentity> children;
  std::vector<Item> items;
  bool clean = false, begun = false, may_erase = false, io_failed = false;
  bool startup_finished = false, finished = false, may_finish_clean = false;
  bool allow_initial_clean_boundary = true;
  BootSessionReader read_boot_session;

  bool RootsMatch() const {
    Identity actual_lock;
    return SameDirectory(root_path, root_identity) && SameDirectory(cache_path, cache_identity) &&
        Entry(root.value, kLock, &actual_lock, false) == Status::kOK && actual_lock == lock_identity;
  }
  bool OwnerMatches() const { return begun && !finished && owner == CurrentProcessIdentity(); }
  void InvalidateReceipt() {
    io_failed = true;
    for (auto& item : items) item.record.verified = false;
  }
  bool Checkpoint(const std::function<bool(Boundary)>& callback, Boundary boundary) {
    return !callback || callback(boundary);
  }
  std::vector<uint8_t> Encode() const {
    Writer output;
    output.String(kMagic);
    output.Integer(kVersion);
    output.String(installation);
    output.String(legacy);
    output.IdentityValue(root_identity, root_volume);
    output.IdentityValue(cache_identity, cache_volume);
    output.Integer(revision);
    output.Process(owner);
    output.Integer(clean);
    output.Integer(children.size());
    for (const auto& child : children) output.Process(child);
    output.Integer(items.size());
    for (const auto& item : items) {
      output.String(item.record.profile_id);
      output.Integer(static_cast<uint64_t>(item.record.storage));
      output.String(item.record.request_id);
      output.Integer(item.record.retired);
      output.Integer(item.record.verified);
      for (const auto* target : {&item.data, &item.cache}) {
        output.IdentityValue(target->identity, target == &item.data ? root_volume : cache_volume);
        output.Integer(static_cast<uint64_t>(target->phase));
      }
      output.Integer(item.boot_staged);
      output.String(item.quarantine_boot);
    }
    output.Integer(Checksum(output.bytes, output.bytes.size()));
    return output.bytes;
  }
  Status Decode(const std::vector<uint8_t>& bytes) {
    Reader input{bytes};
    if (input.String() != kMagic) return Status::kOwnershipChanged;
    const uint64_t version = input.Integer();
    if (version != kVersion && version != kDeviceVersion) return Status::kOwnershipChanged;
    Identity stored_root, stored_cache;
    if (input.String() != installation || input.String() != legacy ||
        !input.IdentityValue(version, root_volume, root_identity.device, &stored_root) ||
        !input.IdentityValue(version, cache_volume, cache_identity.device, &stored_cache) ||
        stored_root != root_identity || stored_cache != cache_identity)
      return Status::kOwnershipChanged;
    revision = input.Integer();
    owner = input.Process();
    uint64_t clean_value = input.Integer();
    if (clean_value > 1) return Status::kCorrupt;
    clean = clean_value;
    uint64_t count = input.Integer();
    if (count > kMaximumChildren) return Status::kCorrupt;
    for (uint64_t i = 0; i < count; ++i) {
      auto child = input.Process();
      if (!ValidProcess(child)) return Status::kCorrupt;
      children.push_back(child);
    }
    count = input.Integer();
    if (count > kMaximumProfiles) return Status::kCorrupt;
    std::set<std::string> ids, requests;
    for (uint64_t i = 0; i < count; ++i) {
      Item item;
      item.record.profile_id = input.String();
      uint64_t storage = input.Integer();
      item.record.storage = static_cast<Storage>(storage);
      item.record.request_id = input.String();
      uint64_t retired = input.Integer(), verified = input.Integer();
      item.record.retired = retired;
      item.record.verified = verified;
      for (auto* target : {&item.data, &item.cache}) {
        const bool data = target == &item.data;
        if (!input.IdentityValue(version, data ? root_volume : cache_volume,
                                 data ? root_identity.device : cache_identity.device, &target->identity))
          return Status::kOwnershipChanged;
        uint64_t phase = input.Integer();
        if (phase > static_cast<uint64_t>(Phase::kRemoved)) return Status::kCorrupt;
        target->phase = static_cast<Phase>(phase);
      }
      const auto staged = input.Integer();
      if (staged > 1) return Status::kCorrupt;
      item.boot_staged = staged;
      item.quarantine_boot = input.String();
      if (!UUID(item.record.profile_id) || !ids.insert(item.record.profile_id).second ||
          storage > static_cast<uint64_t>(Storage::kLegacyDefault) || retired > 1 || verified > 1 ||
          (item.record.profile_id == legacy) != (item.record.storage == Storage::kLegacyDefault) ||
          (retired && (!UUID(item.record.request_id) || !requests.insert(item.record.request_id).second)) ||
          (!retired && (!item.record.request_id.empty() || verified)) ||
          (item.boot_staged && !retired) ||
          (!item.quarantine_boot.empty() && (!item.boot_staged || !BootUUID(item.quarantine_boot) ||
            item.data.phase == Phase::kOriginal || item.cache.phase == Phase::kOriginal)) ||
          (verified && (item.data.phase != Phase::kRemoved || item.cache.phase != Phase::kRemoved)))
        return Status::kCorrupt;
      items.push_back(item);
    }
    size_t checksum_offset = input.position;
    uint64_t checksum = input.Integer();
    if (!input.valid || input.position != bytes.size() || checksum != Checksum(bytes, checksum_offset) ||
        (revision && !ValidProcess(owner))) return Status::kCorrupt;
    return Status::kOK;
  }
  Status Read() {
    Status status = Entry(root.value, kLedger, &ledger_identity, false);
    if (status != Status::kOK || !ledger_identity.present()) return status;
    FD file(openat(root.value, kLedger, O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
    struct stat info;
    if (file.value < 0 || fstat(file.value, &info) || IdentityOf(info) != ledger_identity ||
        (info.st_mode & 0777) != 0600 || info.st_size < 0 ||
        uint64_t(info.st_size) > kMaximumJournalBytes) return Status::kCorrupt;
    std::vector<uint8_t> bytes(static_cast<size_t>(info.st_size));
    size_t offset = 0;
    while (offset < bytes.size()) {
      ssize_t count = read(file.value, bytes.data() + offset, bytes.size() - offset);
      if (count <= 0) return Status::kIO;
      offset += count;
    }
    return Decode(bytes);
  }
  Status Save() {
    Status status = SaveImpl();
    if (status != Status::kOK) {
      InvalidateReceipt();
    }
    return status;
  }
  Status SaveImpl() {
    if (io_failed) return Status::kIO;
    if (!RootsMatch()) return Status::kOwnershipChanged;
    Identity current;
    Status status = Entry(root.value, kLedger, &current, false);
    if (status != Status::kOK || current != ledger_identity) return Status::kOwnershipChanged;
    if (revision == std::numeric_limits<uint64_t>::max()) return Status::kLimit;
    ++revision;
    auto bytes = Encode();
    if (bytes.size() > kMaximumJournalBytes) return Status::kLimit;
    // A torn prior attempt is not overwritten or trusted. Its owner may retry
    // only after validating this exact owner-only regular file, then removing it.
    Identity temporary;
    status = Entry(root.value, kTemporary, &temporary, false);
    if (status != Status::kOK) return status;
    if (temporary.present() && unlinkat(root.value, kTemporary, 0)) return Status::kIO;
    FD file(openat(root.value, kTemporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (file.value < 0) return Status::kIO;
    size_t offset = 0;
    while (offset < bytes.size()) {
      ssize_t count = write(file.value, bytes.data() + offset, bytes.size() - offset);
      if (count <= 0) { io_failed = true; return Status::kIO; }
      offset += count;
    }
    if (fsync(file.value) || !RootsMatch()) { io_failed = true; return Status::kIO; }
    status = Entry(root.value, kLedger, &current, false);
    if (status != Status::kOK || current != ledger_identity) return Status::kOwnershipChanged;
    if (renameat(root.value, kTemporary, root.value, kLedger) || fsync(root.value)) {
      io_failed = true;
      return Status::kIO;
    }
    status = Entry(root.value, kLedger, &ledger_identity, false);
    if (status != Status::kOK) io_failed = true;
    return status;
  }
  Status QuarantineTarget(Item& item, Target& target, int parent,
                     const Identity& parent_identity,
                     const std::function<bool(Boundary)>& checkpoint,
                          bool allow_absent_quarantine) {
    if (!RootsMatch() || !OwnerMatches()) return Status::kOwnershipChanged;
    const auto name = ProfileName(item.record), quarantine = QuarantineName(item.record);
    Identity original, moved;
    Status result = Entry(parent, name, &original, true);
    if (result != Status::kOK) return result;
    result = Entry(parent, quarantine, &moved, true);
    if (result != Status::kOK) return result;
    if (target.phase == Phase::kRemoved)
      return !original.present() && !moved.present() ? Status::kOK : Status::kOwnershipChanged;
    if (!target.identity.present()) {
      if (original.present() || moved.present()) return Status::kOwnershipChanged;
      target.phase = Phase::kRemoved;
      return Save();
    }
    if (target.phase == Phase::kOriginal) {
      if (original == target.identity && !moved.present()) {
        if (renameatx_np(parent, name.c_str(), parent, quarantine.c_str(), RENAME_EXCL) || fsync(parent))
          return Status::kIO;
        if (!Checkpoint(checkpoint, Boundary::kRenamed)) return Status::kPending;
        result = Entry(parent, quarantine, &moved, true);
        if (result != Status::kOK || moved != target.identity) return Status::kOwnershipChanged;
      } else if (original.present() || moved != target.identity) return Status::kOwnershipChanged;
      target.phase = Phase::kQuarantined;
      result = Save();
      if (result != Status::kOK) return result;
      if (!Checkpoint(checkpoint, Boundary::kQuarantineRecorded)) return Status::kPending;
    }
    result = Entry(parent, name, &original, true);
    if (result != Status::kOK || original.present()) return Status::kOwnershipChanged;
    result = Entry(parent, quarantine, &moved, true);
    if (result != Status::kOK ||
        (moved.present() ? moved != target.identity || moved.device != parent_identity.device
                         : !allow_absent_quarantine)) return Status::kOwnershipChanged;
    return Status::kOK;
  }
  Status EraseTarget(Item& item, Target& target, int parent,
                     const Identity& parent_identity,
                     const std::function<bool(Boundary)>& checkpoint) {
    Status result = QuarantineTarget(item, target, parent, parent_identity, checkpoint, true);
    if (result != Status::kOK || target.phase == Phase::kRemoved) return result;
    const auto name = ProfileName(item.record), quarantine = QuarantineName(item.record);
    Identity original, moved;
    result = Entry(parent, name, &original, true);
    if (result != Status::kOK || original.present()) return Status::kOwnershipChanged;
    result = Entry(parent, quarantine, &moved, true);
    if (result != Status::kOK) return result;
    if (moved.present()) {
      if (moved != target.identity || moved.device != parent_identity.device) return Status::kOwnershipChanged;
      FD directory(openat(parent, quarantine.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
      Identity opened;
      if (directory.value < 0 || !OwnedDirectory(directory.value, &opened) || opened != moved)
        return Status::kOwnershipChanged;
      Budget budget;
      result = RemoveContents(directory.value, moved.device, 0, budget);
      if (result != Status::kOK) return result;
      Identity current;
      if (!RootsMatch() || Entry(parent, quarantine, &current, true) != Status::kOK || current != moved)
        return Status::kOwnershipChanged;
      if (unlinkat(parent, quarantine.c_str(), AT_REMOVEDIR) || fsync(parent)) return Status::kIO;
      if (!Checkpoint(checkpoint, Boundary::kRemoved)) return Status::kPending;
    }
    target.phase = Phase::kRemoved;
    result = Save();
    if (result != Status::kOK) return result;
    return Checkpoint(checkpoint, Boundary::kRemovalRecorded) ? Status::kOK : Status::kPending;
  }
  Status VerifyRemoved(Item& item, const std::function<bool(Boundary)>& checkpoint) {
    // Re-read both paths after work. A late recreation is failure, not success.
    for (int parent : {root.value, cache.value}) {
      for (const auto& name : {ProfileName(item.record), QuarantineName(item.record)}) {
        Identity current;
        Status status = Entry(parent, name, &current, true);
        if (status != Status::kOK || current.present()) return Status::kOwnershipChanged;
      }
    }
    item.record.verified = true;
    Status status = Save();
    if (status != Status::kOK) return status;
    return Checkpoint(checkpoint, Boundary::kVerified) ? Status::kOK : Status::kPending;
  }
};

Journal::Journal(std::unique_ptr<Impl> implementation) : impl_(std::move(implementation)) {}
Journal::~Journal() = default;
std::unique_ptr<Journal> Journal::Open(const std::string& root, const std::string& cache_root,
                                     const std::string& installation_id,
                                     const std::string& legacy_profile_id, Status* status,
                                     BootSessionReader read_boot_session) {
  if (!status) return nullptr;
  *status = Status::kInvalid;
  if (!UUID(installation_id) || !UUID(legacy_profile_id)) return nullptr;
  auto impl = std::make_unique<Impl>();
  impl->root_path = root; impl->cache_path = cache_root;
  impl->installation = installation_id; impl->legacy = legacy_profile_id;
  impl->read_boot_session = std::move(read_boot_session);
  impl->root = OpenDirectory(root); impl->cache = OpenDirectory(cache_root);
  if (impl->root.value < 0 || impl->cache.value < 0 ||
      !OwnedDirectory(impl->root.value, &impl->root_identity) ||
      !OwnedDirectory(impl->cache.value, &impl->cache_identity) ||
      !VolumeOf(impl->root.value, &impl->root_volume) ||
      !VolumeOf(impl->cache.value, &impl->cache_volume)) {
    *status = Status::kOwnershipChanged;
    return nullptr;
  }
  // Use inode ancestry, not lexical prefixes: case-insensitive aliases may
  // spell the same ancestor differently without being symlinks.
  if (impl->root_identity != impl->cache_identity) {
    bool root_contains_cache = false, cache_contains_root = false;
    if (!IsAncestor(impl->root.value, impl->cache.value, &root_contains_cache) ||
        !IsAncestor(impl->cache.value, impl->root.value, &cache_contains_root) ||
        root_contains_cache || cache_contains_root) {
      *status = Status::kOwnershipChanged;
      return nullptr;
    }
  }
  impl->lock = FD(openat(impl->root.value, kLock, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600));
  struct stat lock_info;
  if (impl->lock.value < 0 || fstat(impl->lock.value, &lock_info) ||
      !S_ISREG(lock_info.st_mode) || lock_info.st_uid != geteuid() ||
      lock_info.st_nlink != 1 || (lock_info.st_mode & 0777) != 0600) return nullptr;
  impl->lock_identity = IdentityOf(lock_info);
  if (!impl->RootsMatch()) { *status = Status::kOwnershipChanged; return nullptr; }
  if (flock(impl->lock.value, LOCK_EX | LOCK_NB)) { *status = Status::kBusy; return nullptr; }
  *status = impl->Read();
  if (*status != Status::kOK) return nullptr;
  return std::unique_ptr<Journal>(new Journal(std::move(impl)));
}
Status Journal::BeginRun(const ProcessIdentity& owner, bool strict_singleton) {
  if (impl_->begun || !ValidProcess(owner) || owner != CurrentProcessIdentity()) return Status::kInvalid;
  bool prior_clean = impl_->clean && ReadProcessState(impl_->owner) == ProcessState::kExited;
  for (const auto& child : impl_->children)
    prior_clean = prior_clean && ReadProcessState(child) == ProcessState::kExited;
  // A later orderly browser exit cannot prove that helpers from an earlier
  // dirty run have exited: their launch identities may never have reached the
  // journal. Preserve that missing proof across every subsequent owner.
  const bool pristine = impl_->revision == 0 && impl_->owner == ProcessIdentity{} &&
                        impl_->children.empty() && impl_->items.empty();
  impl_->may_finish_clean = (pristine && impl_->allow_initial_clean_boundary) || prior_clean;
  impl_->may_erase = strict_singleton && prior_clean;
  impl_->owner = owner;
  impl_->clean = false;
  impl_->children.clear();
  impl_->begun = true;
  for (auto& item : impl_->items) item.record.verified = false;
  Status status = impl_->Save();
  if (status != Status::kOK) impl_->may_erase = false;
  return status;
}
Status Journal::RequirePriorCleanBoundary() {
  if (impl_->begun) return Status::kInvalid;
  impl_->allow_initial_clean_boundary = false;
  return Status::kOK;
}
void Journal::FinishStartup() {
  impl_->startup_finished = true;
  impl_->may_erase = false;
}
Status Journal::TrackChild(const ProcessIdentity& child) {
  if (!impl_->OwnerMatches() || !ValidProcess(child)) return Status::kInvalid;
  if (std::find(impl_->children.begin(), impl_->children.end(), child) != impl_->children.end()) return Status::kOK;
  if (impl_->children.size() == kMaximumChildren) { impl_->io_failed = true; return Status::kLimit; }
  impl_->children.push_back(child);
  return Status::kOK;
}
Status Journal::FinishCleanRun() {
  if (!impl_->OwnerMatches()) return Status::kOwnershipChanged;
  if (!impl_->may_finish_clean) return Status::kPending;
  for (const auto& child : impl_->children)
    if (ReadProcessState(child) != ProcessState::kExited) return Status::kPending;
  impl_->clean = true;
  Status status = impl_->Save();
  if (status == Status::kOK) {
    impl_->finished = true;
    impl_->may_erase = false;
  }
  return status;
}
Status Journal::RegisterProfile(const std::string& profile_id, Storage storage) {
  FinishStartup();
  if (!impl_->OwnerMatches() || !UUID(profile_id) ||
      (storage != Storage::kOrdinary && storage != Storage::kLegacyDefault) ||
      (profile_id == impl_->legacy) != (storage == Storage::kLegacyDefault)) return Status::kInvalid;
  auto found = std::find_if(impl_->items.begin(), impl_->items.end(), [&](const Item& item) {
    return item.record.profile_id == profile_id;
  });
  if (found != impl_->items.end()) return found->record.retired ? Status::kRetired : Status::kOK;
  if (impl_->items.size() == kMaximumProfiles) return Status::kLimit;
  Item item;
  item.record.profile_id = profile_id; item.record.storage = storage;
  impl_->items.push_back(item);
  return impl_->Save();
}
Status Journal::Queue(const std::string& profile_id, Storage storage,
                      const std::string& request_id, uint64_t expected_revision) {
  if (!impl_->OwnerMatches() || !impl_->startup_finished || !UUID(request_id)) return Status::kInvalid;
  if (expected_revision != impl_->revision) return Status::kStale;
  auto found = std::find_if(impl_->items.begin(), impl_->items.end(), [&](const Item& item) {
    return item.record.profile_id == profile_id;
  });
  if (found == impl_->items.end()) return Status::kNotRegistered;
  if (found->record.storage != storage) return Status::kInvalid;
  if (found->record.retired) return Status::kRetired;
  if (std::any_of(impl_->items.begin(), impl_->items.end(), [&](const Item& item) {
        return item.record.request_id == request_id;
      })) return Status::kInvalid;
  Item updated = *found;
  const auto name = ProfileName(updated.record);
  Status status = Entry(impl_->root.value, name, &updated.data.identity, true);
  if (status != Status::kOK) return status;
  status = Entry(impl_->cache.value, name, &updated.cache.identity, true);
  if (status != Status::kOK) return status;
  if (impl_->root_identity == impl_->cache_identity) updated.cache = {{}, Phase::kRemoved};
  updated.record.request_id = request_id;
  updated.record.retired = true;
  *found = updated;
  return impl_->Save();
}
bool Journal::IsRetired(const std::string& profile_id) const {
  return std::any_of(impl_->items.begin(), impl_->items.end(), [&](const Item& item) {
    return item.record.profile_id == profile_id && item.record.retired;
  });
}
bool Journal::CanUseLedger() const {
  return impl_->OwnerMatches() && impl_->RootsMatch() && !impl_->io_failed;
}
Snapshot Journal::GetSnapshot() const {
  Snapshot result;
  result.revision = impl_->revision; result.may_erase = impl_->may_erase;
  result.durable = !impl_->io_failed;
  std::string boot;
  if (std::any_of(impl_->items.begin(), impl_->items.end(), [](const Item& item) {
        return item.record.retired && !item.record.verified && !item.quarantine_boot.empty();
      }) && impl_->read_boot_session) boot = impl_->read_boot_session();
  for (const auto& item : impl_->items) {
    auto record = item.record;
    if (!record.retired) record.progress = Progress::kActive;
    else if (!result.durable) record.progress = Progress::kBlocked;
    else if (record.verified) record.progress = Progress::kErased;
    else if (!item.boot_staged) record.progress = Progress::kAwaitingStartup;
    else if (item.quarantine_boot.empty()) record.progress = Progress::kQuarantinePending;
    else if (!BootUUID(boot) || boot != item.quarantine_boot)
      record.progress = Progress::kVerificationPending;
    else record.progress = Progress::kRestartRequired;
    result.records.push_back(std::move(record));
  }
  return result;
}
Status Journal::Execute(const std::function<bool(Boundary)>& checkpoint) {
  if (!impl_->OwnerMatches() || !impl_->RootsMatch()) {
    impl_->InvalidateReceipt();
    return Status::kOwnershipChanged;
  }
  if (!impl_->may_erase || impl_->startup_finished || impl_->io_failed) return Status::kPending;
  bool pending = false;
  for (auto& item : impl_->items) {
    if (!item.record.retired) continue;
    item.record.verified = false;
    if (item.boot_staged) {
      // Boot-staged targets have their own authority and cannot fall through
      // another execution path while the staged writers might still be alive.
      pending = true;
      continue;
    }
    Status status = impl_->EraseTarget(item, item.data, impl_->root.value, impl_->root_identity, checkpoint);
    if (status != Status::kOK) return status;
    if (impl_->root_identity != impl_->cache_identity) {
      status = impl_->EraseTarget(item, item.cache, impl_->cache.value, impl_->cache_identity, checkpoint);
      if (status != Status::kOK) return status;
    }
    status = impl_->VerifyRemoved(item, checkpoint);
    if (status != Status::kOK) return status;
  }
  return pending ? Status::kPending : Status::kVerified;
}
Status Journal::StageForNextBoot(const std::function<bool(Boundary)>& checkpoint) {
  if (!impl_->OwnerMatches() || !impl_->RootsMatch()) {
    impl_->InvalidateReceipt();
    return Status::kOwnershipChanged;
  }
  if (impl_->startup_finished || impl_->io_failed) return Status::kPending;
  for (auto& item : impl_->items) {
    if (!item.record.retired) continue;
    if (item.record.verified) continue;
    item.record.verified = false;
    // Choose and durably publish the non-destructive staging route before its
    // first rename. Even an interrupted two-root stage cannot later fall into
    // the ordinary executor and unlink while the original writers may live.
    if (!item.boot_staged) {
      item.boot_staged = true;
      Status status = impl_->Save();
      if (status != Status::kOK) return status;
    }
    Status status = impl_->QuarantineTarget(item, item.data, impl_->root.value,
                                            impl_->root_identity, checkpoint, false);
    if (status != Status::kOK) return status;
    if (impl_->root_identity != impl_->cache_identity) {
      status = impl_->QuarantineTarget(item, item.cache, impl_->cache.value,
                                       impl_->cache_identity, checkpoint, false);
      if (status != Status::kOK) return status;
    }
    if (!item.quarantine_boot.empty()) continue;
    status = impl_->QuarantineTarget(item, item.data, impl_->root.value,
                                     impl_->root_identity, {}, false);
    if (status != Status::kOK) return status;
    if (impl_->root_identity != impl_->cache_identity) {
      status = impl_->QuarantineTarget(item, item.cache, impl_->cache.value,
                                       impl_->cache_identity, {}, false);
      if (status != Status::kOK) return status;
    }
    // Capture only after both exact inodes have been renamed and their phases
    // durably published. An interrupted publication gets a new baseline later;
    // it cannot borrow the boot in which some earlier rename might have run.
    const auto boot = impl_->read_boot_session ? impl_->read_boot_session() : std::string{};
    if (!BootUUID(boot)) return Status::kPending;
    item.quarantine_boot = boot;
    status = impl_->Save();
    if (status != Status::kOK) return status;
    if (!impl_->Checkpoint(checkpoint, Boundary::kQuarantineSealed)) return Status::kPending;
  }
  return Status::kPending;
}
Status Journal::ResumeQuarantinedAfterBoot(const std::function<bool(Boundary)>& checkpoint) {
  if (!impl_->OwnerMatches() || !impl_->RootsMatch()) {
    impl_->InvalidateReceipt();
    return Status::kOwnershipChanged;
  }
  if (impl_->startup_finished || impl_->io_failed) return Status::kPending;
  for (auto& item : impl_->items)
    if (item.record.retired) item.record.verified = false;
  const auto boot = impl_->read_boot_session ? impl_->read_boot_session() : std::string{};
  if (!BootUUID(boot)) return Status::kPending;
  bool pending = false;
  for (auto& item : impl_->items) {
    if (!item.record.retired) continue;
    if (!item.boot_staged || item.quarantine_boot.empty() || item.quarantine_boot == boot) {
      pending = true;
      continue;
    }
    if (item.data.phase == Phase::kOriginal || item.cache.phase == Phase::kOriginal)
      return Status::kCorrupt;
    // Validate both source paths and both private quarantine identities before
    // unlinking either root. Later ordinary binaries know only original names;
    // a recreated original is neither adopted nor removed by this boundary.
    Status status = impl_->QuarantineTarget(item, item.data, impl_->root.value,
                                            impl_->root_identity, {}, true);
    if (status != Status::kOK) return status;
    if (impl_->root_identity != impl_->cache_identity) {
      status = impl_->QuarantineTarget(item, item.cache, impl_->cache.value,
                                       impl_->cache_identity, {}, true);
      if (status != Status::kOK) return status;
    }
    status = impl_->EraseTarget(item, item.data, impl_->root.value, impl_->root_identity, checkpoint);
    if (status != Status::kOK) return status;
    if (impl_->root_identity != impl_->cache_identity) {
      status = impl_->EraseTarget(item, item.cache, impl_->cache.value, impl_->cache_identity, checkpoint);
      if (status != Status::kOK) return status;
    }
    status = impl_->VerifyRemoved(item, checkpoint);
    if (status != Status::kOK) return status;
  }
  return pending ? Status::kPending : Status::kVerified;
}
}  // namespace arx::erasure
