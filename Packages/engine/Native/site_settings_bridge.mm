#include "chrome/browser/arx/site_settings_bridge.h"

#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <variant>

#include "base/callback_list.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/strings/string_util.h"
#include "base/task/single_thread_task_runner.h"
#include "base/values.h"
#include "components/permissions/permission_decision_auto_blocker.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/permissions/permission_decision_auto_blocker_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/browser/ui/zoom/chrome_zoom_level_prefs.h"
#include "components/content_settings/core/browser/content_settings_info.h"
#include "components/content_settings/core/browser/content_settings_observer.h"
#include "components/content_settings/core/browser/content_settings_registry.h"
#include "components/content_settings/core/browser/content_settings_type_set.h"
#include "components/content_settings/core/browser/content_settings_utils.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/browser/permission_settings_registry.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_pattern.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/content_settings/core/common/content_settings_utils.h"
#include "content/public/browser/host_zoom_map.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace arx {
namespace {
using content_settings::ProviderType;
using content_settings::SettingSource;

constexpr size_t kMaximumRows = 5000;
constexpr size_t kMaximumTextBytes = 2048;
constexpr double kMinimumFactor = 0.25;
constexpr double kMaximumFactor = 5.0;

struct Kind {
  ArxSitePermission permission;
  const char* name;
};

constexpr Kind kKinds[] = {
    {ARX_SITE_PERMISSION_CAMERA, "camera"},
    {ARX_SITE_PERMISSION_MICROPHONE, "microphone"},
    {ARX_SITE_PERMISSION_LOCATION, "location"},
    {ARX_SITE_PERMISSION_NOTIFICATIONS, "notifications"},
    {ARX_SITE_PERMISSION_POPUPS, "popups"},
    {ARX_SITE_PERMISSION_CLIPBOARD, "clipboard"},
    // DEV-884: ALLOW means content blocking is off for the site.
    {ARX_SITE_PERMISSION_ADS, "ads"},
};

std::optional<ContentSettingsType> TypeFor(ArxSitePermission permission) {
  switch (permission) {
    case ARX_SITE_PERMISSION_CAMERA: return ContentSettingsType::MEDIASTREAM_CAMERA;
    case ARX_SITE_PERMISSION_MICROPHONE: return ContentSettingsType::MEDIASTREAM_MIC;
    // Chromium is moving geolocation to GEOLOCATION_WITH_OPTIONS behind a
    // feature; follow whichever type its permission prompts store.
    case ARX_SITE_PERMISSION_LOCATION: return content_settings::GeolocationContentSettingsType();
    case ARX_SITE_PERMISSION_NOTIFICATIONS: return ContentSettingsType::NOTIFICATIONS;
    case ARX_SITE_PERMISSION_POPUPS: return ContentSettingsType::POPUPS;
    case ARX_SITE_PERMISSION_CLIPBOARD: return ContentSettingsType::CLIPBOARD_READ_WRITE;
    case ARX_SITE_PERMISSION_ADS: return ContentSettingsType::ADS;
  }
  return std::nullopt;
}

bool WithOptions(ContentSettingsType type) {
  return type == ContentSettingsType::GEOLOCATION_WITH_OPTIONS;
}

const char* Name(ContentSetting setting) {
  switch (setting) {
    case CONTENT_SETTING_ALLOW: return "allow";
    case CONTENT_SETTING_BLOCK: return "block";
    case CONTENT_SETTING_ASK: return "ask";
    default: return nullptr;
  }
}

// Location with options allows when either precision is allowed.
const char* Name(const PermissionSetting& setting) {
  if (const auto* value = std::get_if<ContentSetting>(&setting)) return Name(*value);
  const auto& location = std::get<GeolocationSetting>(setting);
  using Option = PermissionOption;
  if (location.approximate == Option::kAllowed || location.precise == Option::kAllowed)
    return "allow";
  if (location.approximate == Option::kDenied && location.precise == Option::kDenied)
    return "block";
  return "ask";
}

PermissionSetting ToPermissionSetting(ContentSettingsType type, ContentSetting setting) {
  if (!WithOptions(type)) return setting;
  using Option = PermissionOption;
  const Option option = setting == CONTENT_SETTING_ALLOW   ? Option::kAllowed
                        : setting == CONTENT_SETTING_BLOCK ? Option::kDenied
                                                           : Option::kAsk;
  return GeolocationSetting{option, option};
}

bool Managed(SettingSource source) {
  return source == SettingSource::kPolicy || source == SettingSource::kExtension ||
         source == SettingSource::kSupervised;
}

bool Managed(ProviderType provider) {
  return Managed(content_settings::GetSettingSourceFromProviderType(provider));
}

// An exception for exactly one origin reads as that origin; anything wider
// keeps Chromium's pattern text.
std::string Origin(const ContentSettingsPattern& pattern) {
  const GURL url = pattern.ToRepresentativeUrl();
  if (url.is_valid() && url.SchemeIsHTTPOrHTTPS() &&
      ContentSettingsPattern::FromURLNoWildcard(url) == pattern)
    return url::Origin::Create(url).Serialize();
  return pattern.ToString();
}

double Rounded(double factor) {
  return std::round(factor * 1000) / 1000;
}

std::optional<std::string> Text(const char* value) {
  if (!value) return std::string();
  const size_t length = strnlen(value, kMaximumTextBytes + 1);
  if (length > kMaximumTextBytes) return std::nullopt;
  return std::string(value, length);
}

class Watcher;

struct Settings {
  SiteSettingsReply reply = nullptr;
  SiteSettingsChanged changed = nullptr;
  std::map<Profile*, std::unique_ptr<Watcher>> watchers;
};

Settings& State() {
  static base::NoDestructor<Settings> settings;
  return *settings;
}

// Tells the app once per burst that a listed profile's site settings changed,
// whoever changed them. Lives until the profile is destroyed or Stop.
class Watcher final : public content_settings::Observer, public ProfileObserver {
 public:
  Watcher(Profile* profile, std::string key) : key_(std::move(key)) {
    profile_observation_.Observe(profile);
    if (auto* map = HostContentSettingsMapFactory::GetForProfile(profile))
      settings_observation_.Observe(map);
    if (auto* zoom = content::HostZoomMap::GetDefaultForBrowserContext(profile))
      zoom_subscription_ = zoom->AddZoomLevelChangedCallback(base::BindRepeating(
          &Watcher::ZoomChanged, base::Unretained(this)));
    if (auto* prefs = profile->GetZoomLevelPrefs())
      default_zoom_subscription_ = prefs->RegisterDefaultZoomLevelCallback(
          base::BindRepeating(&Watcher::Changed, base::Unretained(this)));
  }

  void OnContentSettingChanged(const ContentSettingsPattern&, const ContentSettingsPattern&,
                               ContentSettingsTypeSet types) override {
    for (const auto& kind : kKinds)
      if (auto type = TypeFor(kind.permission); type && types.Contains(*type)) return Changed();
  }

  void OnProfileWillBeDestroyed(Profile* profile) override {
    // Destroys this; nothing below may touch it.
    State().watchers.erase(profile);
  }

 private:
  void ZoomChanged(const content::HostZoomMap::ZoomLevelChange& change) {
    if (change.mode == content::HostZoomMap::ZOOM_CHANGED_FOR_HOST) Changed();
  }

  void Changed() {
    if (posted_) return;
    posted_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](base::WeakPtr<Watcher> watcher) {
                         if (!watcher) return;
                         watcher->posted_ = false;
                         if (auto changed = State().changed) changed(watcher->key_.c_str());
                       },
                       weak_factory_.GetWeakPtr()));
  }

  const std::string key_;
  bool posted_ = false;
  base::ScopedObservation<Profile, ProfileObserver> profile_observation_{this};
  base::ScopedObservation<HostContentSettingsMap, content_settings::Observer>
      settings_observation_{this};
  base::CallbackListSubscription zoom_subscription_;
  base::CallbackListSubscription default_zoom_subscription_;
  base::WeakPtrFactory<Watcher> weak_factory_{this};
};

void Watch(Profile* profile, const char* key) {
  auto& watchers = State().watchers;
  if (!watchers.contains(profile))
    watchers.emplace(profile, std::make_unique<Watcher>(profile, key ? key : ""));
}

// Always posted, so a reply never arrives inside the call that asked.
void Reply(uint64_t request, ArxSiteSettingsStatus status, base::DictValue body) {
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(body)), &json);
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](uint64_t request, ArxSiteSettingsStatus status, std::string json) {
                       if (auto reply = State().reply)
                         reply(request, status, reinterpret_cast<const uint8_t*>(json.data()),
                               json.size());
                     },
                     request, status, std::move(json)));
}

void Fail(uint64_t request, ArxSiteSettingsStatus status, const char* reason) {
  base::DictValue body;
  if (reason) body.Set("reason", reason);
  Reply(request, status, std::move(body));
}

base::DictValue Listing(Profile* profile) {
  auto* map = HostContentSettingsMapFactory::GetForProfile(profile);
  bool truncated = false;

  base::DictValue defaults;
  base::ListValue managed_defaults;
  base::ListValue sites;
  for (const auto& kind : kKinds) {
    const ContentSettingsType type = *TypeFor(kind.permission);
    ProviderType provider = ProviderType::kDefaultProvider;
    const char* fallback =
        WithOptions(type) ? Name(map->GetDefaultPermissionSetting(type, &provider))
                          : Name(map->GetDefaultContentSetting(type, &provider));
    if (fallback) defaults.Set(kind.name, fallback);
    if (Managed(provider)) managed_defaults.Append(kind.name);

    const auto* options = WithOptions(type)
                              ? content_settings::PermissionSettingsRegistry::GetInstance()->Get(type)
                              : nullptr;
    // Rules come in precedence order: a policy or extension rule for a pattern
    // hides the user's rule for the same pattern, so only the first one counts.
    std::set<std::string> seen;
    for (const auto& entry : map->GetSettingsForOneType(type)) {
      // The wildcard rule is the default; embedded exceptions aren't per site.
      if (entry.primary_pattern.MatchesAllHosts() || !entry.secondary_pattern.MatchesAllHosts() ||
          entry.source == ProviderType::kDefaultProvider || entry.IsExpired())
        continue;
      if (!seen.insert(entry.primary_pattern.ToString()).second) continue;
      const char* setting =
          options ? Name(content_settings::ValueToPermissionSetting(options, entry.setting_value))
                  : Name(entry.GetContentSetting());
      if (!setting) continue;
      if (sites.size() >= kMaximumRows) {
        truncated = true;
        break;
      }
      base::DictValue row;
      row.Set("origin", Origin(entry.primary_pattern));
      row.Set("permission", kind.name);
      row.Set("setting", setting);
      row.Set("managed", Managed(entry.source));
      sites.Append(std::move(row));
    }
  }

  base::DictValue permissions;
  permissions.Set("defaults", std::move(defaults));
  permissions.Set("managedDefaults", std::move(managed_defaults));
  permissions.Set("sites", std::move(sites));

  base::ListValue zoom_sites;
  auto* zoom = content::HostZoomMap::GetDefaultForBrowserContext(profile);
  for (const auto& level : zoom->GetAllZoomLevels()) {
    if (level.mode != content::HostZoomMap::ZOOM_CHANGED_FOR_HOST || level.host.empty()) continue;
    if (zoom_sites.size() >= kMaximumRows) {
      truncated = true;
      break;
    }
    base::DictValue row;
    row.Set("host", level.host);
    row.Set("factor", Rounded(blink::ZoomLevelToZoomFactor(level.zoom_level)));
    zoom_sites.Append(std::move(row));
  }
  base::DictValue zooms;
  zooms.Set("default", Rounded(blink::ZoomLevelToZoomFactor(zoom->GetDefaultZoomLevel())));
  zooms.Set("sites", std::move(zoom_sites));

  base::DictValue listing;
  listing.Set("permissions", std::move(permissions));
  listing.Set("zoom", std::move(zooms));
  listing.Set("truncated", truncated);
  return listing;
}

void Finish(Profile* profile, const char* key, uint64_t request) {
  Watch(profile, key);
  Reply(request, ARX_SITE_SETTINGS_OK, Listing(profile));
}

// Whether policy, an extension or supervision holds a rule for exactly this
// site pattern, which removing the user's rule can't undo.
bool HasManagedRule(HostContentSettingsMap* map, ContentSettingsType type,
                    const ContentSettingsPattern& pattern) {
  for (const auto& entry : map->GetSettingsForOneType(type))
    if (entry.primary_pattern == pattern && entry.secondary_pattern.MatchesAllHosts() &&
        Managed(entry.source))
      return true;
  return false;
}

// As Chromium's own site settings do: a site that's no longer blocked starts
// with no embargo from earlier dismissed prompts.
void ClearEmbargo(Profile* profile, const GURL& url, ContentSettingsType type,
                  ContentSetting setting) {
  if (setting == CONTENT_SETTING_BLOCK || !url.is_valid()) return;
  if (auto* blocker = PermissionDecisionAutoBlockerFactory::GetForProfile(profile))
    blocker->RemoveEmbargoAndResetCounts(url, type);
}

std::optional<ContentSetting> SettingFor(ArxSitePermissionSetting setting) {
  switch (setting) {
    case ARX_SITE_PERMISSION_SETTING_DEFAULT: return CONTENT_SETTING_DEFAULT;
    case ARX_SITE_PERMISSION_SETTING_ALLOW: return CONTENT_SETTING_ALLOW;
    case ARX_SITE_PERMISSION_SETTING_BLOCK: return CONTENT_SETTING_BLOCK;
    case ARX_SITE_PERMISSION_SETTING_ASK: return CONTENT_SETTING_ASK;
  }
  return std::nullopt;
}

// The host part only: no scheme, port, path or user info.
std::optional<std::string> Host(const std::string& text) {
  if (text.find_first_of("/:@?#\\ \t\r\n") != std::string::npos) return std::nullopt;
  const GURL url("https://" + text + "/");
  if (!url.is_valid() || url.host().empty()) return std::nullopt;
  return std::string(url.host());
}
}  // namespace

void StartSiteSettings(SiteSettingsReply reply, SiteSettingsChanged changed) {
  State().reply = reply;
  State().changed = changed;
}

void StopSiteSettings() {
  auto& state = State();
  state.watchers.clear();
  state.reply = nullptr;
  state.changed = nullptr;
}

void ListSiteSettings(Profile* profile, const char* key, uint64_t request) {
  if (!profile || profile->IsOffTheRecord())
    return Fail(request, ARX_SITE_SETTINGS_UNAVAILABLE, nullptr);
  Finish(profile, key, request);
}

void SetSitePermission(Profile* profile, const char* key, uint64_t request, const char* origin,
                       ArxSitePermission permission, ArxSitePermissionSetting setting) {
  if (!profile || profile->IsOffTheRecord())
    return Fail(request, ARX_SITE_SETTINGS_UNAVAILABLE, nullptr);
  const auto type = TypeFor(permission);
  if (!type) return Fail(request, ARX_SITE_SETTINGS_INVALID, "permission");
  const auto value = SettingFor(setting);
  if (!value) return Fail(request, ARX_SITE_SETTINGS_INVALID, "setting");
  const auto text = Text(origin);
  if (!text) return Fail(request, ARX_SITE_SETTINGS_INVALID, "origin");

  auto* map = HostContentSettingsMapFactory::GetForProfile(profile);
  const auto* info = WithOptions(*type)
                         ? nullptr
                         : content_settings::ContentSettingsRegistry::GetInstance()->Get(*type);
  if (!WithOptions(*type) && !info) return Fail(request, ARX_SITE_SETTINGS_UNAVAILABLE, nullptr);

  if (text->empty()) {
    const bool valid = *value != CONTENT_SETTING_DEFAULT &&
                       (info ? info->IsDefaultSettingValid(*value)
                             : *value != CONTENT_SETTING_ALLOW);
    if (!valid) return Fail(request, ARX_SITE_SETTINGS_INVALID, "setting");
    ProviderType provider = ProviderType::kDefaultProvider;
    if (WithOptions(*type))
      map->GetDefaultPermissionSetting(*type, &provider);
    else
      map->GetDefaultContentSetting(*type, &provider);
    if (Managed(provider)) return Fail(request, ARX_SITE_SETTINGS_MANAGED, "managed");
    if (WithOptions(*type))
      map->SetDefaultPermissionSetting(*type, ToPermissionSetting(*type, *value));
    else
      map->SetDefaultContentSetting(*type, *value);
    return Finish(profile, key, request);
  }

  const GURL url(*text);
  if (url.is_valid() && url.SchemeIsHTTPOrHTTPS() && !url.has_username() && !url.has_password()) {
    const GURL site = url::Origin::Create(url).GetURL();
    if (*value != CONTENT_SETTING_DEFAULT) {
      if (info && !info->IsSettingValid(*value))
        return Fail(request, ARX_SITE_SETTINGS_INVALID, "setting");
      content_settings::SettingInfo current;
      if (WithOptions(*type))
        map->GetPermissionSetting(site, site, *type, &current);
      else
        map->GetContentSetting(site, site, *type, &current);
      if (Managed(current.source)) return Fail(request, ARX_SITE_SETTINGS_MANAGED, "managed");
    } else if (HasManagedRule(
                   map, *type,
                   HostContentSettingsMap::GetPatternsForContentSettingsType(site, site, *type)
                       .first)) {
      return Fail(request, ARX_SITE_SETTINGS_MANAGED, "managed");
    }
    if (WithOptions(*type))
      map->SetPermissionSettingDefaultScope(
          site, site, *type,
          *value == CONTENT_SETTING_DEFAULT
              ? std::nullopt
              : std::optional<PermissionSetting>(ToPermissionSetting(*type, *value)));
    else
      map->SetContentSettingDefaultScope(site, site, *type, *value);
    ClearEmbargo(profile, site, *type, *value);
    return Finish(profile, key, request);
  }

  // A listed pattern wider than one origin can only be removed.
  const auto pattern = ContentSettingsPattern::FromString(*text);
  if (*value != CONTENT_SETTING_DEFAULT || !pattern.IsValid() || pattern.MatchesAllHosts())
    return Fail(request, ARX_SITE_SETTINGS_INVALID, "origin");
  if (HasManagedRule(map, *type, pattern)) return Fail(request, ARX_SITE_SETTINGS_MANAGED, "managed");
  if (WithOptions(*type))
    map->SetPermissionSettingCustomScope(pattern, ContentSettingsPattern::Wildcard(), *type,
                                         std::nullopt);
  else
    map->SetContentSettingCustomScope(pattern, ContentSettingsPattern::Wildcard(), *type,
                                      CONTENT_SETTING_DEFAULT);
  ClearEmbargo(profile, pattern.ToRepresentativeUrl(), *type, CONTENT_SETTING_DEFAULT);
  Finish(profile, key, request);
}

void SetSiteZoom(Profile* profile, const char* key, uint64_t request, const char* host,
                 double factor) {
  if (!profile || profile->IsOffTheRecord())
    return Fail(request, ARX_SITE_SETTINGS_UNAVAILABLE, nullptr);
  const auto text = Text(host);
  if (!text) return Fail(request, ARX_SITE_SETTINGS_INVALID, "host");
  const bool in_range = std::isfinite(factor) && factor >= kMinimumFactor &&
                        factor <= kMaximumFactor;
  auto* zoom = content::HostZoomMap::GetDefaultForBrowserContext(profile);

  if (text->empty()) {
    if (!in_range) return Fail(request, ARX_SITE_SETTINGS_INVALID, "factor");
    auto* prefs = profile->GetZoomLevelPrefs();
    if (!prefs) return Fail(request, ARX_SITE_SETTINGS_UNAVAILABLE, nullptr);
    prefs->SetDefaultZoomLevelPref(blink::ZoomFactorToZoomLevel(factor));
    return Finish(profile, key, request);
  }

  const auto normalized = Host(*text);
  if (!normalized) return Fail(request, ARX_SITE_SETTINGS_INVALID, "host");
  if (factor != 0 && !in_range) return Fail(request, ARX_SITE_SETTINGS_INVALID, "factor");
  // A level equal to the default removes the host's entry.
  zoom->SetZoomLevelForHost(*normalized, factor == 0 ? zoom->GetDefaultZoomLevel()
                                                     : blink::ZoomFactorToZoomLevel(factor));
  Finish(profile, key, request);
}
}  // namespace arx
