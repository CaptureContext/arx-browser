#include "chrome/browser/arx/content_blocking_bridge.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/one_shot_event.h"
#include "base/scoped_observation.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/supports_user_data.h"
#include "base/task/sequenced_task_runner.h"
#include "base/values.h"
#include "base/json/json_writer.h"
#include "base/time/time.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "chrome/browser/arx/extensions_bridge.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/content_settings/core/browser/content_settings_observer.h"
#include "components/content_settings/core/browser/content_settings_type_set.h"
#include "components/content_settings/core/browser/content_settings_utils.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_pattern.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/helium_services/extension_ids.h"
#include "components/sessions/content/session_tab_helper.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/browser_thread.h"
#include "extensions/browser/api/storage/storage_frontend.h"
#include "extensions/browser/api/storage/storage_area_namespace.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/extension_system.h"
#include "extensions/common/extension.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "url/gurl.h"

namespace arx {
namespace {

// What uBlock's arx.js reads. Keep in step with Scripts/engine/content_blocking_overlay.py.
constexpr char kStorageKey[] = "arxContentBlocking";

struct Wanted {
  bool enabled = true;
  bool cookie_banners = false;
};

Wanted& Current() {
  static Wanted wanted;
  return wanted;
}

class ContentBlocking;

std::set<ContentBlocking*>& Registered() {
  static base::NoDestructor<std::set<ContentBlocking*>> registered;
  return *registered;
}

const void* UserDataKey() {
  static const int key = 0;
  return &key;
}

// One regular profile's uBlock: its enabled state and arx.js settings follow
// Current() and the profile's Ads site exceptions. Owned by the profile.
class ContentBlocking final : public base::SupportsUserData::Data,
                              public content_settings::Observer,
                              public extensions::ExtensionRegistryObserver {
 public:
  explicit ContentBlocking(Profile* profile) : profile_(profile) {
    Registered().insert(this);
    map_ = HostContentSettingsMapFactory::GetForProfile(profile);
    if (map_) observation_.Observe(map_.get());
    if (auto* registry = extensions::ExtensionRegistry::Get(profile))
      registry_observation_.Observe(registry);
  }

  ~ContentBlocking() override { Registered().erase(this); }

  void Apply() {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    auto* system = extensions::ExtensionSystem::Get(profile_);
    if (!system) return;
    if (!system->ready().is_signaled()) {
      if (waiting_) return;
      waiting_ = true;
      system->ready().Post(FROM_HERE, base::BindOnce(&ContentBlocking::Ready,
                                                     weak_factory_.GetWeakPtr()));
      return;
    }
    const std::string id = helium::kUBlockOriginComponentId;
    auto* registry = extensions::ExtensionRegistry::Get(profile_);
    auto* registrar = extensions::ExtensionRegistrar::Get(profile_);
    if (!registry || !registrar || !registrar->IsInitialized()) return;
    scoped_refptr<const extensions::Extension> ublock = registry->GetInstalledExtension(id);
    if (!ublock) return;

    const bool enabled = registry->enabled_extensions().Contains(id);
    if (Current().enabled && !enabled) {
      // Only Arx's own off; another reason (a reload in progress) stays.
      registrar->RemoveDisableReasonAndMaybeEnable(
          id, extensions::disable_reason::DISABLE_USER_ACTION);
    } else if (!Current().enabled && enabled) {
      registrar->DisableExtension(id, {extensions::disable_reason::DISABLE_USER_ACTION});
    }

    base::DictValue settings;
    settings.Set("cookieBanners", Current().cookie_banners);
    settings.Set("trustedSites", TrustedSites());
    // DEV-923: arx.js selects the Phishing URL Blocklist once; the person can
    // turn it off in uBlock's dashboard afterwards.
    settings.Set("phishingList", true);
    if (last_written_ && *last_written_ == settings) return;
    last_written_ = settings.Clone();
    base::DictValue values;
    values.Set(kStorageKey, std::move(settings));
    // Writes uBlock's storage even while it's off, so it starts with the
    // current settings. A changed value fires storage.onChanged for arx.js.
    extensions::StorageFrontend::Get(profile_)->Set(
        ublock, extensions::StorageAreaNamespace::kLocal, std::move(values),
        base::DoNothing());
  }

  // content_settings::Observer:
  void OnContentSettingChanged(const ContentSettingsPattern&, const ContentSettingsPattern&,
                               ContentSettingsTypeSet types) override {
    if (types.Contains(ContentSettingsType::ADS)) Apply();
  }

  // extensions::ExtensionRegistryObserver: uBlock loaded again, as it does after
  // its dashboard resets or restores its settings, which clears its storage.
  // Write Arx's settings again, posted, so this never runs inside the registry's
  // own notification.
  void OnExtensionLoaded(content::BrowserContext*, const extensions::Extension* extension) override {
    if (!extension || extension->id() != helium::kUBlockOriginComponentId) return;
    last_written_.reset();
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&ContentBlocking::Apply, weak_factory_.GetWeakPtr()));
  }
  void OnShutdown(extensions::ExtensionRegistry*) override { registry_observation_.Reset(); }

 private:
  void Ready() {
    waiting_ = false;
    Apply();
  }

  // uBlock trusted-site directives for the sites whose Ads setting is ALLOW,
  // in the same scope as the rule: an exact origin (what the site menu sets)
  // becomes a regex for that scheme, host and port only; a wider pattern such
  // as `[*.]example.com` becomes a hostname, which uBlock applies to its
  // subdomains too. Rules come in precedence order, so only a pattern's first
  // rule counts: a policy BLOCK hides the person's ALLOW for the same pattern.
  base::ListValue TrustedSites() const {
    base::ListValue sites;
    if (!map_) return sites;
    // Each pattern's first rule, in precedence order.
    std::set<std::string> patterns;
    std::vector<const ContentSettingPatternSource*> allowed;
    std::vector<std::string> blocked_hosts;
    const auto rules = map_->GetSettingsForOneType(ContentSettingsType::ADS);
    for (const auto& entry : rules) {
      if (entry.primary_pattern.MatchesAllHosts() || !entry.secondary_pattern.MatchesAllHosts() ||
          entry.source == content_settings::mojom::ProviderType::kDefaultProvider || entry.IsExpired())
        continue;
      if (!patterns.insert(entry.primary_pattern.ToString()).second) continue;
      if (entry.GetContentSetting() == CONTENT_SETTING_ALLOW) {
        allowed.push_back(&entry);
      } else {
        const GURL url = entry.primary_pattern.ToRepresentativeUrl();
        if (url.is_valid() && !url.host().empty()) blocked_hosts.emplace_back(url.host());
      }
    }
    std::set<std::string> directives;
    for (const auto* entry : allowed) {
      const GURL url = entry->primary_pattern.ToRepresentativeUrl();
      if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || url.host().empty()) continue;
      // What Chromium decides for the site after every rule. Only an ALLOW
      // counts, and only when no higher source outranks this rule: the winner
      // is this rule, or another site rule from the same source, such as the
      // person's exact `https://example.com` ALLOW inside their own
      // `[*.]example.com` ALLOW. A managed rule or a managed default wins.
      content_settings::SettingInfo info;
      if (map_->GetContentSetting(url, url, ContentSettingsType::ADS, &info) != CONTENT_SETTING_ALLOW)
        continue;
      const bool decided_here = info.primary_pattern == entry->primary_pattern ||
          (!info.primary_pattern.MatchesAllHosts() &&
           info.source == content_settings::GetSettingSourceFromProviderType(entry->source));
      if (!decided_here) continue;
      const std::string host(url.host());
      std::string directive;
      if (ContentSettingsPattern::FromURLNoWildcard(url) == entry->primary_pattern) {
        directive = ExactOriginDirective(url);
      } else if (entry->primary_pattern.ToString() == "[*.]" + host) {
        // Any scheme and port, the host and its subdomains: what a hostname
        // directive means to uBlock. A BLOCK anywhere inside it can't be
        // carved out of a hostname directive, so then the rule is skipped.
        const bool carved = std::any_of(blocked_hosts.begin(), blocked_hosts.end(),
            [&](const std::string& blocked) {
              return blocked == host || base::EndsWith(blocked, "." + host);
            });
        if (carved) continue;
        directive = host;
      } else {
        continue;  // Some other shape Arx doesn't set; leave it to uBlock's own UI.
      }
      // No cap: every rule the site menu shows as off reaches uBlock.
      if (!directives.insert(directive).second) continue;
      sites.Append(directive);
    }
    return sites;
  }

  // `/^https:\/\/news\.example\//`, with `:port` when it isn't the default.
  // An IPv6 host keeps its brackets, escaped: `/^http:\/\/\[::1\]\//`.
  static std::string ExactOriginDirective(const GURL& url) {
    std::string host;
    for (char character : url.host()) {
      if (character == '.' || character == '[' || character == ']') host += '\\';
      host += character;
    }
    std::string directive = "/^" + std::string(url.scheme()) + ":\\/\\/" + host;
    if (url.has_port()) directive += ":" + std::string(url.port());
    return directive + "\\//";
  }

  raw_ptr<Profile> profile_;
  scoped_refptr<HostContentSettingsMap> map_;
  bool waiting_ = false;
  std::optional<base::DictValue> last_written_;
  base::ScopedObservation<HostContentSettingsMap, content_settings::Observer> observation_{this};
  base::ScopedObservation<extensions::ExtensionRegistry, extensions::ExtensionRegistryObserver>
      registry_observation_{this};
  base::WeakPtrFactory<ContentBlocking> weak_factory_{this};
};

}  // namespace

void EnsureContentBlocking(Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile) return;
  profile = profile->GetOriginalProfile();
  if (profile->GetUserData(UserDataKey())) return;
  auto blocking = std::make_unique<ContentBlocking>(profile);
  auto* raw = blocking.get();
  profile->SetUserData(UserDataKey(), std::move(blocking));
  raw->Apply();
}

void SetContentBlocking(bool enabled, bool block_cookie_banners) {
  auto& current = Current();
  if (current.enabled == enabled && current.cookie_banners == block_cookie_banners) return;
  current.enabled = enabled;
  current.cookie_banners = block_cookie_banners;
  // Before the engine runs nothing is registered yet.
  const std::set<ContentBlocking*> registered = Registered();
  for (auto* blocking : registered)
    if (Registered().contains(blocking)) blocking->Apply();
}

}  // namespace arx

namespace arx {
namespace {

// What arx.js reads and writes for Hide Element (DEV-1019). Keep in step with
// Scripts/engine/content_blocking_overlay.py.
constexpr char kPickerKey[] = "arxElementPicker";
constexpr char kShowKey[] = "arxShowHiddenElement";
constexpr char kHiddenKey[] = "arxHiddenElements";
// What arx.js made of the last picker ask, for the extensions smoke.
constexpr char kPickerStatusKey[] = "arxElementPickerStatus";
// Lines the extensions smoke adds to My filters.
constexpr char kFixtureFiltersKey[] = "arxFixtureFilters";
// A line Arx's own element picker adds to My filters (DEV-1201).
constexpr char kHideKey[] = "arxHideElement";
constexpr size_t kMaximumFixtureFilters = 16;
// A filter line longer than this isn't one arx.js listed.
constexpr size_t kMaximumFilterBytes = 8 * 1024;

// An ordinary page's profile with uBlock on in it.
struct PageBlocker {
  raw_ptr<Profile> profile;
  scoped_refptr<const extensions::Extension> ublock;
};

std::optional<PageBlocker> Blocker(content::WebContents* contents) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!contents) return std::nullopt;
  auto* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  if (!profile || profile->IsOffTheRecord()) return std::nullopt;
  auto* registry = extensions::ExtensionRegistry::Get(profile);
  if (!registry) return std::nullopt;
  scoped_refptr<const extensions::Extension> ublock(
      registry->enabled_extensions().GetByID(helium::kUBlockOriginComponentId));
  if (!ublock) return std::nullopt;
  return PageBlocker{profile, std::move(ublock)};
}

// Each request differs from the last, even across launches, so writing it
// always fires storage.onChanged.
double NextRequest() {
  static int64_t count = 0;
  count += 1;
  return static_cast<double>(base::Time::Now().InMillisecondsSinceUnixEpoch()) * 1000.0 +
         static_cast<double>(count % 1000);
}

void Write(const PageBlocker& blocker, const char* key, base::DictValue request) {
  request.Set("request", NextRequest());
  base::DictValue values;
  values.Set(key, std::move(request));
  extensions::StorageFrontend::Get(blocker.profile)
      ->Set(blocker.ublock, extensions::StorageAreaNamespace::kLocal, std::move(values),
            base::DoNothing());
}

}  // namespace
}  // namespace arx

namespace arx {
namespace {

// An ordinary http(s) page's profile with uBlock on, on a site the person didn't
// turn blocking off for: uBlock doesn't filter a trusted site, so a filter picked
// there would never apply.
std::optional<PageBlocker> PickingBlocker(content::WebContents* contents, GURL* url) {
  if (!contents) return std::nullopt;
  *url = contents->GetLastCommittedURL();
  if (!url->SchemeIsHTTPOrHTTPS()) return std::nullopt;
  auto blocker = Blocker(contents);
  if (!blocker) return std::nullopt;
  if (auto* map = HostContentSettingsMapFactory::GetForProfile(blocker->profile);
      map && map->GetContentSetting(*url, *url, ContentSettingsType::ADS) == CONTENT_SETTING_ALLOW)
    return std::nullopt;
  return blocker;
}

// Whether `selector` is a plain CSS selector for a `host##selector` line: not a
// scriptlet, an HTML filter, another kind of cosmetic filter, or one of uBlock's
// action operators, which do more than hide (DEV-1201).
bool IsPlainSelector(std::string_view selector) {
  if (selector.empty() || selector.size() > kMaximumFilterBytes) return false;
  if (selector.find_first_of("\r\n") != std::string_view::npos) return false;
  if (selector.starts_with("+js(") || selector.starts_with('^')) return false;
  for (const std::string_view operation : {"#@#", "#?#", "#$#", "##", ":style(", ":remove(",
                                           ":remove-attr(", ":remove-class(", ":watch-attr("}) {
    if (selector.find(operation) != std::string_view::npos) return false;
  }
  return true;
}

}  // namespace
}  // namespace arx

extern "C" __attribute__((visibility("default")))
bool ArxEngineStartElementPicker(uint64_t page) {
  CHECK([NSThread isMainThread]);
  if (!arx::IsEmbedded()) return false;
  auto* contents = arx::PageContents(page);
  GURL url;
  const auto blocker = arx::PickingBlocker(contents, &url);
  if (!blocker) return false;
  const SessionID tab = sessions::SessionTabHelper::IdForTab(contents);
  if (!tab.is_valid()) return false;
  base::DictValue request;
  request.Set("tabId", tab.id());
  arx::Write(*blocker, arx::kPickerKey, std::move(request));
  return true;
}

namespace arx {
namespace {

// Reads `key`, an object arx.js keeps in uBlock's storage.local, in `page`'s
// profile and hands it to `done` as JSON ("{}" when there's none).
bool CopyStoredObject(uint64_t page, const char* key, ArxHiddenElementsCallback done,
                      void* context) {
  CHECK([NSThread isMainThread]);
  if (!done || !IsEmbedded()) return false;
  const auto blocker = Blocker(PageContents(page));
  if (!blocker) return false;
  auto reply = base::BindOnce(
      [](std::string key, ArxHiddenElementsCallback done, void* context,
         extensions::StorageFrontend::GetResult result) {
        std::string json = "{}";
        if (result.status.success && result.data) {
          if (const auto* value = result.data->FindDict(key))
            json = base::WriteJson(*value).value_or("{}");
        }
        done(context, json.c_str(), json.size());
      },
      std::string(key), done, context);
  extensions::StorageFrontend::Get(blocker->profile)
      ->GetValues(blocker->ublock, extensions::StorageAreaNamespace::kLocal,
                  std::vector<std::string>{key},
                  mojo::WrapCallbackWithDefaultInvokeIfNotRun(
                      std::move(reply), extensions::StorageFrontend::GetResult()));
  return true;
}

}  // namespace
}  // namespace arx

extern "C" __attribute__((visibility("default")))
bool ArxEngineCopyHiddenElements(uint64_t page, ArxHiddenElementsCallback done, void* context) {
  return arx::CopyStoredObject(page, arx::kHiddenKey, done, context);
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineCopyElementPickerStatus(uint64_t page, ArxHiddenElementsCallback done,
                                      void* context) {
  return arx::CopyStoredObject(page, arx::kPickerStatusKey, done, context);
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineAddFixtureFilters(uint64_t page, const char* filters) {
  CHECK([NSThread isMainThread]);
  if (!filters || !arx::IsEmbedded() || !arx::IsExtensionFixtureRun()) return false;
  base::ListValue lines;
  for (const auto& line : base::SplitString(filters, "\n", base::TRIM_WHITESPACE,
                                            base::SPLIT_WANT_NONEMPTY)) {
    if (line.size() > arx::kMaximumFilterBytes || lines.size() == arx::kMaximumFixtureFilters)
      return false;
    lines.Append(line);
  }
  if (lines.empty()) return false;
  const auto blocker = arx::Blocker(arx::PageContents(page));
  if (!blocker) return false;
  base::DictValue request;
  request.Set("filters", std::move(lines));
  arx::Write(*blocker, arx::kFixtureFiltersKey, std::move(request));
  return true;
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineHideElement(uint64_t page, const char* filter) {
  CHECK([NSThread isMainThread]);
  if (!arx::IsEmbedded()) return false;
  GURL url;
  const auto blocker = arx::PickingBlocker(arx::PageContents(page), &url);
  if (!blocker) return false;
  // No filter asks only whether the page's site would take one, before the picker opens.
  if (!filter) return true;
  const std::string line(filter);
  const size_t separator = line.find("##");
  if (separator == std::string::npos) return false;
  // Only the page's own site, as the browser names it (ASCII, an IPv6 address in
  // brackets), so the line hides on the site it was picked on and the site menu lists it.
  if (std::string_view(line).substr(0, separator) != url.host()) return false;
  if (!arx::IsPlainSelector(std::string_view(line).substr(separator + 2))) return false;
  base::DictValue request;
  request.Set("filter", line);
  arx::Write(*blocker, arx::kHideKey, std::move(request));
  return true;
}

extern "C" __attribute__((visibility("default")))
bool ArxEngineShowHiddenElement(uint64_t page, const char* filter) {
  CHECK([NSThread isMainThread]);
  if (!filter || !arx::IsEmbedded()) return false;
  const std::string line(filter);
  if (line.empty() || line.size() > arx::kMaximumFilterBytes ||
      line.find('\n') != std::string::npos || line.find("##") == std::string::npos)
    return false;
  const auto blocker = arx::Blocker(arx::PageContents(page));
  if (!blocker) return false;
  base::DictValue request;
  request.Set("filter", line);
  arx::Write(*blocker, arx::kShowKey, std::move(request));
  return true;
}

// DEV-884, exported outside the ABI table so the app still runs on engines
// built before it. Main thread; may be called before ArxEngine run.
extern "C" __attribute__((visibility("default")))
void ArxEngineSetContentBlocking(bool enabled, bool block_cookie_banners) {
  arx::SetContentBlocking(enabled, block_cookie_banners);
}
