#include "chrome/browser/arx/browsing_data_bridge.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/task/single_thread_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/browser/browsing_data/chrome_browsing_data_remover_constants.h"
#include "chrome/browser/browsing_data/counters/browsing_data_counter_factory.h"
#include "chrome/browser/browsing_data/counters/cache_counter.h"
#include "chrome/browser/download/download_prefs.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/common/pref_names.h"
#include "components/browsing_data/core/counters/autofill_counter.h"
#include "components/browsing_data/core/counters/browsing_data_counter.h"
#include "components/browsing_data/core/pref_names.h"
#include "components/history/core/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browsing_data_filter_builder.h"
#include "content/public/browser/browsing_data_remover.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "url/gurl.h"

namespace arx {
namespace {
using browsing_data::BrowsingDataCounter;
using content::BrowsingDataRemover;

constexpr uint32_t kAllKinds = ARX_BROWSING_DATA_HISTORY | ARX_BROWSING_DATA_DOWNLOADS |
                               ARX_BROWSING_DATA_COOKIES | ARX_BROWSING_DATA_CACHE |
                               ARX_BROWSING_DATA_AUTOFILL | ARX_BROWSING_DATA_SITE_SETTINGS;
constexpr uint32_t kSiteKinds = ARX_BROWSING_DATA_COOKIES | ARX_BROWSING_DATA_CACHE;
constexpr size_t kMaximumPathBytes = 4096;
constexpr size_t kMaximumURLBytes = 8192;
constexpr size_t kMaximumJobs = 32;
// A counter that never answers (a stalled cache backend) shouldn't hold the
// sheet forever; what has been counted by then is replied.
constexpr base::TimeDelta kCountTimeout = base::Seconds(20);

class CountJob;
class ClearJob;

struct ProfileData {
  ProfileDataReply reply = nullptr;
  std::map<uint64_t, std::unique_ptr<CountJob>> counts;
  std::map<Profile*, std::unique_ptr<ClearJob>> clears;
  uint64_t generation = 0;
};

ProfileData& State() {
  static base::NoDestructor<ProfileData> data;
  return *data;
}

// Always posted, so a reply never arrives inside the call that asked. A reply
// posted before Stop is dropped.
void Reply(uint64_t request, ArxProfileDataStatus status, base::DictValue body) {
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(body)), &json);
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](uint64_t generation, uint64_t request, ArxProfileDataStatus status,
                        std::string json) {
                       auto& state = State();
                       if (state.generation != generation || !state.reply) return;
                       state.reply(request, status, reinterpret_cast<const uint8_t*>(json.data()),
                                   json.size());
                     },
                     State().generation, request, status, std::move(json)));
}

void Fail(uint64_t request, ArxProfileDataStatus status, const char* reason) {
  base::DictValue body;
  if (reason) body.Set("reason", reason);
  Reply(request, status, std::move(body));
}

bool Ordinary(Profile* profile) {
  return profile && !profile->IsOffTheRecord();
}

// 0 is all time; anything else is a moment no later than a day from now.
std::optional<base::Time> Begin(double since) {
  if (!std::isfinite(since) || since < 0) return std::nullopt;
  if (since == 0) return base::Time();
  const base::Time begin = base::Time::FromSecondsSinceUnixEpoch(since);
  if (begin > base::Time::Now() + base::Days(1)) return std::nullopt;
  return begin;
}

int Clamped(BrowsingDataCounter::ResultInt value) {
  return static_cast<int>(std::clamp<BrowsingDataCounter::ResultInt>(value, 0, INT32_MAX));
}

// Counts the kinds Chromium can count, each with its own counter, and replies
// once they have all finished or the timeout passes. Owned by State().counts.
class CountJob final : public ProfileObserver {
 public:
  CountJob(Profile* profile, uint64_t request, base::Time begin)
      : profile_(profile), request_(request), begin_(begin) {
    observation_.Observe(profile);
  }

  void Start(uint32_t kinds) {
    struct Wanted {
      ArxBrowsingDataKind kind;
      const char* pref;
    };
    constexpr Wanted kWanted[] = {
        {ARX_BROWSING_DATA_COOKIES, browsing_data::prefs::kDeleteCookies},
        {ARX_BROWSING_DATA_CACHE, browsing_data::prefs::kDeleteCache},
        {ARX_BROWSING_DATA_AUTOFILL, browsing_data::prefs::kDeleteFormData},
        {ARX_BROWSING_DATA_SITE_SETTINGS, browsing_data::prefs::kDeleteSiteSettings},
    };
    starting_ = true;
    for (const auto& wanted : kWanted) {
      if (!(kinds & wanted.kind)) continue;
      auto counter = BrowsingDataCounterFactory::GetForProfileAndPref(profile_, wanted.pref);
      if (!counter) continue;
      ++pending_;
      counter->InitWithoutPref(begin_, base::BindRepeating(&CountJob::Counted,
                                                           weak_factory_.GetWeakPtr(),
                                                           wanted.kind));
      counters_.push_back(std::move(counter));
    }
    // Some counters answer inside Restart, so start them only once all exist.
    for (auto& counter : counters_) counter->Restart();
    starting_ = false;
    timeout_.Start(FROM_HERE, kCountTimeout,
                   base::BindOnce(&CountJob::Finish, weak_factory_.GetWeakPtr()));
    if (pending_ == 0) Finish();
  }

  void OnProfileWillBeDestroyed(Profile*) override {
    if (done_) return;
    done_ = true;
    Fail(request_, ARX_PROFILE_DATA_UNAVAILABLE, nullptr);
    Discard();
  }

 private:
  void Counted(ArxBrowsingDataKind kind, std::unique_ptr<BrowsingDataCounter::Result> result) {
    if (done_ || !result || !result->Finished() || (counted_ & kind)) return;
    counted_ |= kind;
    --pending_;
    const auto* finished = static_cast<const BrowsingDataCounter::FinishedResult*>(result.get());
    base::DictValue value;
    switch (kind) {
      case ARX_BROWSING_DATA_COOKIES:
        value.Set("sites", Clamped(finished->Value()));
        body_.Set("cookies", std::move(value));
        break;
      case ARX_BROWSING_DATA_CACHE: {
        const auto* cache = static_cast<const CacheCounter::CacheResult*>(result.get());
        value.Set("bytes", static_cast<double>(std::max<int64_t>(cache->cache_size(), 0)));
        value.Set("upperLimit", cache->is_upper_limit());
        body_.Set("cache", std::move(value));
        break;
      }
      case ARX_BROWSING_DATA_AUTOFILL: {
        const auto* autofill =
            static_cast<const browsing_data::AutofillCounter::AutofillResult*>(result.get());
        value.Set("entries", Clamped(autofill->Value()));
        value.Set("addresses", Clamped(autofill->num_addresses()));
        value.Set("cards", Clamped(autofill->num_credit_cards()));
        body_.Set("autofill", std::move(value));
        break;
      }
      case ARX_BROWSING_DATA_SITE_SETTINGS:
        value.Set("sites", Clamped(finished->Value()));
        body_.Set("siteSettings", std::move(value));
        break;
      default:
        break;
    }
    if (pending_ == 0 && !starting_) Finish();
  }

  void Finish() {
    if (done_) return;
    done_ = true;
    Reply(request_, ARX_PROFILE_DATA_OK, std::move(body_));
    // Never destroy a counter inside its own callback.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](uint64_t generation, uint64_t request) {
                         if (State().generation == generation) State().counts.erase(request);
                       },
                       State().generation, request_));
  }

  // Destroys this.
  void Discard() { State().counts.erase(request_); }

  raw_ptr<Profile> profile_;
  const uint64_t request_;
  const base::Time begin_;
  std::vector<std::unique_ptr<BrowsingDataCounter>> counters_;
  base::DictValue body_;
  uint32_t counted_ = 0;
  int pending_ = 0;
  bool starting_ = false;
  bool done_ = false;
  base::OneShotTimer timeout_;
  base::ScopedObservation<Profile, ProfileObserver> observation_{this};
  base::WeakPtrFactory<CountJob> weak_factory_{this};
};

struct Removal {
  uint64_t mask = 0;
  uint64_t origins = 0;
};

Removal RemovalFor(uint32_t kinds) {
  Removal removal;
  if (kinds & ARX_BROWSING_DATA_HISTORY) removal.mask |= chrome_browsing_data_remover::DATA_TYPE_HISTORY;
  if (kinds & ARX_BROWSING_DATA_DOWNLOADS) removal.mask |= BrowsingDataRemover::DATA_TYPE_DOWNLOADS;
  if (kinds & ARX_BROWSING_DATA_COOKIES) {
    removal.mask |= chrome_browsing_data_remover::DATA_TYPE_SITE_DATA;
    removal.origins |= BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB;
  }
  if (kinds & ARX_BROWSING_DATA_CACHE) removal.mask |= BrowsingDataRemover::DATA_TYPE_CACHE;
  if (kinds & ARX_BROWSING_DATA_AUTOFILL) removal.mask |= chrome_browsing_data_remover::DATA_TYPE_FORM_DATA;
  if (kinds & ARX_BROWSING_DATA_SITE_SETTINGS)
    removal.mask |= chrome_browsing_data_remover::DATA_TYPE_CONTENT_SETTINGS;
  if (!removal.origins) removal.origins = BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB;
  return removal;
}

base::ListValue FailedKinds(uint32_t kinds, uint64_t failed) {
  struct Name {
    ArxBrowsingDataKind kind;
    uint64_t mask;
    const char* name;
  };
  const Name names[] = {
      {ARX_BROWSING_DATA_HISTORY, chrome_browsing_data_remover::DATA_TYPE_HISTORY, "history"},
      {ARX_BROWSING_DATA_DOWNLOADS, BrowsingDataRemover::DATA_TYPE_DOWNLOADS, "downloads"},
      {ARX_BROWSING_DATA_COOKIES, chrome_browsing_data_remover::DATA_TYPE_SITE_DATA, "cookies"},
      {ARX_BROWSING_DATA_CACHE, BrowsingDataRemover::DATA_TYPE_CACHE, "cache"},
      {ARX_BROWSING_DATA_AUTOFILL, chrome_browsing_data_remover::DATA_TYPE_FORM_DATA, "autofill"},
      {ARX_BROWSING_DATA_SITE_SETTINGS, chrome_browsing_data_remover::DATA_TYPE_CONTENT_SETTINGS,
       "siteSettings"},
  };
  base::ListValue list;
  for (const auto& name : names)
    if ((kinds & name.kind) && (failed & name.mask)) list.Append(name.name);
  return list;
}

// One removal per profile, through its BrowsingDataRemover. Registered as an
// observer, so a remover destroyed first still reports, and one destroyed
// after this never calls it. Owned by State().clears.
class ClearJob final : public BrowsingDataRemover::Observer, public ProfileObserver {
 public:
  // A filter limits the removal to one site, named in the reply as domain.
  ClearJob(Profile* profile, uint64_t request, uint32_t kinds,
           std::unique_ptr<content::BrowsingDataFilterBuilder> filter = nullptr,
           std::string domain = {})
      : profile_(profile), remover_(profile->GetBrowsingDataRemover()), request_(request),
        kinds_(kinds), filter_(std::move(filter)), domain_(std::move(domain)) {
    observation_.Observe(profile);
    remover_->AddObserver(this);
  }

  ~ClearJob() override {
    if (remover_) remover_->RemoveObserver(this);
  }

  void Start(base::Time begin) {
    const Removal removal = RemovalFor(kinds_);
    if (filter_) {
      remover_->RemoveWithFilterAndReply(begin, base::Time::Max(), removal.mask, removal.origins,
                                         std::move(filter_), this);
      return;
    }
    remover_->RemoveAndReply(begin, base::Time::Max(), removal.mask, removal.origins, this);
  }

  void OnBrowsingDataRemoverDone(uint64_t failed_data_types) override {
    if (done_) return;
    done_ = true;
    base::DictValue body;
    if (!domain_.empty()) body.Set("domain", domain_);
    body.Set("failed", FailedKinds(kinds_, failed_data_types));
    Reply(request_, ARX_PROFILE_DATA_OK, std::move(body));
    // The remover is still notifying; leave before it returns.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](uint64_t generation, base::WeakPtr<ClearJob> job) {
                         if (State().generation != generation || !job) return;
                         State().clears.erase(job->profile_);
                       },
                       State().generation, weak_factory_.GetWeakPtr()));
  }

  void OnProfileWillBeDestroyed(Profile* profile) override {
    if (!done_) {
      done_ = true;
      Fail(request_, ARX_PROFILE_DATA_UNAVAILABLE, nullptr);
    }
    // Destroys this.
    State().clears.erase(profile);
  }

 private:
  raw_ptr<Profile> profile_;
  raw_ptr<BrowsingDataRemover> remover_;
  const uint64_t request_;
  const uint32_t kinds_;
  std::unique_ptr<content::BrowsingDataFilterBuilder> filter_;
  const std::string domain_;
  bool done_ = false;
  base::ScopedObservation<Profile, ProfileObserver> observation_{this};
  base::WeakPtrFactory<ClearJob> weak_factory_{this};
};

// The site a site clear removes: an http(s) address's registrable domain, or its
// host when it has none (an IP address, localhost), which is what
// BrowsingDataFilterBuilder::AddRegisterableDomain accepts. Empty otherwise.
std::string SiteDomain(const char* text) {
  if (!text) return {};
  const size_t length = strnlen(text, kMaximumURLBytes + 1);
  if (length == 0 || length > kMaximumURLBytes) return {};
  const GURL url(std::string(text, length));
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || !url.has_host() || url.has_username() ||
      url.has_password())
    return {};
  std::string domain = net::registry_controlled_domains::GetDomainAndRegistry(
      url, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  return domain.empty() ? std::string(url.host()) : domain;
}

base::DictValue DownloadSettings(Profile* profile) {
  auto* prefs = DownloadPrefs::FromBrowserContext(profile);
  base::DictValue body;
  body.Set("directory", prefs->DownloadPath().value());
  body.Set("ask", prefs->PromptForDownload());
  body.Set("defaultDirectory", prefs->GetDefaultDownloadDirectoryForProfile().value());
  const auto* prompt = profile->GetPrefs()->FindPreference(prefs::kPromptForDownload);
  body.Set("managed", prefs->IsDownloadPathManaged() || (prompt && prompt->IsManaged()));
  return body;
}

bool DownloadSettingsManaged(Profile* profile) {
  const auto* prompt = profile->GetPrefs()->FindPreference(prefs::kPromptForDownload);
  return DownloadPrefs::FromBrowserContext(profile)->IsDownloadPathManaged() ||
         (prompt && prompt->IsManaged());
}

void ApplyDownloadSettings(base::WeakPtr<Profile> weak, uint64_t generation, uint64_t request,
                           base::FilePath directory, bool ask, bool exists) {
  if (State().generation != generation) return;
  Profile* profile = weak.get();
  if (!Ordinary(profile)) return Fail(request, ARX_PROFILE_DATA_UNAVAILABLE, nullptr);
  if (!exists) return Fail(request, ARX_PROFILE_DATA_INVALID, "directory");
  // Policy may have arrived while the folder was checked.
  if (DownloadSettingsManaged(profile)) return Fail(request, ARX_PROFILE_DATA_MANAGED, "managed");
  if (!directory.empty()) DownloadPrefs::FromBrowserContext(profile)->SetDownloadPath(directory);
  profile->GetPrefs()->SetBoolean(prefs::kPromptForDownload, ask);
  Reply(request, ARX_PROFILE_DATA_OK, DownloadSettings(profile));
}
}  // namespace

void StartProfileData(ProfileDataReply reply) {
  State().reply = reply;
}

void StopProfileData() {
  auto& state = State();
  ++state.generation;
  state.counts.clear();
  state.clears.clear();
  state.reply = nullptr;
}

void CountBrowsingData(Profile* profile, uint64_t request, uint32_t kinds, double since) {
  if (!Ordinary(profile)) return Fail(request, ARX_PROFILE_DATA_UNAVAILABLE, nullptr);
  if (!kinds || (kinds & ~kAllKinds)) return Fail(request, ARX_PROFILE_DATA_INVALID, "kinds");
  const auto begin = Begin(since);
  if (!begin) return Fail(request, ARX_PROFILE_DATA_INVALID, "since");
  auto& counts = State().counts;
  if (counts.size() >= kMaximumJobs || counts.contains(request))
    return Fail(request, ARX_PROFILE_DATA_BUSY, nullptr);
  auto* job = counts.emplace(request, std::make_unique<CountJob>(profile, request, *begin))
                  .first->second.get();
  job->Start(kinds);
}

void ClearBrowsingData(Profile* profile, uint64_t request, uint32_t kinds, double since) {
  if (!Ordinary(profile)) return Fail(request, ARX_PROFILE_DATA_UNAVAILABLE, nullptr);
  if (!kinds || (kinds & ~kAllKinds)) return Fail(request, ARX_PROFILE_DATA_INVALID, "kinds");
  const auto begin = Begin(since);
  if (!begin) return Fail(request, ARX_PROFILE_DATA_INVALID, "since");
  // As Chrome's dialog: a policy that keeps history keeps download history too.
  if ((kinds & (ARX_BROWSING_DATA_HISTORY | ARX_BROWSING_DATA_DOWNLOADS)) &&
      !profile->GetPrefs()->GetBoolean(prefs::kAllowDeletingBrowserHistory))
    return Fail(request, ARX_PROFILE_DATA_MANAGED, "history");
  auto& clears = State().clears;
  if (clears.contains(profile) || clears.size() >= kMaximumJobs)
    return Fail(request, ARX_PROFILE_DATA_BUSY, nullptr);
  auto* job =
      clears.emplace(profile, std::make_unique<ClearJob>(profile, request, kinds)).first->second.get();
  job->Start(*begin);
}

void ReadDownloadSettings(Profile* profile, uint64_t request) {
  if (!Ordinary(profile)) return Fail(request, ARX_PROFILE_DATA_UNAVAILABLE, nullptr);
  Reply(request, ARX_PROFILE_DATA_OK, DownloadSettings(profile));
}

void SetDownloadSettings(Profile* profile, uint64_t request, const char* directory, bool ask) {
  if (!Ordinary(profile)) return Fail(request, ARX_PROFILE_DATA_UNAVAILABLE, nullptr);
  if (DownloadSettingsManaged(profile)) return Fail(request, ARX_PROFILE_DATA_MANAGED, "managed");
  std::string text;
  if (directory) {
    const size_t length = strnlen(directory, kMaximumPathBytes + 1);
    if (length > kMaximumPathBytes) return Fail(request, ARX_PROFILE_DATA_INVALID, "directory");
    text.assign(directory, length);
  }
  const base::FilePath path(text);
  if (!text.empty() && (!path.IsAbsolute() || path.ReferencesParent()))
    return Fail(request, ARX_PROFILE_DATA_INVALID, "directory");
  const uint64_t generation = State().generation;
  if (text.empty())
    return ApplyDownloadSettings(profile->GetWeakPtr(), generation, request, path, ask, true);
  // The folder check touches the disk, so it runs off the UI thread.
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock()}, base::BindOnce(&base::DirectoryExists, path),
      base::BindOnce(&ApplyDownloadSettings, profile->GetWeakPtr(), generation, request, path,
                     ask));
}
void SiteDataScope(Profile* profile, uint64_t request, const char* url) {
  if (!Ordinary(profile)) return Fail(request, ARX_PROFILE_DATA_UNAVAILABLE, nullptr);
  const std::string domain = SiteDomain(url);
  if (domain.empty()) return Fail(request, ARX_PROFILE_DATA_INVALID, "url");
  base::DictValue body;
  body.Set("domain", domain);
  Reply(request, ARX_PROFILE_DATA_OK, std::move(body));
}

void ClearSiteData(Profile* profile, uint64_t request, const char* url, uint32_t kinds) {
  if (!Ordinary(profile)) return Fail(request, ARX_PROFILE_DATA_UNAVAILABLE, nullptr);
  if (!kinds || (kinds & ~kSiteKinds)) return Fail(request, ARX_PROFILE_DATA_INVALID, "kinds");
  std::string domain = SiteDomain(url);
  if (domain.empty()) return Fail(request, ARX_PROFILE_DATA_INVALID, "url");
  auto& clears = State().clears;
  if (clears.contains(profile) || clears.size() >= kMaximumJobs)
    return Fail(request, ARX_PROFILE_DATA_BUSY, nullptr);
  auto filter = content::BrowsingDataFilterBuilder::Create(
      content::BrowsingDataFilterBuilder::Mode::kDelete);
  filter->AddRegisterableDomain(domain);
  auto* job = clears
                  .emplace(profile, std::make_unique<ClearJob>(profile, request, kinds,
                                                               std::move(filter), std::move(domain)))
                  .first->second.get();
  job->Start(base::Time());
}
}  // namespace arx
