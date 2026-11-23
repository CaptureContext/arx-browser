"""Execute the production idle profile release (DEV-880) with deterministic peers."""
import unittest

from Scripts.engine.config import PACKAGE
from Scripts.tests.test_erasure_policy import run_policy


def function(source, signature):
    return signature + source.split(signature, 1)[1].split("\n}\n", 1)[0] + "\n}\n"


class ProfileReleaseNativeTests(unittest.TestCase):
    def test_release_requires_an_unused_loaded_ordinary_profile_and_forgets_it_first(self):
        engine = (PACKAGE / "Native/engine_bridge.mm").read_text()
        policy = (function(engine, "bool OrdinaryProfileInUse(")
                  + function(engine, "bool ReleaseProfile("))
        source = r'''
#include <cassert>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>
struct Profile {
  bool download = false;
  Profile* original = nullptr;
  Profile* GetOriginalProfile() { return original ? original : this; }
};
std::vector<std::string> events;
struct KeepAlive {
  Profile* value; std::string key;
  ~KeepAlive() { events.push_back("keep-alive:" + key); }
  Profile* profile() { return value; }
};
struct Contents { Profile* value; Profile* GetBrowserContext() { return value; } };
struct Page { Contents value; Contents* contents() { return &value; } };
struct Runtime {
  bool running = true;
  std::map<std::string, int> preparing_profiles;
  std::map<std::string, Profile*> private_profiles;
  std::map<Profile*, int> retired_private_profiles;
  std::set<std::string> private_profile_keys, ordinary_profile_keys;
  std::map<std::string, std::unique_ptr<KeepAlive>> profiles;
  std::map<int, std::unique_ptr<Page>> pages;
};
Runtime& State() { static Runtime value; return value; }
void CheckThread() {}
namespace erasure { bool enabled = true; bool Enabled() { return enabled; } }
bool DownloadsRetainProfile(Profile* profile) { return profile->download; }
std::set<std::string> installs, loads, consent, views, requests;
bool PageConsentRetainsProfile(const std::string& key) { return consent.contains(key); }
bool HasExtensionInstallWork(const std::string& key) { return installs.contains(key); }
bool HasExtensionViewWork(const std::string& key) { return views.contains(key); }
bool HasExtensionLoadWork(const std::string& key) { return loads.contains(key); }
bool HasExtensionRequestWork(const std::string& key) { return requests.contains(key); }
void StopDownloads(Profile*) { events.push_back("downloads"); }
void ForgetPasswordSettingsProfile(Profile*) { events.push_back("passwords"); }
void ForgetExtensionProfile(const std::string& key) { events.push_back("extensions:" + key); }
void ClearInitialKeepAlive(Profile*) { events.push_back("first-window"); }
void WatchReleasedProfile(Profile*, const std::string& key) { events.push_back("watch:" + key); }
void KeepSessionOnReload(Profile*) { events.push_back("session"); }
'''
        source += policy
        source += r'''
void Load(Profile* profile, const std::string& key) {
  State().ordinary_profile_keys.insert(key);
  State().profiles[key].reset(new KeepAlive{profile, key});
}

int main() {
  auto& state = State();
  Profile target, other, legacy;
  const std::string key = "11111111-1111-4111-8111-111111111111";
  Load(&target, key);
  Load(&other, "other");

  // Every kind of use refuses, and changes nothing.
  for (auto* work : {&installs, &loads, &consent, &views, &requests}) {
    work->insert(key);
    assert(!ReleaseProfile(key.c_str()));
    work->clear();
  }
  state.preparing_profiles[key] = 1;
  assert(!ReleaseProfile(key.c_str()));
  state.preparing_profiles[key] = 0;
  target.download = true;
  assert(!ReleaseProfile(key.c_str()));
  target.download = false;
  state.pages[1] = std::make_unique<Page>(Page{Contents{&target}});
  assert(!ReleaseProfile(key.c_str()));
  state.pages.clear();
  // DEV-889: a private window it opened, open or still being destroyed.
  Profile opened{false, &target};
  state.private_profiles["private"] = &opened;
  assert(!ReleaseProfile(key.c_str()));
  state.private_profiles.clear();
  state.retired_private_profiles[&opened] = 1;
  assert(!ReleaseProfile(key.c_str()));
  state.retired_private_profiles.clear();
  state.pages[1] = std::make_unique<Page>(Page{Contents{&target}});
  assert(events.empty() && state.profiles.contains(key));

  // Another profile's page and work don't hold this one.
  state.pages[1]->value.value = &other;
  requests.insert("other");
  state.running = false;
  assert(!ReleaseProfile(key.c_str()));
  state.running = true;
  assert(!ReleaseProfile(nullptr));
  assert(ReleaseProfile(key.c_str()));
  // Bridges forget their raw pointers, and Chromium's first-window keep-alive
  // goes, while Arx's own keep-alive still holds the profile; it goes last.
  assert((events == std::vector<std::string>{"downloads", "passwords", "extensions:" + key,
                                             "first-window", "session", "watch:" + key,
                                             "keep-alive:" + key}));
  assert(!state.profiles.contains(key) && state.ordinary_profile_keys.contains(key));
  assert(!ReleaseProfile(key.c_str()));  // Not loaded any more.
  assert(!ReleaseProfile("other"));      // Its request still owes a reply.

  // Without erasure, Default is the startup profile and the private parent.
  events.clear();
  Load(&legacy, "");
  erasure::enabled = false;
  assert(!ReleaseProfile(""));
  erasure::enabled = true;
  assert(ReleaseProfile(""));
  assert(events.back() == "keep-alive:");

  // A private key is never an ordinary profile to release.
  state.private_profile_keys.insert("private");
  state.profiles["private"].reset(new KeepAlive{&other, "private"});
  assert(!ReleaseProfile("private"));
  state.profiles.erase("private");
  return 0;
}
'''
        run_policy(source)

    def test_a_released_profile_stays_loaded_until_chromium_destroys_it(self):
        engine = (PACKAGE / "Native/engine_bridge.mm").read_text()
        start = engine.index("class ReleasedProfile final")
        tracker = engine[start:engine.index("// Chromium gives every new profile", start)]
        policy = (tracker + function(engine, "void WatchReleasedProfile(")
                  + function(engine, "bool ProfileIsLoaded("))
        source = r"""
#include <cassert>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>
struct Profile;
struct ProfileObserver { virtual ~ProfileObserver() = default; virtual void OnProfileWillBeDestroyed(Profile*) {} };
struct Profile { std::vector<ProfileObserver*> observers; std::string path; };
template <typename T> using raw_ptr = T*;
namespace base {
template <typename T> struct NoDestructor {
  T* value = new T; T& operator*() { return *value; } T* operator->() { return value; }
};
template <typename Source, typename Observer> struct ScopedObservation {
  explicit ScopedObservation(Observer* observer) : observer(observer) {}
  ~ScopedObservation() { Reset(); }
  void Observe(Source* value) { source = value; source->observers.push_back(observer); }
  void Reset() {
    if (!source) return;
    std::erase(source->observers, static_cast<ProfileObserver*>(observer));
    source = nullptr;
  }
  Observer* observer; Source* source = nullptr;
};
}
struct FilePath {
  std::string value;
  FilePath AppendASCII(const std::string& name) const { return {value + "/" + name}; }
};
struct Manager {
  std::map<std::string, Profile*> loaded;
  FilePath user_data_dir() const { return {"/root"}; }
  Profile* GetProfileByPath(const FilePath& path) {
    return loaded.contains(path.value) ? loaded[path.value] : nullptr;
  }
};
struct BrowserProcess { Manager manager; Manager* profile_manager() { return &manager; } };
BrowserProcess* g_browser_process = new BrowserProcess;
struct KeepAlive { Profile* value; Profile* profile() { return value; } };
struct Runtime {
  bool running = true;
  std::set<std::string> private_profile_keys;
  std::map<std::string, std::unique_ptr<KeepAlive>> profiles;
};
Runtime& State() { static Runtime value; return value; }
void CheckThread() {}
"""
        source += policy
        source += r"""
void Destroy(Profile& profile) {
  for (auto* observer : std::vector<ProfileObserver*>(profile.observers))
    observer->OnProfileWillBeDestroyed(&profile);
}

int main() {
  Profile work, other;
  const std::string key = "11111111-1111-4111-8111-111111111111";
  State().profiles[key].reset(new KeepAlive{&work});
  assert(ProfileIsLoaded(key.c_str()));
  State().profiles.erase(key);
  assert(!ProfileIsLoaded(key.c_str()));

  // Released: loaded until its destruction, and watched once.
  WatchReleasedProfile(&work, key);
  WatchReleasedProfile(&work, key);
  assert(work.observers.size() == 1);
  WatchReleasedProfile(&other, "other");
  assert(ProfileIsLoaded(key.c_str()) && ProfileIsLoaded("other"));
  Destroy(work);
  assert(work.observers.empty());
  assert(!ProfileIsLoaded(key.c_str()) && ProfileIsLoaded("other"));

  // Chromium's own record counts too: Default and Arx-<key> directories.
  g_browser_process->profile_manager()->loaded["/root/Default"] = &other;
  assert(ProfileIsLoaded(""));
  g_browser_process->profile_manager()->loaded["/root/Arx-" + key] = &work;
  assert(ProfileIsLoaded(key.c_str()));
  State().private_profile_keys.insert(key);
  assert(!ProfileIsLoaded(key.c_str()));
  State().running = false;
  assert(!ProfileIsLoaded("other") && !ProfileIsLoaded(nullptr));
  return 0;
}
"""
        run_policy(source)


if __name__ == "__main__":
    unittest.main()
