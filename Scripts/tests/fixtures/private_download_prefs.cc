// Fakes for Packages/engine/Native/private_download_prefs.mm (DEV-729). The
// production code after its includes replaces the IMPLEMENTATION marker.
#include <cassert>
#include <cstdint>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#define FROM_HERE 0
#define DCHECK_CURRENTLY_ON(thread) (void)0
namespace content { struct BrowserThread { enum { UI }; }; }

namespace base {
template <typename T> using raw_ptr = T*;
template <typename T> struct NoDestructor {
  T value;
  T& operator*() { return value; }
};
struct FilePath {
  std::string path;
  bool operator==(const FilePath&) const = default;
};
template <typename T> T* Unretained(T* pointer) { return pointer; }
template <typename Method, typename Object>
std::function<void()> BindRepeating(Method method, Object* object) {
  return [method, object] { (object->*method)(); };
}
template <typename Function, typename... Arguments>
std::function<void()> BindOnce(Function function, Arguments... arguments) {
  return [function, arguments...] { function(arguments...); };
}
std::deque<std::function<void()>> tasks;
struct SingleThreadTaskRunner {
  static SingleThreadTaskRunner* GetCurrentDefault() { static SingleThreadTaskRunner runner; return &runner; }
  void PostTask(int, std::function<void()> task) { tasks.push_back(std::move(task)); }
};
}  // namespace base
using base::raw_ptr;

namespace prefs {
inline constexpr char kDownloadDefaultDirectory[] = "download.default_directory";
inline constexpr char kSaveFileDefaultDirectory[] = "savefile.default_directory";
inline constexpr char kPromptForDownload[] = "download.prompt_for_download";
}  // namespace prefs

struct PrefService {
  struct Preference {
    bool managed = false;
    bool IsManaged() const { return managed; }
  };
  std::map<std::string, Preference> preferences;
  std::map<std::string, base::FilePath> paths;
  std::map<std::string, bool> booleans;
  std::map<std::string, std::vector<std::function<void()>>> observers;
  int writes = 0;
  const Preference* FindPreference(const char* name) {
    return &preferences[name];
  }
  void SetFilePath(const char* name, const base::FilePath& value) {
    ++writes;
    paths[name] = value;
    Notify(name);
  }
  void SetBoolean(const char* name, bool value) {
    ++writes;
    booleans[name] = value;
    Notify(name);
  }
  void Notify(const std::string& name) {
    auto copy = observers[name];
    for (auto& observer : copy) observer();
  }
};

struct PrefChangeRegistrar {
  PrefService* service = nullptr;
  std::vector<std::pair<std::string, size_t>> added;
  void Init(PrefService* prefs) { service = prefs; }
  void Add(const char* name, std::function<void()> callback) {
    service->observers[name].push_back(std::move(callback));
    added.emplace_back(name, service->observers[name].size() - 1);
  }
  void RemoveAll() {
    if (!service) return;
    for (auto& [name, index] : added) service->observers[name][index] = [] {};
    added.clear();
  }
  ~PrefChangeRegistrar() { RemoveAll(); }
};

class Profile;
class ProfileObserver {
 public:
  virtual ~ProfileObserver() = default;
  virtual void OnProfileWillBeDestroyed(Profile*) {}
};

class Profile {
 public:
  bool off_the_record = false;
  PrefService preferences;
  std::set<ProfileObserver*> observers;
  bool IsOffTheRecord() { return off_the_record; }
  PrefService* GetPrefs() { return &preferences; }
  void Destroy() {
    auto copy = observers;
    for (auto* observer : copy) observer->OnProfileWillBeDestroyed(this);
  }
};

namespace base {
template <typename Source, typename Observer> struct ScopedMultiSourceObservation {
  Observer* observer;
  std::vector<Source*> sources;
  explicit ScopedMultiSourceObservation(Observer* value) : observer(value) {}
  void AddObservation(Source* source) {
    source->observers.insert(observer);
    sources.push_back(source);
  }
  void RemoveAllObservations() {
    for (auto* source : sources) source->observers.erase(observer);
    sources.clear();
  }
  ~ScopedMultiSourceObservation() { RemoveAllObservations(); }
};
}  // namespace base

// The opener's effective values, as Chromium's DownloadPrefs reads them.
struct DownloadPrefs {
  Profile* profile;
  static std::map<Profile*, std::unique_ptr<DownloadPrefs>>& All() {
    static std::map<Profile*, std::unique_ptr<DownloadPrefs>> all;
    return all;
  }
  static DownloadPrefs* FromBrowserContext(Profile* profile) {
    auto& slot = All()[profile];
    if (!slot) slot = std::make_unique<DownloadPrefs>(DownloadPrefs{profile});
    return slot.get();
  }
  base::FilePath DownloadPath() const {
    auto& paths = profile->preferences.paths;
    auto found = paths.find(prefs::kDownloadDefaultDirectory);
    return found == paths.end() ? base::FilePath{"/Users/me/Downloads"} : found->second;
  }
  base::FilePath SaveFilePath() const {
    auto& paths = profile->preferences.paths;
    auto found = paths.find(prefs::kSaveFileDefaultDirectory);
    return found == paths.end() ? DownloadPath() : found->second;
  }
  bool PromptForDownload() const {
    auto& booleans = profile->preferences.booleans;
    auto found = booleans.find(prefs::kPromptForDownload);
    return found != booleans.end() && found->second;
  }
};

namespace arx {
void FollowOpenerDownloadPreferences(Profile* private_profile, Profile* opener);
void StopFollowingOpenerDownloadPreferences(Profile* private_profile);
}  // namespace arx
// IMPLEMENTATION

using namespace arx;

void Drain() {
  while (!base::tasks.empty()) {
    auto task = std::move(base::tasks.front());
    base::tasks.pop_front();
    task();
  }
}

base::FilePath Path(Profile& profile, const char* name) {
  return profile.preferences.paths.at(name);
}
bool Ask(Profile& profile) { return profile.preferences.booleans.at(prefs::kPromptForDownload); }

Profile Ordinary() { return {}; }
Profile Private() {
  Profile profile;
  profile.off_the_record = true;
  return profile;
}

void CopiesNowAndOnChange() {
  auto opener = Ordinary();
  auto otr = Private();
  opener.preferences.paths[prefs::kDownloadDefaultDirectory] = {"/Volumes/Work"};
  opener.preferences.booleans[prefs::kPromptForDownload] = true;
  FollowOpenerDownloadPreferences(&otr, &opener);
  assert(Path(otr, prefs::kDownloadDefaultDirectory) == base::FilePath{"/Volumes/Work"});
  assert(Path(otr, prefs::kSaveFileDefaultDirectory) == base::FilePath{"/Volumes/Work"});
  assert(Ask(otr));
  const int opener_writes = opener.preferences.writes;
  opener.preferences.SetFilePath(prefs::kDownloadDefaultDirectory, {"/tmp/elsewhere"});
  opener.preferences.SetBoolean(prefs::kPromptForDownload, false);
  assert(Path(otr, prefs::kDownloadDefaultDirectory) == base::FilePath{"/tmp/elsewhere"});
  assert(!Ask(otr));
  // Only the opener's own two writes: the link never writes back to it.
  assert(opener.preferences.writes == opener_writes + 2);
  StopFollowingOpenerDownloadPreferences(&otr);
  Drain();
}

void ManagedIsLeftAlone() {
  auto opener = Ordinary();
  auto otr = Private();
  otr.preferences.preferences[prefs::kPromptForDownload].managed = true;
  otr.preferences.preferences[prefs::kDownloadDefaultDirectory].managed = true;
  opener.preferences.booleans[prefs::kPromptForDownload] = true;
  FollowOpenerDownloadPreferences(&otr, &opener);
  assert(!otr.preferences.booleans.contains(prefs::kPromptForDownload));
  assert(!otr.preferences.paths.contains(prefs::kDownloadDefaultDirectory));
  assert(otr.preferences.paths.contains(prefs::kSaveFileDefaultDirectory));
  StopFollowingOpenerDownloadPreferences(&otr);
  Drain();
}

void RefusesWrongKinds() {
  auto opener = Ordinary();
  auto otr = Private();
  FollowOpenerDownloadPreferences(&opener, &opener);
  FollowOpenerDownloadPreferences(&otr, &otr);
  FollowOpenerDownloadPreferences(nullptr, &opener);
  assert(otr.preferences.writes == 0 && opener.preferences.writes == 0);
  assert(opener.observers.empty() && otr.observers.empty());
}

void OpenerDestroyed() {
  auto otr = Private();
  {
    auto opener = Ordinary();
    FollowOpenerDownloadPreferences(&otr, &opener);
    opener.Destroy();
    // Detached at once: neither profile is observed and no pref callback stays.
    assert(opener.observers.empty() && otr.observers.empty());
    const int writes = otr.preferences.writes;
    opener.preferences.SetBoolean(prefs::kPromptForDownload, true);
    assert(otr.preferences.writes == writes);
  }
  Drain();
  // The posted erase ran; stopping again is harmless.
  StopFollowingOpenerDownloadPreferences(&otr);
  Drain();
}

void PrivateDestroyed() {
  auto opener = Ordinary();
  auto otr = Private();
  FollowOpenerDownloadPreferences(&otr, &opener);
  otr.Destroy();
  const int writes = otr.preferences.writes;
  opener.preferences.SetBoolean(prefs::kPromptForDownload, true);
  assert(otr.preferences.writes == writes && opener.observers.empty());
  Drain();
}

void RelinkSurvivesStaleErase() {
  auto first = Ordinary();
  auto second = Ordinary();
  auto otr = Private();
  first.preferences.booleans[prefs::kPromptForDownload] = true;
  FollowOpenerDownloadPreferences(&otr, &first);
  // Relinking detaches the first link, whose erase is still queued.
  FollowOpenerDownloadPreferences(&otr, &second);
  assert(!Ask(otr));
  Drain();
  second.preferences.SetBoolean(prefs::kPromptForDownload, true);
  assert(Ask(otr));
  first.preferences.SetBoolean(prefs::kPromptForDownload, false);
  assert(Ask(otr));
  StopFollowingOpenerDownloadPreferences(&otr);
  Drain();
}

int main(int argc, char** argv) {
  assert(argc == 2);
  std::map<std::string, void (*)()> cases = {
    {"copies", CopiesNowAndOnChange}, {"managed", ManagedIsLeftAlone},
    {"refuses", RefusesWrongKinds}, {"opener-destroyed", OpenerDestroyed},
    {"private-destroyed", PrivateDestroyed}, {"relink", RelinkSurvivesStaleErase},
  };
  cases.at(argv[1])();
  assert(base::tasks.empty());
}
