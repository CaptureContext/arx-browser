#include "chrome/browser/arx/downloads_bridge.h"

#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/ref_counted.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/run_loop.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/download/download_core_service.h"
#include "chrome/browser/download/download_core_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "components/download/public/common/download_interrupt_reasons.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_item_impl.h"
#include "components/download/public/common/download_task_runner.h"
#include "components/download/public/common/download_url_parameters.h"
#include "content/public/browser/download_item_utils.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/common/referrer.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "url/gurl.h"

namespace arx {
namespace {

struct Snapshot {
  std::string guid, url, path, filename;
  uint64_t page = 0;
  int state = 0, reason = 0;
  int64_t received = 0, total = 0;
  double started = 0;
  bool dangerous = false, missing = false, private_context = false;
};

// DEV-1130: whether Chromium can continue an ordinary transfer from its bytes on disk once a quit
// interrupts it. It asks the server for the rest with If-Range, which needs a strong validator
// (an ETag or Last-Modified), and a server that said Accept-Ranges: none refuses; either way the
// resumed transfer starts over. Transient and Save Page As transfers aren't resumed at all, and
// one a service worker answered always starts over (DownloadItemImpl::ResumeInterruptedDownload).
// A server that sent no Accept-Ranges often takes ranges anyway, so that alone doesn't count.
// The download manager's items are all DownloadItemImpl.
bool ContinuesAfterQuit(const download::DownloadItem& item) {
  if (item.IsTransient() || item.IsSavePackageDownload()) return false;
  if (static_cast<const download::DownloadItemImpl&>(item).fetched_via_service_worker()) return false;
  if (item.GetETag().empty() && item.GetLastModifiedTime().empty()) return false;
  const auto& headers = item.GetResponseHeaders();
  return !headers || !headers->HasHeaderValue("Accept-Ranges", "none");
}

// DEV-966: a transfer, paused or not, that a quit can leave interrupted with its bytes on disk to
// continue next launch: one writing to its intermediate file (the overlay's accessor). Every other
// internal state reads IN_PROGRESS too: one still choosing where to go has nothing to keep, and
// Chromium would ignore or refuse the interruption while one resumes or completes. One with all
// its data is finishing, maybe renaming its file already, and has nothing to resume. A dangerous or
// insecure one waiting for a decision stays on the shutdown's cancel, which deletes its file, as
// Chromium intends; Arx can't pause or resume it either.
bool ContinuesFromDisk(const download::DownloadItem& item) {
  const auto insecure = item.GetInsecureDownloadStatus();
  return item.GetState() == download::DownloadItem::IN_PROGRESS &&
      static_cast<const download::DownloadItemImpl&>(item).IsWritingToIntermediateFile() &&
      !item.AllDataSaved() && !item.IsDangerous() && insecure != download::DownloadItem::InsecureDownloadStatus::BLOCK &&
      insecure != download::DownloadItem::InsecureDownloadStatus::WARN && ContinuesAfterQuit(item);
}

// DEV-966: with ARX_DOWNLOAD_DIAGNOSTICS set (the download resume smoke sets it), a quit and a
// launch say on stderr what they found and did with each transfer, so a resume that fails says
// why. No addresses or file names: the GUID, states, flags and byte counts.
bool DownloadDiagnostics() {
  static const bool enabled = std::getenv("ARX_DOWNLOAD_DIAGNOSTICS") != nullptr;
  return enabled;
}

void DiagnoseItem(const char* event, const download::DownloadItem& item, bool private_context) {
  if (!DownloadDiagnostics()) return;
  std::fprintf(stderr,
      "%s guid=%s private=%d state=%d reason=%d paused=%d writing=%d all_data=%d dangerous=%d "
      "etag=%d last_modified=%d continues=%d can_resume=%d received=%lld total=%lld\n",
      event, item.GetGuid().c_str(), private_context, static_cast<int>(item.GetState()),
      static_cast<int>(item.GetLastReason()), item.IsPaused(),
      static_cast<const download::DownloadItemImpl&>(item).IsWritingToIntermediateFile(),
      item.AllDataSaved(), item.IsDangerous(), !item.GetETag().empty(),
      !item.GetLastModifiedTime().empty(), ContinuesAfterQuit(item), item.CanResume(),
      static_cast<long long>(item.GetReceivedBytes()), static_cast<long long>(item.GetTotalBytes()));
}

class Downloads final : public content::DownloadManager::Observer,
                        public download::DownloadItem::Observer {
 public:
  Downloads(Profile* profile, std::string key, const ArxEngineCallbacks& callbacks)
      : profile_(profile), key_(std::move(key)), callbacks_(callbacks),
        private_(profile->IsOffTheRecord()) {
    manager_ = profile->GetDownloadManager();
    manager_->AddObserver(this);
    auto* service = DownloadCoreServiceFactory::GetForBrowserContext(profile);
    service->InitializeHistory(DownloadCoreService::DownloadHistoryLoadTrigger::kDownloadsPage);
    Enumerate();
    if (manager_->IsManagerInitialized()) OnManagerInitialized();
  }

  ~Downloads() override {
    weak_factory_.InvalidateWeakPtrs();
    for (auto& [item, page] : items_) item->RemoveObserver(this);
    if (manager_) manager_->RemoveObserver(this);
  }

  bool Cancel(const std::string& guid) {
    if (!manager_) return false;
    auto* item = manager_->GetDownloadByGuid(guid);
    if (!item) return false;
    auto weak = weak_factory_.GetWeakPtr();
    if (item->GetState() == download::DownloadItem::IN_PROGRESS) item->Cancel(true);
    if (!weak || !weak->manager_) return true;
    // Completion can race a queued Swift cancel action. Replay the authoritative
    // terminal state instead of making an already-finished transfer an error.
    if (auto* current = weak->manager_->GetDownloadByGuid(guid)) weak->OnDownloadUpdated(current);
    return true;
  }

  // DEV-892: Chromium's own pause and resume. Resuming an interrupted transfer,
  // including one interrupted by quitting, continues from the bytes on disk when
  // the server honours its range request, and starts over when it doesn't.
  bool SetPaused(const std::string& guid, bool paused) {
    if (!manager_) return false;
    auto* item = manager_->GetDownloadByGuid(guid);
    if (!item || item->IsDangerous()) return false;
    const bool in_progress = item->GetState() == download::DownloadItem::IN_PROGRESS;
    auto weak = weak_factory_.GetWeakPtr();
    if (paused) {
      if (!in_progress || item->IsPaused()) return false;
      item->Pause();
    } else {
      const bool interrupted = item->GetState() == download::DownloadItem::INTERRUPTED;
      if (!(in_progress && item->IsPaused()) && !(interrupted && item->CanResume())) return false;
      item->Resume(/*user_resume=*/true);
    }
    if (weak && weak->manager_)
      if (auto* current = weak->manager_->GetDownloadByGuid(guid)) weak->OnDownloadUpdated(current);
    return true;
  }

  // Remove from List: Chromium forgets a finished transfer, as its own
  // downloads page does. The file stays.
  bool Remove(const std::string& guid) {
    if (!manager_) return false;
    auto* item = manager_->GetDownloadByGuid(guid);
    if (!item || item->GetState() == download::DownloadItem::IN_PROGRESS) return false;
    item->Remove();
    return true;
  }

  // ARX_DOWNLOAD_CONTROL_* bits for the item, or 0 when it's unknown.
  uint32_t Control(const std::string& guid) const {
    if (!manager_) return 0;
    auto* item = manager_->GetDownloadByGuid(guid);
    if (!item || item->IsDangerous()) return 0;
    uint32_t bits = 0;
    const auto state = item->GetState();
    if (state == download::DownloadItem::IN_PROGRESS) {
      bits |= item->IsPaused() ? (ARX_DOWNLOAD_CONTROL_PAUSED | ARX_DOWNLOAD_CONTROL_CAN_RESUME)
                               : ARX_DOWNLOAD_CONTROL_CAN_PAUSE;
    } else if (state == download::DownloadItem::INTERRUPTED && item->CanResume()) {
      bits |= ARX_DOWNLOAD_CONTROL_CAN_RESUME;
    }
    return bits;
  }

  uint64_t ActiveCount() const {
    uint64_t count = 0;
    for (const auto& [item, page] : items_)
      if (item->GetState() == download::DownloadItem::IN_PROGRESS) ++count;
    return count;
  }

  // DEV-1130: transfers in progress, paused ones included, that a quit would lose: every one in
  // a private context, whose profile and partial file go with it, and an ordinary one Chromium
  // couldn't continue from its bytes on disk.
  uint64_t LostOnQuitCount() const {
    uint64_t count = 0;
    for (const auto& [item, page] : items_) {
      if (item->GetState() != download::DownloadItem::IN_PROGRESS) continue;
      if (private_ || !ContinuesAfterQuit(*item)) ++count;
    }
    return count;
  }

  void CancelAll() {
    std::vector<std::string> active;
    for (const auto& [item, page] : items_)
      if (item->GetState() == download::DownloadItem::IN_PROGRESS) active.push_back(item->GetGuid());
    auto weak = weak_factory_.GetWeakPtr();
    for (const auto& guid : active) {
      if (!weak) return;
      weak->Cancel(guid);
    }
  }

  // DEV-966: the ordinary transfers a quit can leave interrupted with their bytes, as GUIDs.
  std::vector<std::string> ContinuingFromDisk() const {
    std::vector<std::string> continuing;
    if (private_ || !manager_) return continuing;
    for (const auto& [item, page] : items_)
      if (ContinuesFromDisk(*item)) continuing.push_back(item->GetGuid());
    return continuing;
  }

  content::DownloadManager* manager() const { return manager_; }
  bool is_private() const { return private_; }

  // DEV-966 diagnostics: every transfer this observer knows, under `event`.
  void Diagnose(const char* event) const {
    if (!DownloadDiagnostics()) return;
    if (!manager_) std::fprintf(stderr, "%s observer=detached private=%d\n", event, private_);
    for (const auto& [item, page] : items_) DiagnoseItem(event, *item, private_);
  }
  const std::string& key() const { return key_; }
  bool RetainsProfile() const { return ActiveCount() > 0 || pending_notifications_ > 0; }
  base::WeakPtr<Downloads> GetWeakPtr() { return weak_factory_.GetWeakPtr(); }

  void OnDownloadCreated(content::DownloadManager*, download::DownloadItem* item) override {
    if (!items_.contains(item)) {
      items_[item] = PageIdentifier(content::DownloadItemUtils::GetOriginalWebContents(item));
      item->AddObserver(this);
    }
    OnDownloadUpdated(item);
  }

  void OnDownloadUpdated(download::DownloadItem* item) override {
    const auto insecure = item->GetInsecureDownloadStatus();
    Snapshot value;
    value.guid = item->GetGuid();
    value.url = item->GetOriginalUrl().spec();
    value.path = item->GetTargetFilePath().AsUTF8Unsafe();
    value.filename = item->GetFileNameToReportUser().AsUTF8Unsafe();
    value.page = items_[item];
    value.state = static_cast<int>(item->GetState());
    value.reason = static_cast<int>(item->GetLastReason());
    value.received = item->GetReceivedBytes();
    value.total = item->GetTotalBytes();
    value.started = item->GetStartTime().InSecondsFSinceUnixEpoch();
    value.dangerous = item->IsDangerous() ||
        insecure == download::DownloadItem::InsecureDownloadStatus::BLOCK ||
        insecure == download::DownloadItem::InsecureDownloadStatus::WARN;
    value.missing = item->GetFileExternallyRemoved();
    value.private_context = private_;
    ++pending_notifications_;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&Downloads::Deliver, weak_factory_.GetWeakPtr(), std::move(value)));
  }

  void OnDownloadDestroyed(download::DownloadItem* item) override {
    items_.erase(item);
    DownloadActivityChanged(profile_);
  }

  void OnManagerInitialized() override {
    Enumerate();
    Diagnose("ARX_DOWNLOAD_LOADED");
    ++pending_notifications_;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&Downloads::Initialized, weak_factory_.GetWeakPtr()));
  }

  void ManagerGoingDown(content::DownloadManager*) override {
    for (auto& [item, page] : items_) item->RemoveObserver(this);
    items_.clear();
    manager_ = nullptr;
    DownloadActivityChanged(profile_);
  }

 private:
  void Enumerate() {
    content::DownloadManager::DownloadVector downloads;
    manager_->GetAllDownloads(&downloads);
    for (download::DownloadItem* item : downloads) OnDownloadCreated(manager_, item);
  }

  void Deliver(Snapshot value) {
    auto weak = weak_factory_.GetWeakPtr();
    auto* profile = profile_;
    const auto callbacks = callbacks_;
    const std::string key = key_;
    if (callbacks.download_changed) {
      ArxDownloadSnapshot snapshot = {
        value.guid.c_str(), value.url.c_str(), value.path.c_str(), value.filename.c_str(),
        value.page, value.state, value.reason, value.received, value.total, value.started,
        value.dangerous, value.missing, value.private_context
      };
      callbacks.download_changed(callbacks.context, key.c_str(), &snapshot);
    }
    // The external callback can stop the runtime and delete this observer.
    if (!weak) return;
    --weak->pending_notifications_;
    DownloadActivityChanged(profile);
  }

  void Initialized() {
    auto weak = weak_factory_.GetWeakPtr();
    auto* profile = profile_;
    const auto callbacks = callbacks_;
    const std::string key = key_;
    if (callbacks.downloads_initialized)
      callbacks.downloads_initialized(callbacks.context, key.c_str());
    if (!weak) return;
    --weak->pending_notifications_;
    DownloadActivityChanged(profile);
  }

  Profile* const profile_;
  std::string key_;
  ArxEngineCallbacks callbacks_;
  bool private_;
  uint64_t pending_notifications_ = 0;
  content::DownloadManager* manager_ = nullptr;
  std::map<download::DownloadItem*, uint64_t> items_;
  base::WeakPtrFactory<Downloads> weak_factory_{this};
};

std::map<Profile*, std::unique_ptr<Downloads>>& Observations() {
  static base::NoDestructor<std::map<Profile*, std::unique_ptr<Downloads>>> value;
  return *value;
}

constexpr base::TimeDelta kStartTimeout = base::Seconds(30);
// DEV-966: how long a quit waits for the download sequence to let go of the files it keeps.
constexpr base::TimeDelta kKeptFilesTimeout = base::Seconds(3);
constexpr size_t kMaximumPendingStarts = 16;

constexpr net::NetworkTrafficAnnotationTag kStartAnnotation =
    net::DefineNetworkTrafficAnnotation("arx_automation_download", R"(
      semantics {
        sender: "Arx local automation"
        description:
          "Downloads a file a locally granted assistant asked for, after the "
          "user approved it in Arx."
        trigger: "An explicitly granted assistant starts a download."
        data: "The URL with the profile's cookies."
        destination: WEBSITE
      }
      policy {
        cookies_allowed: YES
        cookies_store: "user"
        setting: "Local assistants (MCP) in Arx Settings."
        policy_exception_justification: "Not implemented."
      })");

constexpr net::NetworkTrafficAnnotationTag kLinkAnnotation =
    net::DefineNetworkTrafficAnnotation("arx_link_download", R"(
      semantics {
        sender: "Arx link menu"
        description: "Downloads the file a link points to."
        trigger: "The user chooses Download Linked File in a link's menu."
        data: "The URL with the profile's cookies and the page's referrer."
        destination: WEBSITE
      }
      policy {
        cookies_allowed: YES
        cookies_store: "user"
        setting: "This feature cannot be disabled by settings."
        policy_exception_justification: "Not implemented."
      })");

// One reply per accepted start. A timed-out entry stays until Chromium answers,
// so an item that arrives after the TIMEOUT reply is cancelled, not kept.
struct PendingStart {
  std::string key;
  ArxEngineCallbacks callbacks;
  bool timed_out = false;
};

std::map<uint64_t, PendingStart>& PendingStarts() {
  static base::NoDestructor<std::map<uint64_t, PendingStart>> value;
  return *value;
}

void ReplyStart(const ArxEngineCallbacks& callbacks, uint64_t request,
                ArxDownloadStartStatus status, std::string guid, int reason) {
  // Posted after the item's own download_changed delivery, so Swift has the item first.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
      base::BindOnce([](ArxEngineCallbacks callbacks, uint64_t request,
                        ArxDownloadStartStatus status, std::string guid, int reason) {
        if (callbacks.download_started)
          callbacks.download_started(callbacks.context, request, status,
                                     guid.empty() ? nullptr : guid.c_str(), reason);
      }, callbacks, request, status, std::move(guid), reason));
}

void StartTimedOut(uint64_t request) {
  auto found = PendingStarts().find(request);
  if (found == PendingStarts().end() || found->second.timed_out) return;
  found->second.timed_out = true;
  ReplyStart(found->second.callbacks, request, ARX_DOWNLOAD_START_TIMEOUT, {}, 0);
}

void Started(uint64_t request, download::DownloadItem* item,
             download::DownloadInterruptReason reason) {
  auto found = PendingStarts().find(request);
  // Stopping the downloads bridge drops every pending start without a reply.
  if (found == PendingStarts().end()) return;
  auto pending = std::move(found->second);
  PendingStarts().erase(found);
  if (pending.timed_out) {
    if (!item) return;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce([](std::string key, std::string guid) { CancelDownload(key, guid); },
                       pending.key, item->GetGuid()));
    return;
  }
  if (item) {
    ReplyStart(pending.callbacks, request, ARX_DOWNLOAD_START_STARTED, item->GetGuid(), 0);
  } else {
    ReplyStart(pending.callbacks, request, ARX_DOWNLOAD_START_FAILED, {}, static_cast<int>(reason));
  }
}

std::vector<base::WeakPtr<Downloads>> DownloadObservers() {
  std::vector<base::WeakPtr<Downloads>> observers;
  for (const auto& [profile, downloads] : Observations())
    observers.push_back(downloads->GetWeakPtr());
  return observers;
}
}

void ObserveDownloads(Profile* profile, const std::string& key, const ArxEngineCallbacks& callbacks) {
  if (!Observations().contains(profile))
    Observations()[profile] = std::make_unique<Downloads>(profile, key, callbacks);
}

void InitializePrivateDownloadPreferences(Profile* profile) {
  if (!profile->IsOffTheRecord()) return;
  // Creating the manager constructs Chrome's download-bubble delegate, which
  // forces an ephemeral OTR prompt preference. Arx owns its Downloads surface;
  // restore inheritance once, before this fresh context can start requests.
  profile->GetDownloadManager();
  profile->GetPrefs()->ClearPref(prefs::kPromptForDownload);
}

namespace {
bool CanStart(Profile* profile, uint64_t request, const GURL& url) {
  return profile && !profile->IsOffTheRecord() && Observations().contains(profile) &&
      url.is_valid() && url.SchemeIsHTTPOrHTTPS() && !url.has_username() &&
      !url.has_password() && !PendingStarts().contains(request) &&
      PendingStarts().size() < kMaximumPendingStarts && profile->GetDownloadManager();
}

void Start(Profile* profile, const std::string& key, uint64_t request,
           std::unique_ptr<download::DownloadUrlParameters> params,
           const ArxEngineCallbacks& callbacks) {
  PendingStarts()[request] = PendingStart{key, callbacks};
  // A link download the user approved: not script-initiated, no login prompt,
  // and a source that keeps Chromium's insecure-download and danger checks.
  params->set_content_initiated(false);
  params->set_do_not_prompt_for_login(true);
  params->set_download_source(download::DownloadSource::CONTEXT_MENU);
  params->set_callback(base::BindOnce(&Started, request));
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(FROM_HERE,
      base::BindOnce(&StartTimedOut, request), kStartTimeout);
  profile->GetDownloadManager()->DownloadUrl(std::move(params));
}
}  // namespace

bool StartDownload(Profile* profile, const std::string& key, uint64_t request,
                   const GURL& url, const ArxEngineCallbacks& callbacks) {
  if (!CanStart(profile, request, url)) return false;
  Start(profile, key, request,
        std::make_unique<download::DownloadUrlParameters>(url, kStartAnnotation), callbacks);
  return true;
}

bool StartLinkDownload(content::RenderFrameHost* source, Profile* profile,
                       const std::string& key, uint64_t request, const GURL& url,
                       const GURL& frame_url, network::mojom::ReferrerPolicy referrer_policy,
                       const std::string& frame_charset, const std::u16string& suggested_name,
                       const ArxEngineCallbacks& callbacks) {
  if (!source || !CanStart(profile, request, url)) return false;
  // Chrome's ExecSaveLinkAs: the link's frame starts it with its own referrer.
  auto params = source->CreateDownloadUrlParameters(url, kLinkAnnotation);
  const auto referrer = content::Referrer::SanitizeForRequest(
      url, content::Referrer(frame_url.GetAsReferrer(), referrer_policy));
  params->set_referrer(referrer.url);
  params->set_referrer_policy(content::Referrer::ReferrerPolicyForUrlRequest(referrer.policy));
  params->set_referrer_encoding(frame_charset);
  params->set_suggested_name(suggested_name);
  Start(profile, key, request, std::move(params), callbacks);
  return true;
}

bool CancelDownload(const std::string& key, const std::string& guid) {
  for (auto observer : DownloadObservers())
    if (observer && observer->key() == key && observer->Cancel(guid)) return true;
  return false;
}

bool SetDownloadPaused(const std::string& key, const std::string& guid, bool paused) {
  for (auto observer : DownloadObservers())
    if (observer && observer->key() == key && observer->SetPaused(guid, paused)) return true;
  return false;
}

bool RemoveDownload(const std::string& key, const std::string& guid) {
  for (auto observer : DownloadObservers())
    if (observer && observer->key() == key && observer->Remove(guid)) return true;
  return false;
}

uint32_t DownloadControl(const std::string& key, const std::string& guid) {
  // A reopened private profile shares its key with the context that keeps an
  // older transfer, so look for the GUID in every context with the key.
  for (auto observer : DownloadObservers())
    if (observer && observer->key() == key)
      if (const uint32_t bits = observer->Control(guid)) return bits;
  return 0;
}

uint64_t ActiveDownloadCount() {
  uint64_t count = 0;
  for (auto observer : DownloadObservers())
    if (observer) count += observer->ActiveCount();
  return count;
}

uint64_t LostOnQuitDownloadCount() {
  uint64_t count = 0;
  for (auto observer : DownloadObservers())
    if (observer) count += observer->LostOnQuitCount();
  return count;
}

void CancelAllDownloads() {
  // Cancel can synchronously notify observers that stop or replace a context.
  // Snapshot weak identities, never iterate the live registry across callbacks.
  for (auto observer : DownloadObservers())
    if (observer) observer->CancelAll();
}

bool DownloadsRetainProfile(Profile* profile) {
  auto found = Observations().find(profile);
  return found != Observations().end() && found->second->RetainsProfile();
}

void StopDownloads(Profile* profile) {
  auto removed = Observations().extract(profile);
}

void StopAllDownloads() {
  PendingStarts().clear();
  std::map<Profile*, std::unique_ptr<Downloads>> removed;
  Observations().swap(removed);
  if (DownloadDiagnostics()) std::fprintf(stderr, "ARX_DOWNLOAD_QUIT observers=%zu\n", removed.size());
  for (const auto& [profile, downloads] : removed) downloads->Diagnose("ARX_DOWNLOAD_QUIT found");
  // DEV-966: this runs only at quit, before Chromium tears the profiles down. Their download
  // managers then cancel every transfer still in progress, paused ones included: the partial
  // file is deleted and the transfer is recorded as cancelled (DownloadManagerImpl::Shutdown).
  // An ordinary one Chromium can continue is kept instead, as a crash would leave it. Pausing it
  // writes its progress to the profile's in-progress download database at once (an
  // interruption alone waits for a timer that never fires during teardown), and interrupting it
  // keeps its bytes on disk and makes the cancel skip it. The next launch reads the paused entry
  // back as interrupted and resumable, and Downloads offers to resume it. Private ones, and ones
  // that would start over anyway (DEV-1130), are cancelled, as the quit confirmation warned; so
  // is every transfer of a single profile torn down while Arx runs (a private window closing,
  // an erased profile), which StopDownloads leaves to Chromium. The observers go first, so the
  // app never hears of it. Each transfer is found again by GUID and checked again after the
  // pause, since another observer's callback may have ended or changed one meanwhile.
  std::vector<std::pair<content::DownloadManager*, std::vector<std::string>>> continuing;
  size_t in_progress = 0;
  for (const auto& [profile, downloads] : removed) {
    in_progress += downloads->ActiveCount();
    if (auto guids = downloads->ContinuingFromDisk(); !guids.empty())
      continuing.emplace_back(downloads->manager(), std::move(guids));
  }
  removed.clear();
  size_t kept = 0;
  for (const auto& [manager, guids] : continuing)
    for (const auto& guid : guids) {
      auto* item = manager->GetDownloadByGuid(guid);
      if (!item || !ContinuesFromDisk(*item)) continue;
      item->Pause();
      item = manager->GetDownloadByGuid(guid);
      if (!item || !ContinuesFromDisk(*item)) continue;
      static_cast<download::DownloadItemImpl*>(item)->DestinationError(
          download::DOWNLOAD_INTERRUPT_REASON_CRASH, item->GetReceivedBytes(), std::nullopt);
      DiagnoseItem("ARX_DOWNLOAD_QUIT kept", *item, false);
      ++kept;
    }
  if (DownloadDiagnostics())
    std::fprintf(stderr, "ARX_DOWNLOAD_QUIT kept=%zu cancelled=%zu\n", kept, in_progress - kept);
  if (!kept) return;

  // The interruption lets go of each file on the download sequence (DownloadFileDetach). That
  // sequence's tasks are skipped once the thread pool shuts down, and a skipped one destroys the
  // still-attached file, which deletes it (BaseFile::~BaseFile). So the quit waits, at most
  // kKeptFilesTimeout, until the sequence reaches a task posted after them. The main loop has
  // ended, so this loop runs only what's queued on the main thread meanwhile.
  // The reply owns the flag it sets: after a timeout it can still arrive once this has returned.
  base::RunLoop run_loop;
  auto released = base::MakeRefCounted<base::RefCountedData<bool>>(false);
  download::GetDownloadTaskRunner()->PostTaskAndReply(
      FROM_HERE, base::DoNothing(),
      base::BindOnce([](scoped_refptr<base::RefCountedData<bool>> released,
                        base::OnceClosure quit) {
        released->data = true;
        std::move(quit).Run();
      }, released, run_loop.QuitClosure()));
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, run_loop.QuitClosure(), kKeptFilesTimeout);
  run_loop.Run();
  if (DownloadDiagnostics())
    std::fprintf(stderr, "ARX_DOWNLOAD_QUIT files=%s\n", released->data ? "released" : "timed-out");
}
}
