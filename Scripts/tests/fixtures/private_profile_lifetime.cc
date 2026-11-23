// Deterministic Chromium doubles. Policy bodies are injected from production by
// test_private_profile_lifetime.py; this file supplies only boundary behavior.
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#define FROM_HERE 0
// Ordinary Run leaves retirement unconfigured. The retirement-enabled loader
// and queue rules have their separate production-policy harness.
namespace erasure {
inline constexpr char kBootstrapProfile[] = "Arx-Bootstrap";
bool Enabled() { return false; }
bool ProfileKeyAllowed(const std::string&) { return true; }
bool PrivateKeyAllowed(const std::string&) { return true; }
void BeforeShutdown() {}
template <typename F> void RegisterProfile(const std::string&, F reply) { reply(true); }
}
struct Profile;
namespace base {
template <typename T> class WeakPtr {
 public:
  T* pointer = nullptr;
  std::weak_ptr<int> alive;
  explicit operator bool() const { return pointer && !alive.expired(); }
  T* operator->() const { assert(bool(*this)); return pointer; }
};
template <typename T> class WeakPtrFactory {
 public:
  explicit WeakPtrFactory(T* pointer) : pointer_(pointer) {}
  WeakPtr<T> GetWeakPtr() { return {pointer_, alive_}; }
  void InvalidateWeakPtrs() { alive_.reset(); }
 private:
  T* pointer_;
  std::shared_ptr<int> alive_ = std::make_shared<int>(0);
};
template <typename T> struct NoDestructor {
  T value;
  T& operator*() { return value; }
};
struct TimeDelta { int seconds = 0; };
constexpr TimeDelta Seconds(int seconds) { return {seconds}; }
struct SingleThreadTaskRunner {
  std::deque<std::function<void()>> tasks;
  // ABI33 start timeouts. Tests run them explicitly, after any queued work.
  std::deque<std::function<void()>> delayed;
  static SingleThreadTaskRunner* GetCurrentDefault() {
    static SingleThreadTaskRunner runner;
    return &runner;
  }
  void PostTask(int, std::function<void()> task) { tasks.push_back(std::move(task)); }
  void PostDelayedTask(int, std::function<void()> task, TimeDelta) { delayed.push_back(std::move(task)); }
};
template <typename F, typename... Args> auto BindOnce(F function, Args... arguments) {
  return [function, arguments = std::make_tuple(std::move(arguments)...)](auto... remaining) mutable {
    std::apply([&](auto&&... bound) {
      function(std::forward<decltype(bound)>(bound)..., remaining...);
    }, std::move(arguments));
  };
}
template <typename T, typename... Args>
auto BindOnce(void (T::*function)(Args...), WeakPtr<T> weak, Args... arguments) {
  return [function, weak, arguments = std::make_tuple(std::move(arguments)...)]() mutable {
    if (weak) std::apply([&](auto&&... values) {
      (weak.operator->()->*function)(std::forward<decltype(values)>(values)...);
    }, std::move(arguments));
  };
}
// DEV-966: the quit's release flag, owned by the reply that sets it.
template <typename T> struct RefCountedData {
  explicit RefCountedData(const T& value) : data(value) {}
  T data;
};
template <typename T, typename... Arguments> std::shared_ptr<T> MakeRefCounted(Arguments&&... arguments) {
  return std::make_shared<T>(std::forward<Arguments>(arguments)...);
}
struct OnceClosure {
  std::function<void()> function;
  OnceClosure(std::function<void()> value) : function(std::move(value)) {}
  void Run() { function(); }
};
// DEV-966: the quit's wait for the download sequence. The loop runs main-thread tasks until a
// quit closure runs; the closures outlive the loop, as Chromium's weak ones do.
inline std::function<void()> DoNothing() { return [] {}; }
struct RunLoop {
  std::shared_ptr<bool> quit = std::make_shared<bool>(false);
  std::function<void()> QuitClosure() { return [quit = std::weak_ptr<bool>(quit)] { if (auto q = quit.lock()) *q = true; }; }
  void Run();
};
struct Uuid {
  bool valid;
  static Uuid ParseLowercase(const std::string& key) { return {!key.empty() && key != "invalid"}; }
  bool is_valid() const { return valid; }
};
}
template <typename T> using scoped_refptr = std::shared_ptr<T>;
void RunNext() {
  auto& tasks = base::SingleThreadTaskRunner::GetCurrentDefault()->tasks;
  assert(!tasks.empty());
  auto task = std::move(tasks.front());
  tasks.pop_front();
  task();
}
// With the main thread idle, the next delayed task (the quit's timeout) runs, as time passes.
void base::RunLoop::Run() {
  auto* runner = base::SingleThreadTaskRunner::GetCurrentDefault();
  while (!*quit) {
    if (!runner->tasks.empty()) {
      RunNext();
      continue;
    }
    assert(!runner->delayed.empty());
    auto task = std::move(runner->delayed.front());
    runner->delayed.pop_front();
    task();
  }
}
void Drain() {
  int limit = 200;
  while (!base::SingleThreadTaskRunner::GetCurrentDefault()->tasks.empty()) {
    assert(--limit > 0);
    RunNext();
  }
}
struct FakePath {
  std::string value;
  std::string AsUTF8Unsafe() const { return value; }
  bool empty() const { return value.empty(); }
  FakePath AppendASCII(const std::string& name) const { return {value + "/" + name}; }
};
struct FakeURL { std::string spec() const { return "http://127.0.0.1/owned-fixture"; } };
struct GURL {
  std::string value;
  bool is_valid() const { return !value.empty(); }
  bool SchemeIsHTTPOrHTTPS() const { return value.starts_with("http://") || value.starts_with("https://"); }
  bool has_username() const { return value.find('@') != std::string::npos; }
  bool has_password() const { return has_username(); }
  GURL GetAsReferrer() const { return *this; }
};
namespace net {
// DEV-1130: what the lost-on-quit count reads from a transfer's response.
struct HttpResponseHeaders {
  bool refuses_ranges = false;
  bool HasHeaderValue(std::string_view name, std::string_view value) const {
    return refuses_ranges && name == "Accept-Ranges" && value == "none";
  }
};
struct NetworkTrafficAnnotationTag { const char* id; };
constexpr NetworkTrafficAnnotationTag DefineNetworkTrafficAnnotation(const char* id, const char*) { return {id}; }
enum class ReferrerPolicy { CLEAR_ON_TRANSITION_FROM_SECURE_TO_INSECURE };
}
namespace network::mojom { enum class ReferrerPolicy { kDefault }; }
struct FakeTime { double InSecondsFSinceUnixEpoch() const { return 1; } };
namespace download {
enum DownloadInterruptReason {
  DOWNLOAD_INTERRUPT_REASON_NONE = 0, DOWNLOAD_INTERRUPT_REASON_NETWORK_FAILED = 2,
  DOWNLOAD_INTERRUPT_REASON_CRASH = 50
};
// DEV-966: interruptions so far, and how many each wait for the download sequence followed.
int interruptions = 0;
std::vector<int> sequence_waits;
class DownloadItem {
 public:
  enum State { IN_PROGRESS, COMPLETE, CANCELLED, INTERRUPTED };
  enum class InsecureDownloadStatus { SAFE, BLOCK, WARN };
  struct Observer {
    virtual ~Observer() = default;
    virtual void OnDownloadUpdated(DownloadItem*) {}
    virtual void OnDownloadDestroyed(DownloadItem*) {}
  };
  std::string guid;
  State state = IN_PROGRESS;
  std::vector<Observer*> observers;
  std::function<void()> on_cancel;
  int cancellations = 0;
  // DEV-966: Chromium's shutdown cancels with user_cancel false.
  int shutdown_cancellations = 0;
  void AddObserver(Observer* observer) { observers.push_back(observer); }
  void RemoveObserver(Observer* observer) { std::erase(observers, observer); }
  void Cancel(bool user) {
    ++(user ? cancellations : shutdown_cancellations);
    state = CANCELLED;
    Notify();
    if (on_cancel) {
      auto callback = on_cancel;
      callback();
    }
  }
  void Notify() {
    for (auto* observer : std::vector<Observer*>(observers))
      if (std::ranges::find(observers, observer) != observers.end()) observer->OnDownloadUpdated(this);
  }
  State GetState() const { return state; }
  const std::string& GetGuid() const { return guid; }
  FakeURL GetOriginalUrl() const { return {}; }
  FakePath GetTargetFilePath() const { return {"/owned/file"}; }
  FakePath GetFileNameToReportUser() const { return {"file"}; }
  int GetLastReason() const { return 0; }
  int64_t GetReceivedBytes() const { return state == COMPLETE ? 42 : 10; }
  int64_t GetTotalBytes() const { return 42; }
  FakeTime GetStartTime() const { return {}; }
  bool dangerous = false;
  bool IsDangerous() const { return dangerous; }
  // DEV-892 pause, resume and removal.
  bool paused = false;
  bool removed = false;
  bool IsPaused() const { return paused; }
  int pauses = 0;
  void Pause() { ++pauses; paused = true; Notify(); }
  void Resume(bool) { paused = false; state = IN_PROGRESS; Notify(); }
  bool CanResume() const { return paused || state == INTERRUPTED; }
  void Remove() { removed = true; }
  bool GetFileExternallyRemoved() const { return false; }
  InsecureDownloadStatus insecure = InsecureDownloadStatus::SAFE;
  InsecureDownloadStatus GetInsecureDownloadStatus() const { return insecure; }
  // DEV-1130: whether a quit would lose the transfer.
  std::string etag;
  std::string last_modified;
  std::shared_ptr<const net::HttpResponseHeaders> headers;
  bool IsTransient() const { return false; }
  bool IsSavePackageDownload() const { return false; }
  const std::string& GetETag() const { return etag; }
  const std::string& GetLastModifiedTime() const { return last_modified; }
  const std::shared_ptr<const net::HttpResponseHeaders>& GetResponseHeaders() const { return headers; }
  bool fetched_via_service_worker() const { return false; }
  // DEV-966: writing to its intermediate file (the overlay's accessor), and an interruption that
  // keeps its bytes. Chromium writes a pause to the in-progress database at once.
  bool writing = true;
  bool IsWritingToIntermediateFile() const { return state == IN_PROGRESS && writing; }
  bool all_data_saved = false;
  bool AllDataSaved() const { return all_data_saved; }
  std::optional<DownloadInterruptReason> interrupted_by;
  int64_t interrupted_at = -1;
  bool paused_when_interrupted = false;
  void DestinationError(DownloadInterruptReason reason, int64_t bytes, std::nullopt_t) {
    assert(IsWritingToIntermediateFile());
    interrupted_by = reason;
    interrupted_at = bytes;
    paused_when_interrupted = paused;
    ++interruptions;
    state = INTERRUPTED;
    Notify();
  }
};
// DEV-966: the download sequence. Its task runs, then its reply is queued on the main thread.
// A stalled sequence holds its replies until the test lets them go, after the quit returned.
bool sequence_stalled = false;
std::vector<std::function<void()>> stalled_replies;
struct DownloadTaskRunner {
  void PostTaskAndReply(int, std::function<void()> task, std::function<void()> reply) {
    sequence_waits.push_back(interruptions);
    if (sequence_stalled) {
      stalled_replies.push_back([task = std::move(task), reply = std::move(reply)] { task(); reply(); });
      return;
    }
    task();
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(0, std::move(reply));
  }
  DownloadTaskRunner* operator->() { return this; }
};
inline DownloadTaskRunner GetDownloadTaskRunner() { return {}; }
// The download manager's items are all DownloadItemImpl; here they're the same class.
using DownloadItemImpl = DownloadItem;
enum class DownloadSource { UNKNOWN, CONTEXT_MENU };
class DownloadUrlParameters {
 public:
  using OnStartedCallback = std::function<void(DownloadItem*, DownloadInterruptReason)>;
  DownloadUrlParameters(const GURL& url, const net::NetworkTrafficAnnotationTag&) : url(url) {}
  void set_content_initiated(bool value) { content_initiated = value; }
  void set_do_not_prompt_for_login(bool value) { do_not_prompt_for_login = value; }
  void set_download_source(DownloadSource value) { source = value; }
  template <typename F> void set_callback(F value) { callback = std::move(value); }
  // DEV-851: a link download's referrer.
  void set_referrer(const GURL& value) { referrer = value; }
  void set_referrer_policy(net::ReferrerPolicy value) { referrer_policy = value; }
  void set_referrer_encoding(const std::string& value) { referrer_encoding = value; }
  void set_suggested_name(const std::u16string& value) { suggested_name = value; }
  GURL url, referrer;
  net::ReferrerPolicy referrer_policy = net::ReferrerPolicy::CLEAR_ON_TRANSITION_FROM_SECURE_TO_INSECURE;
  std::string referrer_encoding;
  std::u16string suggested_name;
  bool content_initiated = true, do_not_prompt_for_login = false;
  DownloadSource source = DownloadSource::UNKNOWN;
  OnStartedCallback callback;
};
}
namespace content {
struct Referrer {
  Referrer(const GURL& url, network::mojom::ReferrerPolicy policy) : url(url), policy(policy) {}
  static Referrer SanitizeForRequest(const GURL&, const Referrer& referrer) { return referrer; }
  static net::ReferrerPolicy ReferrerPolicyForUrlRequest(network::mojom::ReferrerPolicy) {
    return net::ReferrerPolicy::CLEAR_ON_TRANSITION_FROM_SECURE_TO_INSECURE;
  }
  GURL url;
  network::mojom::ReferrerPolicy policy;
};
struct RenderFrameHost {
  std::unique_ptr<download::DownloadUrlParameters> CreateDownloadUrlParameters(
      const GURL& url, const net::NetworkTrafficAnnotationTag& annotation) {
    return std::make_unique<download::DownloadUrlParameters>(url, annotation);
  }
};
struct WebContents {
  Profile* context;
  Profile* GetBrowserContext() { return context; }
};
class DownloadManager {
 public:
  struct Observer {
    virtual ~Observer() = default;
    virtual void OnDownloadCreated(DownloadManager*, download::DownloadItem*) {}
    virtual void OnManagerInitialized() {}
    virtual void ManagerGoingDown(DownloadManager*) {}
  };
  using DownloadVector = std::vector<download::DownloadItem*>;
  std::vector<Observer*> observers;
  std::map<std::string, std::unique_ptr<download::DownloadItem>> items;
  bool initialized = true;
  void AddObserver(Observer* observer) { observers.push_back(observer); }
  void RemoveObserver(Observer* observer) { std::erase(observers, observer); }
  void GetAllDownloads(DownloadVector* values) {
    for (auto& [guid, item] : items) values->push_back(item.get());
  }
  bool IsManagerInitialized() { return initialized; }
  std::vector<std::unique_ptr<download::DownloadUrlParameters>> requested;
  void DownloadUrl(std::unique_ptr<download::DownloadUrlParameters> params) { requested.push_back(std::move(params)); }
  download::DownloadItem* GetDownloadByGuid(const std::string& guid) {
    auto found = items.find(guid);
    return found == items.end() ? nullptr : found->second.get();
  }
  // DEV-966: DownloadManagerImpl::Shutdown's order: observers hear first, then every transfer
  // still in progress is cancelled.
  void Shutdown() {
    for (auto* observer : std::vector<Observer*>(observers)) observer->ManagerGoingDown(this);
    observers.clear();
    for (auto& [guid, item] : items)
      if (item->GetState() == download::DownloadItem::IN_PROGRESS) item->Cancel(false);
  }
  download::DownloadItem* Add(const std::string& guid) {
    auto item = std::make_unique<download::DownloadItem>();
    item->guid = guid;
    auto* pointer = item.get();
    items[guid] = std::move(item);
    for (auto* observer : std::vector<Observer*>(observers))
      observer->OnDownloadCreated(this, pointer);
    return pointer;
  }
};
struct DownloadItemUtils {
  static WebContents* GetOriginalWebContents(download::DownloadItem*) { return nullptr; }
};
}
namespace prefs { constexpr char kPromptForDownload[] = "download.prompt_for_download"; }
std::function<void()> during_prompt_clear;
struct PrefService {
  PrefService* parent = nullptr;
  std::optional<bool> user, managed;
  int clears = 0, writes = 0;
  std::optional<bool> Managed() const {
    return managed ? managed : (parent ? parent->Managed() : std::nullopt);
  }
  bool GetBoolean(const std::string& key) const {
    assert(key == prefs::kPromptForDownload);
    if (auto value = Managed()) return *value;
    if (user) return *user;
    return parent ? parent->GetBoolean(key) : false;
  }
  void SetBoolean(const std::string& key, bool value) {
    assert(key == prefs::kPromptForDownload);
    ++writes;
    user = value;
  }
  void ClearPref(const std::string& key) {
    assert(key == prefs::kPromptForDownload);
    ++clears;
    user.reset();
    if (during_prompt_clear) during_prompt_clear();
  }
};
struct Profile {
  struct OTRProfileID { static int CreateUnique(const char*) { static int next = 1; return next++; } };
  bool private_context = false;
  bool destroyed = false;
  bool manager_created = false;
  PrefService preferences;
  content::DownloadManager downloads;
  std::vector<std::unique_ptr<Profile>> otr_profiles;
  Profile* original_profile = nullptr;
  bool IsOffTheRecord() { return private_context; }
  Profile* GetOriginalProfile() { return original_profile ? original_profile : this; }
  PrefService* GetPrefs() { return &preferences; }
  content::DownloadManager* GetDownloadManager() {
    assert(!destroyed);
    if (!manager_created) {
      manager_created = true;
      // Pinned DownloadBubbleUIControllerDelegate's constructor installs this
      // OTR-only ephemeral override while the manager is being initialized.
      if (private_context) preferences.SetBoolean(prefs::kPromptForDownload, true);
    }
    return &downloads;
  }
  Profile* GetOffTheRecordProfile(int, bool create) {
    assert(create);
    auto profile = std::make_unique<Profile>();
    profile->private_context = true;
    profile->original_profile = this;
    profile->preferences.parent = &preferences;
    auto* pointer = profile.get();
    otr_profiles.push_back(std::move(profile));
    return pointer;
  }
};
struct ProfileDestroyer {
  static void DestroyOTRProfileWhenAppropriate(Profile* profile) {
    assert(!profile->destroyed);
    assert(profile->downloads.observers.empty());
    profile->destroyed = true;
  }
};
// ABI21 runtime hooks are cleared at shutdown; their behaviour has its own tests.
namespace extensions {
struct ExtensionTabUtil {
  struct EmbedderTabs {};
  static void SetEmbedderTabs(EmbedderTabs) {}
  // ABI22 extension windows.
  struct EmbedderWindowList {};
  static void SetEmbedderWindows(EmbedderWindowList) {}
};
}  // namespace extensions
// ABI22 placements and hooks; extension windows have their own tests.
struct ExtensionPlacement {};
struct SessionID {};
inline void SetUnattendedWebAuthentication(bool (*)(void*)) {}
inline void SetUnattendedFederatedSignIn(bool (*)(void*)) {}
struct HttpAuthCoordinator {
  struct EmbedderPromptCancellation {};
  static void SetEmbedderPromptCancellation(EmbedderPromptCancellation) {}
};
struct DownloadCoreService {
  enum class DownloadHistoryLoadTrigger { kDownloadsPage };
  void InitializeHistory(DownloadHistoryLoadTrigger) {}
};
struct DownloadCoreServiceFactory {
  static DownloadCoreService* GetForBrowserContext(Profile*) { static DownloadCoreService service; return &service; }
};
struct ArxDownloadSnapshot {
  const char *guid, *url, *path, *filename;
  uint64_t page;
  int state, reason;
  int64_t received, total;
  double started;
  bool dangerous, missing, private_context;
};
enum ArxDownloadStartStatus {
  ARX_DOWNLOAD_START_STARTED = 0, ARX_DOWNLOAD_START_UNAVAILABLE = 1,
  ARX_DOWNLOAD_START_FAILED = 2, ARX_DOWNLOAD_START_TIMEOUT = 3,
};
enum {
  ARX_DOWNLOAD_CONTROL_PAUSED = 1u << 0,
  ARX_DOWNLOAD_CONTROL_CAN_RESUME = 1u << 1,
  ARX_DOWNLOAD_CONTROL_CAN_PAUSE = 1u << 2,
};
struct ArxEngineCallbacks {
  void* context = nullptr;
  void (*download_started)(void*, uint64_t, ArxDownloadStartStatus, const char*, int) = nullptr;
  void (*download_changed)(void*, const char*, const ArxDownloadSnapshot*) = nullptr;
  void (*downloads_initialized)(void*, const char*) = nullptr;
  void (*profile_ready)(void*, uint64_t, bool) = nullptr;
  void (*stopping)(void*) = nullptr;
};
struct ScopedKeepAlive {};
enum class ProfileKeepAliveOrigin { kAppWindow };
struct ScopedProfileKeepAlive {
  Profile* pointer;
  Profile* profile() { return pointer; }
  static std::unique_ptr<ScopedProfileKeepAlive> TryAcquire(Profile* profile, ProfileKeepAliveOrigin) {
    return std::make_unique<ScopedProfileKeepAlive>(ScopedProfileKeepAlive{profile});
  }
};
struct ProfileManager {
  Profile original;
  std::vector<std::function<void(Profile*)>> pending;
  FakePath user_data_dir() { return {"/owned"}; }
  Profile* GetProfileByPath(FakePath) { return &original; }
  void CreateProfileAsync(FakePath, std::function<void(Profile*)> callback) {
    pending.push_back(std::move(callback));
  }
};
struct BrowserProcess {
  ProfileManager manager;
  ProfileManager* profile_manager() { return &manager; }
} browser_process;
auto* g_browser_process = &browser_process;
struct Page {
  content::WebContents contents_;
  content::WebContents* contents() { return &contents_; }
};
namespace document::testing { struct OwnedCaptureFixture {}; }
// ENGINE_STATE
EngineState& State() { static EngineState state; return state; }
void CheckThread() {}
void StopAllCaptures() {}
void StopPdfs() {}
void StopDevelopers() {}
void StopAutofill() {}
void StopAutofillSettings() {}
void StopNetworkCaptures() {}
void StopPasswords() {}
void StopPasswordSettings() {}
void StopCredentialImport() {}
void StopSiteSettings() {}
void StopProfileData() {}
int site_icon_stops = 0;
void StopSiteIcons() {
  assert(!State().running);
  ++site_icon_stops;
}
void StopInspections() { assert(!State().running); }
void StopFileChoosers() {}
void ShutdownExtensions() {}
void StopPageExternalTargets() { assert(!State().running); }
void CloseAllDevTools() { assert(!State().running); }
uint64_t PageIdentifier(content::WebContents*) { return 0; }
void DownloadActivityChanged(Profile* profile);
bool CancelDownload(const std::string& key, const std::string& guid);
std::set<Profile*> consent_work;
bool HasPageConsentWork(Profile* profile) { return consent_work.contains(profile); }
// DOWNLOADS_IMPLEMENTATION
// ABI45 (DEV-729): the opener link itself has its own tests; record the calls.
std::vector<std::pair<Profile*, Profile*>> follows;
std::vector<Profile*> unfollows;
void FollowOpenerDownloadPreferences(Profile* private_profile, Profile* opener) {
  follows.emplace_back(private_profile, opener);
}
void StopFollowingOpenerDownloadPreferences(Profile* private_profile) {
  unfollows.push_back(private_profile);
}
// DEV-889: starting a private context's split-mode background pages is outside
// this harness; record the calls.
std::vector<Profile*> private_extensions;
void PreparePrivateExtensions(Profile* profile) { private_extensions.push_back(profile); }
// PROFILE_IMPLEMENTATION
// ACTIVITY_IMPLEMENTATION
struct EngineParts {
  virtual ~EngineParts() = default;
  virtual void PostMainMessageLoopRun() = 0;
};
struct TestEngineParts : EngineParts {
// SHUTDOWN_IMPLEMENTATION
};
std::vector<std::tuple<std::string, std::string, int>> delivered;
std::function<void()> during_delivery, during_initialized;
std::vector<bool> prepared;
int initialized = 0;
std::vector<std::tuple<uint64_t, ArxDownloadStartStatus, std::string, int>> starts;
// Keys besides "private" a scenario prepares on purpose.
std::set<std::string> other_initialized_keys;
ArxEngineCallbacks Callbacks() {
  ArxEngineCallbacks callbacks;
  callbacks.download_started = [](void*, uint64_t request, ArxDownloadStartStatus status, const char* guid, int reason) {
    // The started item's own snapshot always arrives first.
    if (status == ARX_DOWNLOAD_START_STARTED)
      assert(std::ranges::any_of(delivered, [&](const auto& record) { return std::get<1>(record) == guid; }));
    starts.emplace_back(request, status, guid ? guid : "", reason);
  };
  callbacks.download_changed = [](void*, const char* key, const ArxDownloadSnapshot* value) {
    if (during_delivery) during_delivery();
    // Exercise borrowed payload/key lifetime after a reentrant stop.
    delivered.emplace_back(key, value->guid, value->state);
  };
  callbacks.downloads_initialized = [](void*, const char* key) {
    if (during_initialized) during_initialized();
    assert(std::string(key) == "private" || other_initialized_keys.contains(key));
    ++initialized;
  };
  callbacks.profile_ready = [](void*, uint64_t, bool success) { prepared.push_back(success); };
  callbacks.stopping = [](void*) { assert(!State().running); };
  return callbacks;
}
Profile* Prepare(const char* key = "private") {
  assert(PreparePrivateProfile(key));
  return State().private_profiles.at(key);
}
bool HasTerminal(const std::string& guid) {
  return std::ranges::any_of(delivered, [&](const auto& record) {
    return std::get<1>(record) == guid && std::get<2>(record) != download::DownloadItem::IN_PROGRESS;
  });
}
void PrivatePromptInheritance() {
  auto& original = browser_process.manager.original;
  original.preferences.user = false;
  int initialization_checks = 0;
  during_prompt_clear = [&] {
    // No page can resolve this context, and observation/request delivery has
    // not started yet. The manager's startup override already exists.
    assert(State().private_profiles.empty() && Observations().empty());
    const auto& created = original.otr_profiles.back();
    assert(created->manager_created && created->preferences.writes == 1);
    ++initialization_checks;
  };
  auto* profile = Prepare();
  during_prompt_clear = {};
  assert(initialization_checks == 1 && profile->preferences.clears == 1);
  assert(!profile->preferences.user.has_value());
  assert(!profile->GetPrefs()->GetBoolean(prefs::kPromptForDownload));
  assert(original.preferences.user == false && original.preferences.clears == 0);
  assert(original.preferences.writes == 0);
  original.preferences.user = true;
  assert(profile->GetPrefs()->GetBoolean(prefs::kPromptForDownload));
  original.preferences.user = false;
  assert(!profile->GetPrefs()->GetBoolean(prefs::kPromptForDownload));

  // A later intentional private preference must survive idempotent prepare and
  // observer replacement. Neither path is private-context initialization.
  profile->GetPrefs()->SetBoolean(prefs::kPromptForDownload, true);
  assert(Prepare() == profile);
  StopDownloads(profile);
  ObserveDownloads(profile, "private", State().callbacks);
  assert(profile->preferences.clears == 1);
  assert(profile->GetPrefs()->GetBoolean(prefs::kPromptForDownload));
  Drain();

  ReleasePrivateProfile("private");
  auto* fresh = Prepare();
  assert(fresh != profile && fresh->preferences.clears == 1);
  assert(!fresh->GetPrefs()->GetBoolean(prefs::kPromptForDownload));
  Drain();
}
void PrivatePromptEnabled() {
  auto& original = browser_process.manager.original;
  original.preferences.user = true;
  auto* profile = Prepare();
  assert(profile->GetPrefs()->GetBoolean(prefs::kPromptForDownload));
  assert(!profile->preferences.user.has_value());
  assert(original.preferences.user == true && original.preferences.clears == 0);
  Drain();
}
void PrivatePromptManaged() {
  auto& original = browser_process.manager.original;
  original.preferences.user = false;
  original.preferences.managed = true;
  auto* profile = Prepare();
  assert(profile->GetPrefs()->GetBoolean(prefs::kPromptForDownload));
  assert(!profile->preferences.user.has_value());
  assert(original.preferences.managed == true && original.preferences.clears == 0);
  original.preferences.managed = false;
  assert(!profile->GetPrefs()->GetBoolean(prefs::kPromptForDownload));
  Drain();
}
void OrdinaryPromptUnchanged() {
  auto& original = browser_process.manager.original;
  original.preferences.user = true;
  InitializePrivateDownloadPreferences(&original);
  assert(!original.manager_created && original.preferences.clears == 0);
  ObserveDownloads(&original, "ordinary", {});
  assert(original.manager_created && original.preferences.user == true);
  assert(original.preferences.clears == 0 && original.preferences.writes == 0);
  Drain();
}

void Reopen() {
  auto* old = Prepare();
  Drain();
  ReleasePrivateProfile("private");
  assert(State().private_profiles.empty());
  assert(State().retired_private_profiles.contains(old));
  auto* current = Prepare();
  assert(current != old && !old->destroyed);
  Drain();
  assert(old->destroyed && !current->destroyed);
  assert(State().private_profiles.at("private") == current);
}
void Transfers() {
  auto* old = Prepare();
  auto* first = old->downloads.Add("old-transfer");
  Drain();
  ReleasePrivateProfile("private");
  auto* current = Prepare();
  auto* second = current->downloads.Add("new-transfer");
  Drain();
  assert(ActiveDownloadCount() == 2 && !old->destroyed);
  // DEV-892: both contexts share the key; each transfer still reports its own controls.
  assert(DownloadControl("private", "old-transfer") == ARX_DOWNLOAD_CONTROL_CAN_PAUSE);
  assert(DownloadControl("private", "new-transfer") == ARX_DOWNLOAD_CONTROL_CAN_PAUSE);
  assert(CancelDownload("private", "old-transfer"));
  assert(first->cancellations == 1 && second->cancellations == 0);
  assert(!old->destroyed);
  Drain();
  assert(HasTerminal("old-transfer") && old->destroyed && !current->destroyed);
  assert(ActiveDownloadCount() == 1);
  assert(!CancelDownload("other", "new-transfer"));
  assert(CancelDownload("private", "new-transfer"));
  Drain();
  assert(HasTerminal("new-transfer") && !current->destroyed);
}
void Delivery() {
  auto* profile = Prepare();
  auto* item = profile->downloads.Add("before-retirement");
  Drain();
  item->state = download::DownloadItem::COMPLETE;
  item->Notify();
  ReleasePrivateProfile("private");
  assert(!profile->destroyed);
  RunNext();
  assert(HasTerminal(item->guid) && !profile->destroyed);
  Drain();
  assert(profile->destroyed);

  profile = Prepare();
  item = profile->downloads.Add("after-retirement-queued");
  Drain();
  item->state = download::DownloadItem::COMPLETE;
  ReleasePrivateProfile("private");
  item->Notify();
  RunNext(); // Retirement must see the newly queued notification.
  assert(!profile->destroyed && !HasTerminal(item->guid));
  RunNext();
  assert(HasTerminal(item->guid) && !profile->destroyed);
  Drain();
  assert(profile->destroyed);
}
void Generations() {
  auto* first = Prepare();
  Drain();
  ReleasePrivateProfile("private");
  auto* second = Prepare();
  ReleasePrivateProfile("private");
  auto* third = Prepare();
  assert(State().retired_private_profiles.size() == 2);
  Drain();
  assert(first->destroyed && second->destroyed && !third->destroyed);

  ReleasePrivateProfile("private");
  auto& retirement = State().retired_private_profiles.at(third);
  // Simulate the same address representing a later retirement before an old
  // queued closure runs. Only the monotonically allocated token distinguishes it.
  retirement = {State().next_private_retirement++};
  RunNext();
  assert(!third->destroyed && !retirement.cleanup_posted);
  DownloadActivityChanged(third);
  Drain();
  assert(third->destroyed);
}
void LivePage() {
  auto* profile = Prepare();
  Drain();
  State().pages.emplace(1, std::make_unique<Page>(Page{{profile}}));
  ReleasePrivateProfile("private");
  assert(State().private_profiles.at("private") == profile);
  assert(State().retired_private_profiles.empty());
  State().pages.clear();
  ReleasePrivateProfile("private");
  Drain();
  assert(profile->destroyed);
}
void StorageKind() {
  auto* profile = Prepare();
  Drain();
  PrepareProfile("private", 1);
  assert(prepared == std::vector<bool>{false});
  ReleasePrivateProfile("private");
  PrepareProfile("private", 2);
  Drain();
  assert(profile->destroyed);
  PrepareProfile("private", 3);
  assert(prepared == std::vector<bool>({false, false, false}));
  assert(browser_process.manager.pending.empty());
  PrepareProfile("ordinary", 4);
  assert(browser_process.manager.pending.size() == 1);
  assert(!PreparePrivateProfile("ordinary"));
  auto callback = std::move(browser_process.manager.pending.front());
  browser_process.manager.pending.clear();
  callback(&browser_process.manager.original);
  assert(prepared.back() && !PreparePrivateProfile("ordinary"));
  // Shutdown invalidates an outstanding asynchronous ordinary completion too.
  PrepareProfile("pending", 5);
  State().running = false;
  auto count = prepared.size();
  browser_process.manager.pending.front()(&browser_process.manager.original);
  assert(prepared.size() == count && !State().profiles.contains("pending"));
}
void Opener() {
  other_initialized_keys = {"opener", "unlinked", "plain"};
  auto& original = browser_process.manager.original;
  static Profile opener;
  PrepareProfile("opener", 1);
  auto callback = std::move(browser_process.manager.pending.front());
  browser_process.manager.pending.clear();
  callback(&opener);
  assert(prepared.back() && State().profiles.contains("opener"));
  // A prepared ordinary opener links the fresh private context to it, and the
  // context is the opener's own off-the-record child (DEV-889).
  assert(PreparePrivateProfileFor("private", "opener"));
  auto* profile = State().private_profiles.at("private");
  assert(profile->GetOriginalProfile() == &opener);
  assert(follows == (std::vector<std::pair<Profile*, Profile*>>{{profile, &opener}}));
  // Asking again for the same private key links it again, without a new context.
  assert(PreparePrivateProfileFor("private", "opener"));
  assert(State().private_profiles.at("private") == profile && follows.size() == 2);
  // An opener that isn't prepared follows nothing, and the context is the
  // bootstrap profile's; a private opener is refused.
  assert(PreparePrivateProfileFor("unlinked", "missing") && follows.size() == 2);
  assert(State().private_profiles.at("unlinked")->GetOriginalProfile() == &original);
  assert(!PreparePrivateProfileFor("refused", "private"));
  assert(!PreparePrivateProfileFor("same", "same"));
  assert(!State().private_profiles.contains("refused") && !State().private_profiles.contains("same"));
  // The ABI3 entry is the opener-less one.
  assert(PreparePrivateProfile("plain") && follows.size() == 2);
  Drain();
  ReleasePrivateProfile("private");
  assert(unfollows == std::vector<Profile*>{profile});
  Drain();
  assert(profile->destroyed);
}
void CancelAll() {
  auto* first = Prepare();
  auto* a = first->downloads.Add("first");
  ReleasePrivateProfile("private");
  auto* second = Prepare();
  auto* b = second->downloads.Add("second");
  Drain();
  // Map order is pointer order; whichever observer runs first removes both and
  // installs a replacement. Cancel All must neither use stale iterators nor
  // silently cancel transfers added reentrantly after its initial snapshot.
  auto replace = [&] {
    StopAllDownloads();
    ObserveDownloads(second, "private", State().callbacks);
    second->downloads.Add("replacement");
  };
  a->on_cancel = replace;
  b->on_cancel = replace;
  CancelAllDownloads();
  assert(a->cancellations + b->cancellations == 1);
  assert(second->downloads.GetDownloadByGuid("replacement")->cancellations == 0);
  Drain();
}
void CancelGuid() {
  auto* first = Prepare();
  auto* a = first->downloads.Add("old");
  ReleasePrivateProfile("private");
  auto* second = Prepare();
  auto* b = second->downloads.Add("new");
  Drain();
  a->on_cancel = [&] { StopDownloads(first); };
  assert(CancelDownload("private", "old"));
  assert(b->cancellations == 0);
  assert(CancelDownload("private", "new"));
  Drain();
}
// DEV-892: pause and resume a transfer, report its control bits, and only
// forget a finished one.
void PauseResume() {
  auto* profile = Prepare();
  auto* item = profile->downloads.Add("paused");
  Drain();
  assert(DownloadControl("private", "paused") == ARX_DOWNLOAD_CONTROL_CAN_PAUSE);
  assert(SetDownloadPaused("private", "paused", true));
  assert(!SetDownloadPaused("private", "paused", true));
  assert(DownloadControl("private", "paused") == (ARX_DOWNLOAD_CONTROL_PAUSED | ARX_DOWNLOAD_CONTROL_CAN_RESUME));
  assert(!RemoveDownload("private", "paused"));
  assert(SetDownloadPaused("private", "paused", false));
  assert(!item->IsPaused());
  item->state = download::DownloadItem::INTERRUPTED;
  assert(DownloadControl("private", "paused") == ARX_DOWNLOAD_CONTROL_CAN_RESUME);
  assert(SetDownloadPaused("private", "paused", false));
  assert(item->GetState() == download::DownloadItem::IN_PROGRESS);
  item->state = download::DownloadItem::COMPLETE;
  assert(DownloadControl("private", "paused") == 0);
  assert(!SetDownloadPaused("private", "paused", true));
  assert(RemoveDownload("private", "paused") && item->removed);
  assert(DownloadControl("private", "missing") == 0);
  Drain();
}
// DEV-1130: a quit loses every private transfer in progress, paused ones too, and an ordinary one
// Chromium couldn't continue: no ETag or Last-Modified, or a server refusing ranges. A finished
// one never counts, and an ordinary one with a validator and no refusal does neither.
void LostOnQuit() {
  auto& original = browser_process.manager.original;
  other_initialized_keys = {""};
  ObserveDownloads(&original, "", State().callbacks);
  Drain();
  original.downloads.Add("tagged")->etag = "\"v1\"";
  auto* dated = original.downloads.Add("dated-paused");
  dated->last_modified = "Mon, 16 Nov 2026 10:00:00 GMT";
  dated->paused = true;
  original.downloads.Add("unvalidated");
  auto* refusing = original.downloads.Add("refusing-ranges");
  refusing->etag = "\"v2\"";
  auto headers = std::make_shared<net::HttpResponseHeaders>();
  headers->refuses_ranges = true;
  refusing->headers = headers;
  auto* finished = original.downloads.Add("finished");
  finished->state = download::DownloadItem::COMPLETE;
  Drain();
  assert(ActiveDownloadCount() == 4);
  assert(LostOnQuitDownloadCount() == 2);

  auto* profile = Prepare();
  profile->downloads.Add("private")->etag = "\"v3\"";
  Drain();
  assert(LostOnQuitDownloadCount() == 3);
  Drain();
}
// DEV-966: a quit (StopAllDownloads, before Chromium tears the profiles down) leaves an ordinary
// transfer Chromium can continue, paused or not, interrupted with its bytes, before the manager's
// shutdown would cancel it; history records the interruption, so Downloads offers to resume it
// next launch, and the app hears nothing meanwhile. One that would start over, one with no
// partial file yet, one with all its data (finishing), a dangerous or insecure one waiting for a
// decision, a finished one and a private one are left to the shutdown's cancel.
void QuitInterrupts() {
  auto& original = browser_process.manager.original;
  other_initialized_keys = {""};
  ObserveDownloads(&original, "", State().callbacks);
  Drain();
  auto* tagged = original.downloads.Add("tagged");
  tagged->etag = "\"v1\"";
  auto* paused = original.downloads.Add("dated-paused");
  paused->last_modified = "Mon, 16 Nov 2026 10:00:00 GMT";
  paused->paused = true;
  auto* unvalidated = original.downloads.Add("unvalidated");
  auto* choosing = original.downloads.Add("choosing-target");
  choosing->etag = "\"v2\"";
  choosing->writing = false;
  auto* finishing = original.downloads.Add("finishing");
  finishing->etag = "\"v7\"";
  finishing->all_data_saved = true;
  auto* dangerous = original.downloads.Add("dangerous");
  dangerous->etag = "\"v5\"";
  dangerous->dangerous = true;
  auto* insecure = original.downloads.Add("insecure");
  insecure->etag = "\"v6\"";
  insecure->insecure = download::DownloadItem::InsecureDownloadStatus::WARN;
  auto* finished = original.downloads.Add("finished");
  finished->etag = "\"v3\"";
  finished->state = download::DownloadItem::COMPLETE;
  auto* profile = Prepare();
  auto* secret = profile->downloads.Add("private");
  secret->etag = "\"v4\"";
  Drain();
  const auto delivered_before = delivered.size();

  StopAllDownloads();
  // The quit waited once, after both interruptions, for the sequence to let go of their files.
  assert(download::sequence_waits == std::vector<int>{2});
  original.downloads.Shutdown();
  profile->downloads.Shutdown();
  for (auto* item : {tagged, paused}) {
    assert(item->interrupted_by == download::DOWNLOAD_INTERRUPT_REASON_CRASH);
    assert(item->interrupted_at == item->GetReceivedBytes());
    // Paused first, so its progress reached the database before the interruption.
    assert(item->paused_when_interrupted);
    assert(item->GetState() == download::DownloadItem::INTERRUPTED);
    assert(item->shutdown_cancellations == 0 && item->cancellations == 0);
    // Arx's observer let go first, so the app hears nothing during the quit.
    assert(item->observers.empty());
  }
  assert(tagged->pauses == 1);
  for (auto* item : {unvalidated, choosing, finishing, dangerous, insecure, secret}) {
    assert(!item->interrupted_by && item->pauses == 0);
    assert(item->GetState() == download::DownloadItem::CANCELLED);
    assert(item->shutdown_cancellations == 1);
  }
  assert(!finished->interrupted_by && finished->GetState() == download::DownloadItem::COMPLETE);
  Drain();
  assert(delivered.size() == delivered_before);
}
// DEV-966: a download sequence slower than the quit's wait: the quit stops waiting, and the late
// reply, after the quit returned, touches nothing the quit owned.
void QuitTimesOut() {
  auto& original = browser_process.manager.original;
  other_initialized_keys = {""};
  ObserveDownloads(&original, "", State().callbacks);
  Drain();
  auto* tagged = original.downloads.Add("tagged");
  tagged->etag = "\"v1\"";
  Drain();

  download::sequence_stalled = true;
  StopAllDownloads();
  assert(tagged->interrupted_by == download::DOWNLOAD_INTERRUPT_REASON_CRASH);
  assert(download::stalled_replies.size() == 1);
  // Other stack frames reuse the quit's before the reply arrives.
  volatile char overwrite[256];
  for (auto& byte : overwrite) byte = 0x5a;
  for (auto& reply : download::stalled_replies) reply();
  download::stalled_replies.clear();
  download::sequence_stalled = false;
  Drain();
}
// DEV-966: a profile torn down while Arx runs (a private window closing, an erased profile) has
// every transfer cancelled, ones Chromium could continue included: only a quit keeps them.
void TeardownCancels() {
  auto& original = browser_process.manager.original;
  other_initialized_keys = {""};
  ObserveDownloads(&original, "", State().callbacks);
  auto* profile = Prepare();
  Drain();
  auto* ordinary = original.downloads.Add("tagged");
  ordinary->etag = "\"v1\"";
  auto* secret = profile->downloads.Add("private");
  secret->etag = "\"v2\"";
  Drain();

  StopDownloads(profile);
  profile->downloads.Shutdown();
  original.downloads.Shutdown();
  // Nothing was kept, so no quit waited; the observer the manager let go of keeps nothing either.
  StopAllDownloads();
  assert(download::sequence_waits.empty());
  for (auto* item : {ordinary, secret}) {
    assert(!item->interrupted_by);
    assert(item->GetState() == download::DownloadItem::CANCELLED);
    assert(item->shutdown_cancellations == 1);
  }
  Drain();
}
void ReentrantDelivery() {
  auto* profile = Prepare();
  Drain();
  profile->downloads.Add("borrowed-payload");
  during_delivery = [] { StopAllDownloads(); };
  Drain();
  assert(!delivered.empty() && std::get<0>(delivered.back()) == "private");
  during_delivery = {};
  ObserveDownloads(profile, "private", State().callbacks);
  during_initialized = [] { StopAllDownloads(); };
  Drain();
  assert(initialized == 2);
}
void Shutdown() {
  auto* profile = Prepare();
  auto* item = profile->downloads.Add("pending");
  ReleasePrivateProfile("private");
  auto* other = Prepare();
  Drain();
  ReleasePrivateProfile("private"); // Queue retirement of the empty context.
  item->Notify(); // Queue an active snapshot behind that retirement.
  const auto delivered_before = delivered.size();
  const auto initialized_before = initialized;
  assert(!State().retired_private_profiles.empty());
  TestEngineParts parts;
  parts.PostMainMessageLoopRun();
  assert(site_icon_stops == 1);
  assert(Observations().empty() && State().retired_private_profiles.empty());
  assert(State().private_profiles.empty() && State().private_profile_keys.empty());
  assert(State().ordinary_profile_keys.empty());
  Drain();
  assert(delivered.size() == delivered_before && initialized == initialized_before);
  assert(!profile->destroyed && !other->destroyed); // Chromium owns final teardown.
}

void PendingConsentRetainsPrivateProfile() {
  PreparePrivateProfile("private");
  auto* profile = State().private_profiles.at("private");
  consent_work.insert(profile);
  ReleasePrivateProfile("private");
  Drain();
  assert(!profile->destroyed);
  consent_work.erase(profile);
  DownloadActivityChanged(profile);
  Drain();
  assert(profile->destroyed);
}

// ABI33 start_download: replies once, after the item's delivery; a late item after a timeout is cancelled.
void StartDownloads() {
  auto& original = browser_process.manager.original;
  // Other scenarios own initialization delivery; this one is about starts.
  original.downloads.initialized = false;
  ObserveDownloads(&original, "", State().callbacks);
  Drain();
  auto* manager = original.GetDownloadManager();
  auto& runner = *base::SingleThreadTaskRunner::GetCurrentDefault();

  // Private contexts, bad URLs and duplicate requests are refused synchronously.
  auto* profile = Prepare();
  assert(!StartDownload(profile, "private", 1, GURL{"https://example.com/a"}, State().callbacks));
  assert(!StartDownload(&original, "", 1, GURL{"file:///etc/hosts"}, State().callbacks));
  assert(!StartDownload(&original, "", 1, GURL{"https://user@example.com/a"}, State().callbacks));
  assert(StartDownload(&original, "", 1, GURL{"https://example.com/a"}, State().callbacks));
  assert(!StartDownload(&original, "", 1, GURL{"https://example.com/a"}, State().callbacks));
  assert(manager->requested.size() == 1 && profile->downloads.requested.empty());
  auto& params = *manager->requested[0];
  assert(!params.content_initiated && params.do_not_prompt_for_login);
  assert(params.source == download::DownloadSource::CONTEXT_MENU);

  // Chromium creates the item, then answers the request.
  auto* item = manager->Add("started-guid");
  params.callback(item, download::DOWNLOAD_INTERRUPT_REASON_NONE);
  Drain();
  assert(starts.size() == 1 && std::get<0>(starts[0]) == 1);
  assert(std::get<1>(starts[0]) == ARX_DOWNLOAD_START_STARTED && std::get<2>(starts[0]) == "started-guid");
  // A timeout after the reply does nothing.
  runner.delayed.front()();
  runner.delayed.pop_front();
  Drain();
  assert(starts.size() == 1 && item->cancellations == 0);

  // A refused request has no item and reports Chromium's reason.
  assert(StartDownload(&original, "", 2, GURL{"https://example.com/b"}, State().callbacks));
  manager->requested.back()->callback(nullptr, download::DOWNLOAD_INTERRUPT_REASON_NETWORK_FAILED);
  Drain();
  assert(std::get<1>(starts.back()) == ARX_DOWNLOAD_START_FAILED && std::get<3>(starts.back()) == 2);
  runner.delayed.clear();

  // A timed-out start answers TIMEOUT once; its late item is cancelled, not kept.
  assert(StartDownload(&original, "", 3, GURL{"https://example.com/c"}, State().callbacks));
  auto late = std::move(manager->requested.back()->callback);
  runner.delayed.front()();
  runner.delayed.pop_front();
  Drain();
  assert(std::get<0>(starts.back()) == 3 && std::get<1>(starts.back()) == ARX_DOWNLOAD_START_TIMEOUT);
  const auto replies = starts.size();
  auto* stray = manager->Add("late-guid");
  late(stray, download::DOWNLOAD_INTERRUPT_REASON_NONE);
  Drain();
  assert(starts.size() == replies && stray->cancellations == 1);

  // Stopping drops pending starts without replies.
  assert(StartDownload(&original, "", 4, GURL{"https://example.com/d"}, State().callbacks));
  auto dropped = std::move(manager->requested.back()->callback);
  StopAllDownloads();
  dropped(manager->Add("dropped-guid"), download::DOWNLOAD_INTERRUPT_REASON_NONE);
  Drain();
  assert(starts.size() == replies);
  runner.delayed.clear();
}

int main(int argc, char** argv) {
  assert(argc == 2);
  State().running = true;
  State().callbacks = Callbacks();
  std::map<std::string, void (*)()> cases = {
    {"consent", PendingConsentRetainsPrivateProfile}, {"reopen", Reopen}, {"transfers", Transfers}, {"delivery", Delivery},
    {"generations", Generations}, {"live-page", LivePage}, {"storage-kind", StorageKind},
    {"cancel-all", CancelAll}, {"cancel-guid", CancelGuid}, {"pause-resume", PauseResume},
    {"reentrant-delivery", ReentrantDelivery}, {"shutdown", Shutdown},
    {"prompt-inheritance", PrivatePromptInheritance}, {"prompt-enabled", PrivatePromptEnabled},
    {"prompt-managed", PrivatePromptManaged}, {"prompt-ordinary", OrdinaryPromptUnchanged},
    {"start-downloads", StartDownloads}, {"opener", Opener}, {"lost-on-quit", LostOnQuit},
    {"quit-interrupts", QuitInterrupts}, {"teardown-cancels", TeardownCancels},
    {"quit-times-out", QuitTimesOut}
  };
  cases.at(argv[1])();
  State().running = false;
  StopAllDownloads();
  Drain();
}
