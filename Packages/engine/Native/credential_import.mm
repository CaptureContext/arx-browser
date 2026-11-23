#include "chrome/browser/arx/credential_import.h"

#include <algorithm>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/types/expected.h"
#include "base/values.h"
#include "chrome/browser/arx/credential_import_keys.h"
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/keyed_service/core/service_access_type.h"
#include "components/password_manager/core/browser/password_form.h"
#include "components/password_manager/core/browser/password_manager_util.h"
#include "components/password_manager/core/browser/password_store/password_store_consumer.h"
#include "components/password_manager/core/browser/password_store/password_store_interface.h"
#include "components/password_manager/core/browser/password_store/stored_credential.h"
#include "components/password_manager/core/browser/password_string.h"
#include "content/public/browser/storage_partition.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_access_result.h"
#include "net/cookies/cookie_constants.h"
#include "net/cookies/cookie_inclusion_status.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_partition_key.h"
#include "net/cookies/unique_cookie_key.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "url/gurl.h"

namespace arx {
namespace {
using credential_import::CookieKey;
using credential_import::PasswordKey;
using password_manager::PasswordForm;
using password_manager::PasswordStoreBackendError;
using password_manager::PasswordStoreConsumer;
using password_manager::PasswordStoreInterface;
using password_manager::StoredCredential;

constexpr size_t kMaximumPending = 16;
constexpr size_t kMaximumKeyBytes = 64;
// A store or cookie manager that never answers (its profile went away) fails
// the request instead of leaving it pending.
constexpr base::TimeDelta kJobTimeout = base::Seconds(120);

void Fail(uint64_t request, ArxCredentialImportStatus status, const char* reason);
Profile* CurrentProfile(const std::string& key);

// One request's work. Owned by State().jobs until its reply.
class Job : public PasswordStoreConsumer {
 public:
  Job(uint64_t request, std::string key) : request_(request), key_(std::move(key)) {
    timeout_.Start(FROM_HERE, kJobTimeout, base::BindOnce([](uint64_t request) {
      Fail(request, ARX_CREDENTIAL_IMPORT_FAILED, "timeout");
    }, request));
  }
  ~Job() override = default;

  uint64_t request() const { return request_; }
  const std::string& key() const { return key_; }

  // Fetches the profile store's saved logins, then runs `next` with them.
  void FetchLogins(scoped_refptr<PasswordStoreInterface> store,
                   base::OnceCallback<void(std::vector<StoredCredential>)> next) {
    store_ = std::move(store);
    logins_ = std::move(next);
    store_->GetAutofillableLogins(weak_.GetWeakPtr());
  }

  void OnGetPasswordStoreResultsOrErrorFrom(
      PasswordStoreInterface* store,
      base::expected<std::vector<StoredCredential>, PasswordStoreBackendError> results) override {
    if (!logins_) return;
    if (!results.has_value()) return Fail(request_, ARX_CREDENTIAL_IMPORT_FAILED, "store");
    if (!CurrentProfile(key_)) return Fail(request_, ARX_CREDENTIAL_IMPORT_UNAVAILABLE, "profile");
    std::move(logins_).Run(std::move(results.value()));
  }

  PasswordStoreInterface* store() { return store_.get(); }
  base::WeakPtr<Job> GetWeakPtr() { return weak_.GetWeakPtr(); }

 private:
  const uint64_t request_;
  const std::string key_;
  scoped_refptr<PasswordStoreInterface> store_;
  base::OnceCallback<void(std::vector<StoredCredential>)> logins_;
  base::OneShotTimer timeout_;
  base::WeakPtrFactory<Job> weak_{this};
};

struct ImportState {
  CredentialImportReply reply = nullptr;
  CredentialImportProfile profile = nullptr;
  // Requests that still owe their one reply, with the profile key each holds.
  std::map<uint64_t, std::string> pending;
  std::map<uint64_t, std::unique_ptr<Job>> jobs;
  // OK bodies for requests whose write has started: any later failure (a store
  // error, a lost profile, a dropped reply, the timeout) replies with this
  // instead, naming everything that may have persisted as "unconfirmed", so
  // the app always keeps keys it can undo.
  std::map<uint64_t, base::DictValue> fallbacks;
};

ImportState& State() {
  static base::NoDestructor<ImportState> state;
  return *state;
}

std::string Write(base::DictValue body) {
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(body)), &json);
  return json;
}

// Replies once per request and drops its job. Posted, so a reply never runs
// inside the call that started it or inside a store or mojo callback.
void Reply(uint64_t request, ArxCredentialImportStatus status,
           base::DictValue body = base::DictValue()) {
  auto& state = State();
  if (!state.pending.erase(request)) return;
  state.fallbacks.erase(request);
  if (auto job = state.jobs.find(request); job != state.jobs.end()) {
    // The job may be the caller; destroy it after this task.
    base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE,
                                                                 std::move(job->second));
    state.jobs.erase(job);
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
      [](uint64_t request, ArxCredentialImportStatus status, std::string json) {
        if (auto reply = State().reply)
          reply(request, status, reinterpret_cast<const uint8_t*>(json.data()), json.size());
      }, request, status, Write(std::move(body))));
}

void Fail(uint64_t request, ArxCredentialImportStatus status, const char* reason) {
  auto& fallbacks = State().fallbacks;
  if (auto fallback = fallbacks.find(request); fallback != fallbacks.end()) {
    base::DictValue body = std::move(fallback->second);
    fallbacks.erase(fallback);
    return Reply(request, ARX_CREDENTIAL_IMPORT_OK, std::move(body));
  }
  base::DictValue body;
  body.Set("reason", reason);
  Reply(request, status, std::move(body));
}

// The profile for a pending request's key, or null once it has gone away.
Profile* CurrentProfile(const std::string& key) {
  auto& state = State();
  return state.profile ? state.profile(key.c_str()) : nullptr;
}

// Admits a request: replies at once (posted) and returns nullopt when the
// engine is stopped, the profile isn't an ordinary one, too many requests are
// pending or the profile already has one.
std::optional<std::string> Begin(uint64_t request, const char* profile_key) {
  auto& state = State();
  if (!state.reply || state.pending.contains(request)) return std::nullopt;
  const auto key = credential_import::Bounded(profile_key, kMaximumKeyBytes);
  state.pending.emplace(request, key ? std::string(*key) : std::string());
  if (!key || !CurrentProfile(std::string(*key))) {
    Fail(request, ARX_CREDENTIAL_IMPORT_UNAVAILABLE, "profile");
    return std::nullopt;
  }
  if (state.pending.size() > kMaximumPending) {
    Fail(request, ARX_CREDENTIAL_IMPORT_BUSY, "pending");
    return std::nullopt;
  }
  for (const auto& [other, other_key] : state.pending)
    if (other != request && other_key == *key) {
      Fail(request, ARX_CREDENTIAL_IMPORT_BUSY, "profile");
      return std::nullopt;
    }
  return std::string(*key);
}

base::Time FromStorageTime(int64_t microseconds) {
  return microseconds ? base::Time::FromDeltaSinceWindowsEpoch(base::Microseconds(microseconds))
                      : base::Time();
}

std::string StoreTime(base::Time time) {
  return base::NumberToString(time.ToDeltaSinceWindowsEpoch().InMicroseconds());
}

base::DictValue PasswordKeyValue(const PasswordKey& key, base::Time created) {
  base::DictValue value;
  value.Set("signonRealm", key.signon_realm);
  value.Set("username", key.username);
  value.Set("dateCreated", StoreTime(created));
  return value;
}

base::DictValue CookieKeyValue(const CookieKey& key) {
  base::DictValue value;
  value.Set("domain", key.domain);
  value.Set("name", key.name);
  value.Set("path", key.path);
  value.Set("topFrameSiteKey", key.top_frame_site_key);
  value.Set("hasCrossSiteAncestor", key.has_cross_site_ancestor);
  value.Set("sourceScheme", key.source_scheme);
  value.Set("sourcePort", key.source_port);
  return value;
}

base::ListValue CookieKeyList(const std::vector<CookieKey>& keys) {
  base::ListValue list;
  for (const auto& key : keys) list.Append(CookieKeyValue(key));
  return list;
}

std::optional<CookieKey> CookieKeyFrom(const base::Value& value) {
  const auto* dict = value.GetIfDict();
  if (!dict) return std::nullopt;
  const auto* domain = dict->FindString("domain");
  const auto* name = dict->FindString("name");
  const auto* path = dict->FindString("path");
  const auto* site = dict->FindString("topFrameSiteKey");
  const auto cross = dict->FindBool("hasCrossSiteAncestor");
  const auto scheme = dict->FindInt("sourceScheme");
  const auto port = dict->FindInt("sourcePort");
  if (!domain || !name || !path || !site || !cross || !scheme || !port) return std::nullopt;
  return credential_import::Normalized({*domain, *name, *path, *site, *cross, *scheme, *port});
}

std::optional<std::pair<PasswordKey, base::Time>> PasswordKeyFrom(const base::Value& value) {
  const auto* dict = value.GetIfDict();
  if (!dict) return std::nullopt;
  const auto* realm = dict->FindString("signonRealm");
  const auto* username = dict->FindString("username");
  const auto* created = dict->FindString("dateCreated");
  int64_t microseconds = 0;
  if (!realm || !username || !created || !base::StringToInt64(*created, &microseconds) ||
      microseconds <= 0) return std::nullopt;
  return std::make_pair(PasswordKey{*realm, *username}, FromStorageTime(microseconds));
}

// A live cookie's key, or nullopt for one whose partition can't be serialized
// (an opaque or nonced partition), which an import never sets.
std::optional<CookieKey> KeyOf(const net::CanonicalCookie& cookie) {
  const auto partition = net::CookiePartitionKey::Serialize(cookie.PartitionKey());
  if (!partition.has_value()) return std::nullopt;
  return credential_import::Normalized({cookie.Domain(), cookie.Name(), cookie.Path(),
                                        partition->TopLevelSite(),
                                        partition->has_cross_site_ancestor(),
                                        static_cast<int32_t>(cookie.SourceScheme()),
                                        cookie.SourcePort()});
}

network::mojom::CookieManager* CookieManagerFor(const std::string& key) {
  auto* profile = CurrentProfile(key);
  return profile ? profile->GetDefaultStoragePartition()->GetCookieManagerForBrowserProcess()
                 : nullptr;
}

scoped_refptr<PasswordStoreInterface> PasswordStoreFor(const std::string& key) {
  auto* profile = CurrentProfile(key);
  return profile ? ProfilePasswordStoreFactory::GetForProfile(profile,
                                                              ServiceAccessType::EXPLICIT_ACCESS)
                 : nullptr;
}

Job* AddJob(uint64_t request, const std::string& key) {
  auto job = std::make_unique<Job>(request, key);
  auto* raw = job.get();
  State().jobs[request] = std::move(job);
  return raw;
}

PasswordKey KeyOf(const StoredCredential& form) {
  return {form.signon_realm, base::UTF16ToUTF8(form.username_value)};
}

int64_t Microseconds(base::Time time) {
  return time.ToDeltaSinceWindowsEpoch().InMicroseconds();
}

credential_import::StoredPassword StampsOf(const StoredCredential& form) {
  return {KeyOf(form), Microseconds(form.date_created), Microseconds(form.date_password_modified)};
}

// Reads every cookie of the job's profile and runs `next` with them. A lost
// cookie manager runs it with none, which callers treat as UNAVAILABLE.
void FetchCookies(base::WeakPtr<Job> job,
                  base::OnceCallback<void(Job&, const std::vector<net::CanonicalCookie>&)> next) {
  auto* manager = job ? CookieManagerFor(job->key()) : nullptr;
  if (!manager) {
    if (job) Fail(job->request(), ARX_CREDENTIAL_IMPORT_UNAVAILABLE, "profile");
    return;
  }
  // A dropped reply (the network service went away) fails the request: an empty
  // list would read as "no cookies" and let check or undo report success.
  const uint64_t request = job->request();
  manager->GetAllCookies(mojo::WrapCallbackWithDropHandler(
      base::BindOnce(
          [](base::WeakPtr<Job> job,
             base::OnceCallback<void(Job&, const std::vector<net::CanonicalCookie>&)> next,
             const std::vector<net::CanonicalCookie>& cookies) {
            if (!job) return;
            if (!CurrentProfile(job->key()))
              return Fail(job->request(), ARX_CREDENTIAL_IMPORT_UNAVAILABLE, "profile");
            std::move(next).Run(*job, cookies);
          },
          job, std::move(next)),
      base::BindOnce([](uint64_t request) {
        Fail(request, ARX_CREDENTIAL_IMPORT_FAILED, "cookies");
      }, request)));
}

// --- import_password_records ---

base::DictValue PasswordsBody(const std::vector<PasswordKey>& imported,
                              const std::vector<PasswordKey>& unconfirmed, base::Time created,
                              size_t conflicts, size_t skipped) {
  base::ListValue list, unsure;
  for (const auto& key : imported) list.Append(PasswordKeyValue(key, created));
  for (const auto& key : unconfirmed) unsure.Append(PasswordKeyValue(key, created));
  base::DictValue body;
  body.Set("imported", std::move(list));
  body.Set("unconfirmed", std::move(unsure));
  body.Set("conflicts", static_cast<int>(conflicts));
  body.Set("skipped", static_cast<int>(skipped));
  return body;
}

void FinishPasswords(uint64_t request, std::vector<PasswordKey> imported, base::Time created,
                     size_t conflicts, size_t skipped) {
  Reply(request, ARX_CREDENTIAL_IMPORT_OK, PasswordsBody(imported, {}, created, conflicts, skipped));
}

// A row as the store would keep it, or nullopt when it would be skipped. The
// password moves straight from the borrowed UTF-8 into a PasswordString.
std::optional<StoredCredential> PasswordRow(const ArxImportedPassword& record, base::Time created) {
  using namespace credential_import;
  const auto url_text = Bounded(record.url, kMaximumURLBytes);
  const auto realm = Bounded(record.signon_realm, kMaximumURLBytes);
  const auto username = Bounded(record.username, kMaximumUsernameBytes);
  const auto password = Bounded(record.password, kMaximumPasswordBytes);
  if (!url_text || !realm || !username || !password || password->empty()) return std::nullopt;
  const GURL url = password_manager_util::StripAuthAndParams(GURL(*url_text));
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || url.host().empty()) return std::nullopt;
  if (password_manager_util::GetSignonRealm(url) != *realm) return std::nullopt;

  StoredCredential form;
  form.scheme = PasswordForm::Scheme::kHtml;
  form.url = url;
  form.signon_realm = std::string(*realm);
  form.username_value = base::UTF8ToUTF16(*username);
  std::u16string value = base::UTF8ToUTF16(*password);
  form.password_value = password_manager::PasswordString(std::move(value));
  form.date_created = created;
  form.date_password_modified = created;
  form.type = PasswordForm::Type::kImported;
  form.in_store = PasswordForm::Store::kProfileStore;
  return form;
}

void AddPasswords(std::vector<std::optional<StoredCredential>> rows, base::Time created,
                  Job* owner, std::vector<StoredCredential> saved) {
  Job& job = *owner;
  std::set<PasswordKey> existing;
  for (const auto& form : saved) existing.insert(KeyOf(form));
  std::vector<std::optional<PasswordKey>> keys;
  keys.reserve(rows.size());
  for (const auto& row : rows) keys.push_back(row ? std::optional(KeyOf(*row)) : std::nullopt);
  const auto outcomes = credential_import::ClassifyPasswords(keys, std::move(existing));

  std::vector<StoredCredential> added;
  std::vector<PasswordKey> imported;
  size_t conflicts = 0, skipped = 0;
  for (size_t index = 0; index < rows.size(); ++index) {
    switch (outcomes[index]) {
      case credential_import::PasswordOutcome::kImported:
        imported.push_back(*keys[index]);
        added.push_back(std::move(*rows[index]));
        break;
      case credential_import::PasswordOutcome::kConflict: ++conflicts; break;
      case credential_import::PasswordOutcome::kSkipped: ++skipped; break;
    }
  }
  // Rows that won't be added drop their passwords now.
  rows.clear();
  if (added.empty()) return FinishPasswords(job.request(), {}, created, conflicts, skipped);
  // From here on a failure can't prove nothing was stored: it replies with
  // every attempted row as unconfirmed (and skipped), which the app keeps as
  // undo keys. Undo removes only entries that carry this import's stamp.
  State().fallbacks[job.request()] =
      PasswordsBody({}, imported, created, conflicts, skipped + imported.size());
  // The store runs the completion even after a backend error, so read the
  // entries back and report only those stored with this import's stamp; the
  // rest are proven absent and count as skipped.
  job.store()->AddLogins(std::move(added),
      base::BindOnce(
          [](base::WeakPtr<Job> job, std::vector<PasswordKey> attempted, base::Time created,
             size_t conflicts, size_t skipped) {
            if (!job) return;
            scoped_refptr<PasswordStoreInterface> store = job->store();
            job->FetchLogins(std::move(store), base::BindOnce(
                [](uint64_t request, std::vector<PasswordKey> attempted, base::Time created,
                   size_t conflicts, size_t skipped, std::vector<StoredCredential> saved) {
                  std::vector<credential_import::StoredPassword> stored;
                  stored.reserve(saved.size());
                  for (const auto& form : saved) stored.push_back(StampsOf(form));
                  auto confirmed = credential_import::ConfirmedImports(attempted, stored,
                                                                       Microseconds(created));
                  skipped += attempted.size() - confirmed.size();
                  FinishPasswords(request, std::move(confirmed), created, conflicts, skipped);
                },
                job->request(), std::move(attempted), created, conflicts, skipped));
          },
          job.GetWeakPtr(), std::move(imported), created, conflicts, skipped));
}

// --- import_cookies ---

struct CookieCandidate {
  CookieKey key;
  std::unique_ptr<net::CanonicalCookie> cookie;  // null: rejected before setting
  GURL source;
};

std::optional<CookieCandidate> CookieRow(const ArxImportedCookie& record) {
  using namespace credential_import;
  // Read generously, judge per row: a long domain, name, value or site rejects
  // only its own cookie, and a long path is kept, as Chromium stores it.
  const auto domain = Bounded(record.domain, kMaximumFieldReadBytes);
  const auto name = Bounded(record.name, kMaximumFieldReadBytes);
  const auto value = Bounded(record.value, kMaximumFieldReadBytes);
  const auto path = Bounded(record.path, kMaximumFieldReadBytes);
  const auto site = Bounded(record.top_frame_site_key, kMaximumFieldReadBytes);
  // Without these there's no key to report the cookie under: the call is invalid.
  if (!domain || !name || !path || !site) return std::nullopt;

  CookieCandidate candidate;
  candidate.key = Normalized({std::string(*domain), std::string(*name), std::string(*path),
                              std::string(*site), record.has_cross_site_ancestor,
                              record.source_scheme, record.source_port});
  if (!value || name->size() + value->size() > kMaximumNameAndValueBytes ||
      site->size() > kMaximumSiteBytes || !ValidCookieDomain(*domain) || !ValidSameSite(record.same_site) ||
      !ValidPriority(record.priority) || !ValidSourceScheme(record.source_scheme) ||
      !ValidSourcePort(record.source_port) || record.expires_utc <= 0)
    return candidate;

  auto partition = net::CookiePartitionKey::FromStorage(std::string(*site),
                                                        record.has_cross_site_ancestor);
  if (!partition.has_value()) return candidate;
  const GURL source(CookieSourceURL(*domain, record.secure, record.source_scheme,
                                    record.source_port));
  if (!source.is_valid()) return candidate;
  const auto times = InsertionTimes(record.creation_utc, record.expires_utc,
                                    record.last_access_utc, Microseconds(base::Time::Now()));
  const base::Time creation = FromStorageTime(times.creation);
  candidate.cookie = net::CanonicalCookie::FromStorage(
      std::string(*name), std::string(*value), std::string(*domain), std::string(*path),
      creation, FromStorageTime(times.effective_expiry), FromStorageTime(times.last_access),
      creation, record.secure, record.http_only,
      static_cast<net::CookieSameSite>(record.same_site),
      static_cast<net::CookiePriority>(record.priority), std::move(partition.value()),
      static_cast<net::CookieSourceScheme>(record.source_scheme), record.source_port,
      net::CookieSourceType::kOther, net::CanonicalCookieFromStorageCallSite::kCookieManager);
  if (candidate.cookie && candidate.cookie->IsExpired(base::Time::Now())) candidate.cookie.reset();
  candidate.source = source;
  return candidate;
}

struct CookieWrite {
  std::vector<CookieKey> accepted, existing, rejected;
  // Sets whose reply never came: maybe stored. Also listed as rejected.
  std::vector<CookieKey> unconfirmed;
  size_t outstanding = 0;
};

base::DictValue CookiesBody(const CookieWrite& write) {
  base::DictValue body;
  body.Set("accepted", CookieKeyList(write.accepted));
  body.Set("existing", CookieKeyList(write.existing));
  body.Set("rejected", CookieKeyList(write.rejected));
  body.Set("unconfirmed", CookieKeyList(write.unconfirmed));
  return body;
}

void FinishCookies(uint64_t request, const CookieWrite& write) {
  Reply(request, ARX_CREDENTIAL_IMPORT_OK, CookiesBody(write));
}

void SetCookies(std::vector<CookieCandidate> candidates, Job& job,
                const std::vector<net::CanonicalCookie>& live) {
  auto* manager = CookieManagerFor(job.key());
  if (!manager) return Fail(job.request(), ARX_CREDENTIAL_IMPORT_UNAVAILABLE, "profile");
  // "Existing" follows Chromium's own identity (IsEquivalent), so a set never
  // overwrites a cookie the profile already had, partitioned or scheme-bound.
  std::set<net::UniqueCookieKey> taken;
  for (const auto& cookie : live) taken.insert(cookie.UniqueKey());

  auto write = std::make_shared<CookieWrite>();
  std::vector<std::pair<std::unique_ptr<net::CanonicalCookie>, GURL>> sets;
  std::vector<CookieKey> keys;
  for (auto& candidate : candidates) {
    if (!candidate.cookie) {
      write->rejected.push_back(std::move(candidate.key));
    } else if (!taken.insert(candidate.cookie->UniqueKey()).second) {
      write->existing.push_back(std::move(candidate.key));
    } else {
      keys.push_back(std::move(candidate.key));
      sets.emplace_back(std::move(candidate.cookie), std::move(candidate.source));
    }
  }
  candidates.clear();
  if (sets.empty()) return FinishCookies(job.request(), *write);

  // From here on a failure (the timeout, a lost profile) replies with every
  // cookie being set as rejected and unconfirmed, so the app keeps undo keys.
  {
    CookieWrite fallback = *write;
    fallback.rejected.insert(fallback.rejected.end(), keys.begin(), keys.end());
    fallback.unconfirmed = keys;
    State().fallbacks[job.request()] = CookiesBody(fallback);
  }
  write->outstanding = sets.size();
  for (size_t index = 0; index < sets.size(); ++index) {
    manager->SetCanonicalCookie(
        *sets[index].first, sets[index].second, net::CookieOptions::MakeAllInclusive(),
        mojo::WrapCallbackWithDropHandler(
            base::BindOnce(
                [](base::WeakPtr<Job> job, std::shared_ptr<CookieWrite> write, CookieKey key,
                   net::CookieAccessResult result) {
                  (result.status.IsInclude() ? write->accepted : write->rejected)
                      .push_back(std::move(key));
                  if (--write->outstanding == 0 && job) FinishCookies(job->request(), *write);
                },
                job.GetWeakPtr(), write, keys[index]),
            // A dropped reply (the network service went away) may or may not have
            // stored the cookie: rejected for the report, unconfirmed for undo.
            base::BindOnce(
                [](base::WeakPtr<Job> job, std::shared_ptr<CookieWrite> write, CookieKey key) {
                  write->rejected.push_back(key);
                  write->unconfirmed.push_back(std::move(key));
                  if (--write->outstanding == 0 && job) FinishCookies(job->request(), *write);
                },
                job.GetWeakPtr(), write, keys[index])));
  }
}

// --- check_cookies and undo_credential_import ---

std::set<CookieKey> LiveKeys(const std::vector<net::CanonicalCookie>& cookies, base::Time now) {
  std::set<CookieKey> live;
  for (const auto& cookie : cookies)
    if (!cookie.IsExpired(now))
      if (auto key = KeyOf(cookie)) live.insert(std::move(*key));
  return live;
}

std::optional<std::vector<CookieKey>> CookieKeysFrom(const base::ListValue* list) {
  std::vector<CookieKey> keys;
  if (!list) return keys;
  if (list->size() > credential_import::kMaximumCookies) return std::nullopt;
  for (const auto& item : *list) {
    auto key = CookieKeyFrom(item);
    if (!key) return std::nullopt;
    keys.push_back(std::move(*key));
  }
  return keys;
}

// After the deletions, reads the cookies again: undo succeeds only when none
// of the matched cookies is still there, so the app never drops a batch whose
// cookies survived.
void VerifyCookiesGone(std::set<CookieKey> matched, size_t removed_passwords, Job& job,
                       const std::vector<net::CanonicalCookie>& live) {
  for (const auto& cookie : live)
    if (auto key = KeyOf(cookie); key && matched.contains(*key))
      return Fail(job.request(), ARX_CREDENTIAL_IMPORT_FAILED, "cookies");
  base::DictValue body;
  body.Set("removed", static_cast<int>(removed_passwords + matched.size()));
  Reply(job.request(), ARX_CREDENTIAL_IMPORT_OK, std::move(body));
}

void DeleteCookies(std::set<CookieKey> keys, size_t removed_passwords, Job& job,
                   const std::vector<net::CanonicalCookie>& live) {
  auto* manager = CookieManagerFor(job.key());
  if (!manager) return Fail(job.request(), ARX_CREDENTIAL_IMPORT_UNAVAILABLE, "profile");
  std::vector<const net::CanonicalCookie*> matches;
  std::set<CookieKey> matched;
  for (const auto& cookie : live)
    if (auto key = KeyOf(cookie); key && keys.contains(*key)) {
      matches.push_back(&cookie);
      matched.insert(std::move(*key));
    }
  if (matches.empty()) {
    base::DictValue body;
    body.Set("removed", static_cast<int>(removed_passwords));
    return Reply(job.request(), ARX_CREDENTIAL_IMPORT_OK, std::move(body));
  }

  struct Deletion {
    std::set<CookieKey> matched;
    size_t removed_passwords = 0, outstanding = 0;
  };
  auto deletion = std::make_shared<Deletion>();
  deletion->matched = std::move(matched);
  deletion->removed_passwords = removed_passwords;
  deletion->outstanding = matches.size();
  for (const auto* cookie : matches)
    manager->DeleteCanonicalCookie(
        *cookie, mojo::WrapCallbackWithDropHandler(
            base::BindOnce(
                [](base::WeakPtr<Job> job, std::shared_ptr<Deletion> deletion, bool) {
                  if (--deletion->outstanding != 0 || !job) return;
                  FetchCookies(job, base::BindOnce(&VerifyCookiesGone, deletion->matched,
                                                   deletion->removed_passwords));
                },
                job.GetWeakPtr(), deletion),
            // A dropped reply fails undo, so the app keeps the batch to try again.
            base::BindOnce([](uint64_t request) {
              Fail(request, ARX_CREDENTIAL_IMPORT_FAILED, "cookies");
            }, job.request())));
}
}  // namespace

void StartCredentialImport(CredentialImportReply reply, CredentialImportProfile profile) {
  State().reply = reply;
  State().profile = profile;
}

void StopCredentialImport() {
  auto& state = State();
  std::vector<uint64_t> requests;
  for (const auto& [request, key] : state.pending) requests.push_back(request);
  for (uint64_t request : requests) Reply(request, ARX_CREDENTIAL_IMPORT_CANCELLED);
  state.jobs.clear();
  state.profile = nullptr;
  // Replies already posted still reach the app's callback until the runtime's
  // own `running` check drops them.
}

void ImportPasswordRecords(uint64_t request, const char* profile_key,
                           const ArxImportedPassword* records, size_t count) {
  const auto key = Begin(request, profile_key);
  if (!key) return;
  if ((!records && count) || count > credential_import::kMaximumPasswords)
    return Fail(request, ARX_CREDENTIAL_IMPORT_INVALID, "count");
  auto store = PasswordStoreFor(*key);
  if (!store) return Fail(request, ARX_CREDENTIAL_IMPORT_UNAVAILABLE, "store");

  // Copied now: the caller clears its buffers once this returns.
  const base::Time created = base::Time::Now();
  std::vector<std::optional<StoredCredential>> rows;
  rows.reserve(count);
  for (size_t index = 0; index < count; ++index) rows.push_back(PasswordRow(records[index], created));

  auto* job = AddJob(request, *key);
  // The job owns the callback, so it outlives it.
  job->FetchLogins(std::move(store), base::BindOnce(&AddPasswords, std::move(rows), created,
                                                    base::Unretained(job)));
}

void ImportCookies(uint64_t request, const char* profile_key, const ArxImportedCookie* cookies,
                   size_t count) {
  const auto key = Begin(request, profile_key);
  if (!key) return;
  if ((!cookies && count) || count > credential_import::kMaximumCookies)
    return Fail(request, ARX_CREDENTIAL_IMPORT_INVALID, "count");

  // Copied now: the caller clears its buffers once this returns.
  std::vector<CookieCandidate> candidates;
  candidates.reserve(count);
  for (size_t index = 0; index < count; ++index) {
    auto candidate = CookieRow(cookies[index]);
    if (!candidate) return Fail(request, ARX_CREDENTIAL_IMPORT_INVALID, "cookie");
    candidates.push_back(std::move(*candidate));
  }

  auto* job = AddJob(request, *key);
  FetchCookies(job->GetWeakPtr(), base::BindOnce(
      [](std::vector<CookieCandidate> candidates, Job& job,
         const std::vector<net::CanonicalCookie>& live) {
        SetCookies(std::move(candidates), job, live);
      }, std::move(candidates)));
}

void CheckCookies(uint64_t request, const char* profile_key, const char* keys) {
  const auto key = Begin(request, profile_key);
  if (!key) return;
  const auto text = credential_import::Bounded(keys, credential_import::kMaximumKeysBytes);
  auto parsed = text ? base::JSONReader::Read(*text, base::JSON_PARSE_RFC) : std::nullopt;
  auto requested = parsed && parsed->is_list() ? CookieKeysFrom(parsed->GetIfList()) : std::nullopt;
  if (!requested) return Fail(request, ARX_CREDENTIAL_IMPORT_INVALID, "keys");

  auto* job = AddJob(request, *key);
  FetchCookies(job->GetWeakPtr(), base::BindOnce(
      [](std::vector<CookieKey> requested, Job& job,
         const std::vector<net::CanonicalCookie>& live) {
        base::DictValue body;
        body.Set("present", CookieKeyList(credential_import::PresentKeys(
                                requested, LiveKeys(live, base::Time::Now()))));
        Reply(job.request(), ARX_CREDENTIAL_IMPORT_OK, std::move(body));
      }, std::move(*requested)));
}

void UndoCredentialImport(uint64_t request, const char* profile_key, const char* keys) {
  const auto key = Begin(request, profile_key);
  if (!key) return;
  const auto text = credential_import::Bounded(keys, credential_import::kMaximumKeysBytes);
  auto parsed = text ? base::JSONReader::ReadDict(*text, base::JSON_PARSE_RFC) : std::nullopt;
  if (!parsed) return Fail(request, ARX_CREDENTIAL_IMPORT_INVALID, "keys");

  std::map<PasswordKey, base::Time> passwords;
  if (const auto* list = parsed->FindList("passwords")) {
    if (list->size() > credential_import::kMaximumPasswords)
      return Fail(request, ARX_CREDENTIAL_IMPORT_INVALID, "keys");
    for (const auto& item : *list) {
      auto password = PasswordKeyFrom(item);
      if (!password) return Fail(request, ARX_CREDENTIAL_IMPORT_INVALID, "keys");
      passwords.insert(std::move(*password));
    }
  }
  auto cookie_keys = CookieKeysFrom(parsed->FindList("cookies"));
  if (!cookie_keys) return Fail(request, ARX_CREDENTIAL_IMPORT_INVALID, "keys");
  std::set<CookieKey> cookies(cookie_keys->begin(), cookie_keys->end());

  auto* job = AddJob(request, *key);
  auto delete_cookies = base::BindOnce(
      [](std::set<CookieKey> cookies, base::WeakPtr<Job> job, size_t removed) {
        if (!job) return;
        FetchCookies(job, base::BindOnce(&DeleteCookies, std::move(cookies), removed));
      }, std::move(cookies), job->GetWeakPtr());
  if (passwords.empty()) return std::move(delete_cookies).Run(0);

  auto store = PasswordStoreFor(*key);
  if (!store) return Fail(request, ARX_CREDENTIAL_IMPORT_UNAVAILABLE, "store");
  job->FetchLogins(std::move(store), base::BindOnce(
      [](std::map<PasswordKey, base::Time> passwords,
         base::OnceCallback<void(size_t)> delete_cookies, Job* job,
         std::vector<StoredCredential> saved) {
        // Only an entry still exactly as that import added it: one saved again
        // since has a newer creation time, and one whose password changed since
        // (Settings, or an update on sign-in) a newer modified time. Both stay.
        size_t removed = 0;
        for (const auto& form : saved) {
          auto found = passwords.find(KeyOf(form));
          if (found == passwords.end() ||
              !credential_import::StillImported(StampsOf(form), Microseconds(found->second)))
            continue;
          job->store()->RemoveLogin(FROM_HERE, form);
          ++removed;
        }
        if (!removed) return std::move(delete_cookies).Run(0);
        // RemoveLogin only queues the deletion. The store answers reads after
        // the writes queued before them, so read again and succeed only when
        // none of those entries is left.
        scoped_refptr<PasswordStoreInterface> store = job->store();
        job->FetchLogins(std::move(store), base::BindOnce(
            [](std::map<PasswordKey, base::Time> passwords,
               base::OnceCallback<void(size_t)> delete_cookies, uint64_t request, size_t removed,
               std::vector<StoredCredential> saved) {
              for (const auto& form : saved) {
                auto found = passwords.find(KeyOf(form));
                if (found != passwords.end() &&
                    credential_import::StillImported(StampsOf(form), Microseconds(found->second)))
                  return Fail(request, ARX_CREDENTIAL_IMPORT_FAILED, "passwords");
              }
              std::move(delete_cookies).Run(removed);
            }, std::move(passwords), std::move(delete_cookies), job->request(), removed));
      }, std::move(passwords), std::move(delete_cookies), base::Unretained(job)));
}
}  // namespace arx
