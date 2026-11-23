#include "chrome/browser/arx/webstore_install_bridge.h"

#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/escape.h"
#include "base/task/sequenced_task_runner.h"
#include "base/timer/timer.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "chrome/browser/arx/extensions_bridge.h"
#include "chrome/browser/profiles/profile.h"
#include "components/crx_file/id_util.h"
#include "components/version_info/version_info.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/common/extension.h"
#include "extensions/common/mojom/manifest.mojom-shared.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/api/webstore_private/webstore_private_api.h"
#include "net/base/load_flags.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/fetch_api.mojom.h"
#include "url/gurl.h"
#include "url/url_constants.h"

namespace arx {
namespace {
using Result = extensions::api::webstore_private::Result;
using Reply = extensions::WebstorePrivateApi::EmbedderInstallReply;

constexpr size_t kMaximumCRXBytes = 32 * 1024 * 1024;
constexpr size_t kMaximumPendingRequests = 4;
constexpr char kStoreDownloadURL[] = "https://clients2.google.com/service/update2/crx";
// The source name the review sheet shows for a store package.
constexpr char kStoreSourceName[] = "Chrome Web Store";

constexpr net::NetworkTrafficAnnotationTag kWebstoreAnnotation =
    net::DefineNetworkTrafficAnnotation("arx_webstore_install", R"(
      semantics {
        sender: "Arx extensions"
        description:
          "Downloads the package of a Chrome Web Store item the user chose to "
          "add, so Arx can verify it and show it for review before installing."
        trigger: "Add to Chrome on chromewebstore.google.com, accepted by Arx."
        data: "The item's ID and the browser's Chromium version. No cookies."
        destination: GOOGLE_OWNED_SERVICE
      }
      policy {
        cookies_allowed: NO
        setting: "Extensions can be turned off per profile in Arx Settings."
        policy_exception_justification: "Not implemented."
      })");

class Store final {
 public:
  void Configure(const ArxEngineCallbacks& callbacks, bool enabled,
                 const std::string& fixture_origin) {
    callbacks_ = callbacks;
    fixture_origin_ = fixture_origin;
    enabled_ = enabled;
    if (!enabled) return;
    extensions::WebstorePrivateApi::SetEmbedderInstallHandler(base::BindRepeating(
        [](base::WeakPtr<Store> owner, content::WebContents* contents,
           const std::string& id, Reply reply) {
          if (owner) owner->Requested(contents, id, std::move(reply));
          else std::move(reply).Run(Result::kUserCancelled, kCancelled);
        }, weak_factory_.GetWeakPtr()));
  }

  void Install(Profile* profile, const std::string& key, uint64_t request,
               uint64_t revision, uint64_t token) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    auto found = pending_.find(token);
    if (found == pending_.end() || found->second->started || found->second->key != key ||
        !request || !profile || found->second->profile.get() != profile ||
        !ExtensionProfileIsCurrent(profile, key)) {
      ReplyExtensionRequest(request, key, ARX_EXTENSION_STALE);
      return;
    }
    auto& item = *found->second;
    item.started = true;
    item.request = request;
    item.revision = revision;
    item.timer.Stop();
    item.loader = Download(profile, item.id,
        base::BindOnce(&Store::Downloaded, weak_factory_.GetWeakPtr(), token));
  }

  void Decline(uint64_t token) {
    auto found = pending_.find(token);
    if (found == pending_.end() || found->second->started) return;
    Finish(token, Result::kUserCancelled, kCancelled);
  }

  // ABI45 (DEV-776). Downloads the store's current package for an installed
  // store extension and hands it to the verified update path. No store page is
  // waiting, so the outcome goes only to extensions_completed.
  void Update(Profile* profile, const std::string& key, uint64_t request, uint64_t revision,
              const std::string& id) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!enabled_ || !request || !profile || profile->IsOffTheRecord()) {
      ReplyExtensionRequest(request, key, ARX_EXTENSION_UNAVAILABLE);
      return;
    }
    if (!ExtensionProfileIsCurrent(profile, key)) {
      ReplyExtensionRequest(request, key, ARX_EXTENSION_STALE);
      return;
    }
    const auto* installed = crx_file::id_util::IdIsValid(id)
        ? extensions::ExtensionRegistry::Get(profile)->GetInstalledExtension(id) : nullptr;
    if (!installed || !installed->from_webstore() ||
        installed->location() != extensions::mojom::ManifestLocation::kInternal) {
      ReplyExtensionRequest(request, key, ARX_EXTENSION_INVALID_REQUEST);
      return;
    }
    StartDownload(profile, key, request, revision, id, /*install=*/false);
  }

  // ABI47 (DEV-845). A new install of a store item by ID, with no store page
  // and no token: the same download as an update, then the verified new-install
  // path. The outcome goes only to extensions_completed.
  void InstallByID(Profile* profile, const std::string& key, uint64_t request,
                   uint64_t revision, const std::string& id) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!enabled_ || !request || !profile || profile->IsOffTheRecord()) {
      ReplyExtensionRequest(request, key, ARX_EXTENSION_UNAVAILABLE);
      return;
    }
    if (!ExtensionProfileIsCurrent(profile, key)) {
      ReplyExtensionRequest(request, key, ARX_EXTENSION_STALE);
      return;
    }
    if (!crx_file::id_util::IdIsValid(id) ||
        extensions::ExtensionRegistry::Get(profile)->GetInstalledExtension(id)) {
      ReplyExtensionRequest(request, key, ARX_EXTENSION_INVALID_REQUEST);
      return;
    }
    StartDownload(profile, key, request, revision, id, /*install=*/true);
  }

  bool CancelDownload(uint64_t request) {
    if (auto update = updates_.find(request); update != updates_.end()) {
      const auto key = update->second->key;
      updates_.erase(update);
      ReplyExtensionRequest(request, key, ARX_EXTENSION_CANCELLED);
      return true;
    }
    for (auto& [token, item] : pending_) {
      if (item->request != request || !item->loader) continue;
      item->loader.reset();
      const auto key = item->key;
      Finish(token, Result::kUserCancelled, kCancelled);
      ReplyExtensionRequest(request, key, ARX_EXTENSION_CANCELLED);
      return true;
    }
    return false;
  }

  void Shutdown() {
    extensions::WebstorePrivateApi::SetEmbedderInstallHandler({});
    weak_factory_.InvalidateWeakPtrs();
    auto pending = std::move(pending_);
    pending_.clear();
    for (auto& [token, item] : pending) {
      item->loader.reset();
      if (item->reply) std::move(item->reply).Run(Result::kUserCancelled, kCancelled);
    }
    updates_.clear();
    callbacks_ = {};
  }

 private:
  static constexpr char kCancelled[] = "User cancelled install";

  struct Pending {
    base::WeakPtr<Profile> profile;
    std::string key;
    std::string id;
    uint64_t page = 0;
    uint64_t request = 0;
    uint64_t revision = 0;
    bool started = false;
    Reply reply;
    base::OneShotTimer timer;
    std::unique_ptr<network::SimpleURLLoader> loader;
  };

  // A store download with no store page waiting: an update (ABI45) or a new
  // install by ID (ABI47).
  struct PendingUpdate {
    base::WeakPtr<Profile> profile;
    std::string key;
    std::string id;
    uint64_t revision = 0;
    bool install = false;
    std::unique_ptr<network::SimpleURLLoader> loader;
  };

  void StartDownload(Profile* profile, const std::string& key, uint64_t request,
                     uint64_t revision, const std::string& id, bool install) {
    bool busy = updates_.contains(request) || updates_.size() >= kMaximumPendingRequests;
    for (const auto& [other, update] : updates_)
      if (update->key == key) busy = true;
    for (const auto& [token, item] : pending_)
      if (item->key == key && item->started) busy = true;
    if (busy) {
      ReplyExtensionRequest(request, key, ARX_EXTENSION_BUSY);
      return;
    }
    auto update = std::make_unique<PendingUpdate>();
    update->profile = profile->GetWeakPtr();
    update->key = key;
    update->id = id;
    update->revision = revision;
    update->install = install;
    update->loader = Download(profile, id, base::BindOnce(&Store::UpdateDownloaded,
        weak_factory_.GetWeakPtr(), request));
    updates_.emplace(request, std::move(update));
  }

  std::unique_ptr<network::SimpleURLLoader> Download(
      Profile* profile, const std::string& id,
      network::SimpleURLLoader::BodyAsStringCallback done) const {
    auto resource = std::make_unique<network::ResourceRequest>();
    resource->url = DownloadURL(id);
    resource->method = "GET";
    resource->credentials_mode = network::mojom::CredentialsMode::kOmit;
    resource->load_flags = net::LOAD_DISABLE_CACHE;
    auto loader = network::SimpleURLLoader::Create(std::move(resource), kWebstoreAnnotation);
    loader->SetTimeoutDuration(base::Seconds(60));
    auto* partition = profile->GetDefaultStoragePartition();
    loader->DownloadToString(partition->GetURLLoaderFactoryForBrowserProcess().get(),
                             std::move(done), kMaximumCRXBytes);
    return loader;
  }

  void UpdateDownloaded(uint64_t request, std::optional<std::string> body) {
    auto found = updates_.find(request);
    if (found == updates_.end()) return;
    auto update = std::move(found->second);
    updates_.erase(found);
    const bool allowed = update->loader && AllowedFinalURL(update->loader->GetFinalURL());
    update->loader.reset();
    Profile* profile = update->profile.get();
    if (!body || body->empty() || !allowed || !profile ||
        !ExtensionProfileIsCurrent(profile, update->key)) {
      ReplyExtensionRequest(request, update->key, ARX_EXTENSION_FAILED);
      return;
    }
    const std::vector<uint8_t> bytes(body->begin(), body->end());
    if (update->install) {
      InstallWebstoreCRX(profile, update->key, request, update->revision, update->id,
                         kStoreSourceName, bytes, base::DoNothing());
      return;
    }
    UpdateWebstoreCRX(profile, update->key, request, update->revision, update->id,
                      kStoreSourceName, bytes, base::DoNothing());
  }

  GURL DownloadURL(const std::string& id) const {
    if (!fixture_origin_.empty()) return GURL(fixture_origin_ + "/crx/" + id + ".crx");
    // Only the Chromium version: Google answers 204 without it. No platform,
    // channel or install identity is sent.
    const std::string x = "id=" + id + "&installsource=ondemand&uc";
    return GURL(std::string(kStoreDownloadURL) + "?response=redirect&prodversion=" +
                std::string(version_info::GetVersionNumber()) + "&acceptformat=crx3&x=" +
                base::EscapeQueryParamValue(x, /*use_plus=*/true));
  }

  bool AllowedFinalURL(const GURL& url) const {
    if (!fixture_origin_.empty()) return url.DeprecatedGetOriginAsURL() == GURL(fixture_origin_ + "/");
    return url.SchemeIs(url::kHttpsScheme);
  }

  void Requested(content::WebContents* contents, const std::string& id, Reply reply) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    auto* profile = contents ? Profile::FromBrowserContext(contents->GetBrowserContext()) : nullptr;
    const auto key = CurrentExtensionProfileKey(profile);
    const uint64_t page = contents ? PageIdentifier(contents) : 0;
    bool busy = pending_.size() >= kMaximumPendingRequests;
    for (const auto& [token, item] : pending_)
      if (key && item->key == *key) busy = true;
    if (busy) {
      std::move(reply).Run(Result::kInstallInProgress, "An install is already in progress");
      return;
    }
    if (!key || !page || !crx_file::id_util::IdIsValid(id) ||
        !callbacks_.webstore_install_requested ||
        next_token_ == std::numeric_limits<uint64_t>::max()) {
      std::move(reply).Run(Result::kUserCancelled, kCancelled);
      return;
    }
    const uint64_t token = next_token_++;
    auto item = std::make_unique<Pending>();
    item->profile = profile->GetWeakPtr();
    item->key = *key;
    item->id = id;
    item->page = page;
    item->reply = std::move(reply);
    item->timer.Start(FROM_HERE, base::Minutes(2), base::BindOnce(
        &Store::Expire, weak_factory_.GetWeakPtr(), token));
    pending_.emplace(token, std::move(item));
    // Leave Chromium's extension-function stack before the app runs.
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
        base::BindOnce(&Store::Offer, weak_factory_.GetWeakPtr(), token));
  }

  void Offer(uint64_t token) {
    auto found = pending_.find(token);
    if (found == pending_.end()) return;
    const auto key = found->second->key;
    const auto id = found->second->id;
    const auto page = found->second->page;
    const auto callbacks = callbacks_;
    const bool taken = callbacks.webstore_install_requested &&
        callbacks.webstore_install_requested(callbacks.context, page, key.c_str(), id.c_str(), token);
    // The app may have installed or declined during the callback.
    found = pending_.find(token);
    if (!taken && found != pending_.end() && !found->second->started)
      Finish(token, Result::kUserCancelled, kCancelled);
  }

  void Expire(uint64_t token) {
    auto found = pending_.find(token);
    if (found == pending_.end() || found->second->started) return;
    Finish(token, Result::kUserCancelled, kCancelled);
  }

  void Downloaded(uint64_t token, std::optional<std::string> body) {
    auto found = pending_.find(token);
    if (found == pending_.end()) return;
    auto& item = *found->second;
    const bool allowed = item.loader && AllowedFinalURL(item.loader->GetFinalURL());
    item.loader.reset();
    Profile* profile = item.profile.get();
    if (!body || body->empty() || !allowed || !profile ||
        !ExtensionProfileIsCurrent(profile, item.key)) {
      const auto key = item.key;
      const auto request = item.request;
      Finish(token, Result::kInstallError, "The item couldn't be downloaded");
      ReplyExtensionRequest(request, key, ARX_EXTENSION_FAILED);
      return;
    }
    const std::vector<uint8_t> bytes(body->begin(), body->end());
    InstallWebstoreCRX(profile, item.key, item.request, item.revision, item.id, kStoreSourceName,
        bytes, base::BindOnce(&Store::Installed, weak_factory_.GetWeakPtr(), token));
  }

  void Installed(uint64_t token, ArxExtensionStatus status) {
    auto found = pending_.find(token);
    if (found == pending_.end()) return;
    auto& item = *found->second;
    switch (status) {
      case ARX_EXTENSION_SUCCESS:
        if (Profile* profile = item.profile.get())
          extensions::WebstorePrivateApi::RecordEmbedderInstall(profile, item.id);
        Finish(token, Result::kSuccess, "");
        return;
      case ARX_EXTENSION_CANCELLED:
      case ARX_EXTENSION_TIMEOUT:
      case ARX_EXTENSION_STALE:
      case ARX_EXTENSION_UNAVAILABLE:
        Finish(token, Result::kUserCancelled, kCancelled);
        return;
      case ARX_EXTENSION_POLICY_BLOCKED:
        Finish(token, Result::kBlockedByPolicy, "Blocked by policy");
        return;
      case ARX_EXTENSION_BUSY:
        Finish(token, Result::kInstallInProgress, "An install is already in progress");
        return;
      default:
        Finish(token, Result::kInstallError, "The item couldn't be installed");
        return;
    }
  }

  void Finish(uint64_t token, Result result, const std::string& error) {
    auto found = pending_.find(token);
    if (found == pending_.end()) return;
    auto item = std::move(found->second);
    pending_.erase(found);
    if (item->reply) std::move(item->reply).Run(result, error);
  }

  ArxEngineCallbacks callbacks_ = {};
  std::string fixture_origin_;
  bool enabled_ = false;
  std::map<uint64_t, std::unique_ptr<PendingUpdate>> updates_;
  uint64_t next_token_ = 1;
  std::map<uint64_t, std::unique_ptr<Pending>> pending_;
  base::WeakPtrFactory<Store> weak_factory_{this};
};

Store& Manager() {
  static base::NoDestructor<Store> store;
  return *store;
}
}  // namespace

void ConfigureWebstoreInstalls(const ArxEngineCallbacks& callbacks, bool enabled,
                               const std::string& fixture_origin) {
  Manager().Configure(callbacks, enabled, fixture_origin);
}

void InstallWebstoreExtension(Profile* profile, const std::string& profile_key,
                              uint64_t request, uint64_t revision, uint64_t token) {
  Manager().Install(profile, profile_key, request, revision, token);
}

void UpdateWebstoreExtension(Profile* profile, const std::string& profile_key,
                             uint64_t request, uint64_t revision, const std::string& extension_id) {
  Manager().Update(profile, profile_key, request, revision, extension_id);
}

void InstallWebstoreExtensionByID(Profile* profile, const std::string& profile_key,
                                  uint64_t request, uint64_t revision,
                                  const std::string& extension_id) {
  Manager().InstallByID(profile, profile_key, request, revision, extension_id);
}

void DeclineWebstoreInstall(uint64_t token) { Manager().Decline(token); }
bool CancelWebstoreDownload(uint64_t request) { return Manager().CancelDownload(request); }
void ShutdownWebstoreInstalls() { Manager().Shutdown(); }
}  // namespace arx
