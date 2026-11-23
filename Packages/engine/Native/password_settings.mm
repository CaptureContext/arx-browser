#include "chrome/browser/arx/password_settings.h"

#import <AppKit/AppKit.h>
#import <LocalAuthentication/LocalAuthentication.h>

#include <cctype>
#include <cstring>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/memory/ptr_util.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/unguessable_token.h"
#include "base/values.h"
#include "chrome/browser/affiliations/affiliation_service_factory.h"
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/keyed_service/core/service_access_type.h"
#include "components/password_manager/core/browser/import/import_results.h"
#include "components/password_manager/core/browser/import/password_importer.h"
#include "components/password_manager/core/browser/password_form.h"
#include "components/password_manager/core/browser/password_manager_util.h"
#include "components/password_manager/core/browser/ui/credential_ui_entry.h"
#include "components/password_manager/core/browser/ui/saved_passwords_presenter.h"
#include "content/public/browser/browser_thread.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace arx {
namespace {
using password_manager::CredentialFacet;
using password_manager::CredentialUIEntry;
using password_manager::ImportEntry;
using password_manager::ImportResults;
using password_manager::PasswordForm;
using password_manager::PasswordImporter;
using password_manager::PasswordString;
using password_manager::SavedPasswordsPresenter;

constexpr size_t kMaximumListed = 10000;
constexpr size_t kMaximumRows = 200;
constexpr size_t kMaximumPending = 16;
constexpr size_t kMaximumTokenBytes = 64;
constexpr size_t kMaximumTextBytes = 2048;
constexpr size_t kMaximumPathBytes = 4096;
constexpr base::TimeDelta kLoadTimeout = base::Seconds(15);
// A store write reaches the presenter's cache asynchronously; a reply waits
// for it, at most this long.
constexpr base::TimeDelta kSettleTimeout = base::Seconds(5);
constexpr base::TimeDelta kPasteboardLifetime = base::Seconds(60);

class ProfilePasswords;

// A reveal waiting for LocalAuthentication.
struct Reveal {
  base::WeakPtr<ProfilePasswords> owner;
  std::string listing;
  uint32_t credential = 0;
  ArxPasswordReveal mode = ARX_PASSWORD_REVEAL_COPY;
  __weak NSTextField* field = nil;
  LAContext* context = nil;
};

struct Settings {
  SavedPasswordsReply reply = nullptr;
  std::map<Profile*, std::unique_ptr<ProfilePasswords>> profiles;
  // Requests that still owe their one reply.
  std::set<uint64_t> pending;
  std::map<uint64_t, Reveal> reveals;
  NSInteger pasteboard_change = -1;
};

Settings& State() {
  static base::NoDestructor<Settings> settings;
  return *settings;
}

std::string Write(base::DictValue body) {
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(body)), &json);
  return json;
}

// Replies once per request. A cancelled or already answered request is dropped.
void Reply(uint64_t request, ArxSavedPasswordsStatus status,
           base::DictValue body = base::DictValue()) {
  auto& state = State();
  if (!state.pending.erase(request)) return;
  if (auto reveal = state.reveals.find(request); reveal != state.reveals.end()) {
    [reveal->second.context invalidate];
    state.reveals.erase(reveal);
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(
      [](uint64_t request, ArxSavedPasswordsStatus status, std::string json) {
        auto reply = State().reply;
        if (reply) reply(request, status, reinterpret_cast<const uint8_t*>(json.data()), json.size());
      }, request, status, Write(std::move(body))));
}

void Fail(uint64_t request, ArxSavedPasswordsStatus status, const char* reason) {
  base::DictValue body;
  body.Set("reason", reason);
  Reply(request, status, std::move(body));
}

// A short, bounded string argument; nullopt when it's missing or too long.
std::optional<std::string> Text(const char* value, size_t maximum) {
  if (!value) return std::nullopt;
  const size_t length = strnlen(value, maximum + 1);
  if (length > maximum) return std::nullopt;
  return std::string(value, length);
}

bool Token(const std::string& value) {
  if (value.empty() || value.size() > kMaximumTokenBytes) return false;
  for (char character : value)
    if (!isalnum(static_cast<unsigned char>(character))) return false;
  return true;
}

// A site's host only: never a path, query or user info a URL may carry.
std::string Site(const GURL& url) {
  return url.is_valid() && url.SchemeIsHTTPOrHTTPS() ? std::string(url.host()) : std::string();
}

// A row's site: Chromium reports a URL for skipped rows and a domain name for
// conflicts.
std::string SiteName(const std::string& text) {
  GURL url(text);
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) url = GURL("https://" + text);
  return Site(url);
}

const char* SkipReason(ImportEntry::Status status) {
  switch (status) {
    case ImportEntry::MISSING_PASSWORD: return "missingPassword";
    case ImportEntry::MISSING_URL: return "missingURL";
    case ImportEntry::INVALID_URL: return "invalidURL";
    case ImportEntry::LONG_URL:
    case ImportEntry::LONG_PASSWORD:
    case ImportEntry::LONG_USERNAME:
    case ImportEntry::LONG_NOTE:
    case ImportEntry::LONG_CONCATENATED_NOTE: return "tooLong";
    case ImportEntry::CONFLICT_PROFILE:
    case ImportEntry::CONFLICT_ACCOUNT: return "conflict";
    default: return "unknown";
  }
}

// One ordinary profile's presenter and the listing Settings last showed.
class ProfilePasswords final : public SavedPasswordsPresenter::Observer {
 public:
  static std::unique_ptr<ProfilePasswords> Create(Profile* profile) {
    auto* affiliations = AffiliationServiceFactory::GetForProfile(profile);
    auto store = ProfilePasswordStoreFactory::GetForProfile(
        profile, ServiceAccessType::EXPLICIT_ACCESS);
    if (!affiliations || !store) return nullptr;
    return base::WrapUnique(new ProfilePasswords(affiliations, std::move(store)));
  }

  ~ProfilePasswords() override {
    presenter_.RemoveObserver(this);
    for (auto& waiter : loading_) std::move(waiter).Run(false);
  }

  base::WeakPtr<ProfilePasswords> GetWeakPtr() { return weak_.GetWeakPtr(); }

  // Runs once the presenter has read the store; false when it never did.
  void WhenLoaded(base::OnceCallback<void(bool)> callback) {
    if (loaded_) return std::move(callback).Run(true);
    loading_.push_back(std::move(callback));
  }

  // Runs after the presenter's cache next changes, or after kSettleTimeout.
  void AfterChange(base::OnceClosure callback) {
    changing_.push_back(std::move(callback));
    settle_.Start(FROM_HERE, kSettleTimeout,
                  base::BindOnce(&ProfilePasswords::Settled, base::Unretained(this)));
  }

  void ReplyListing(uint64_t request) {
    if (!State().pending.contains(request)) return;
    Reply(request, ARX_SAVED_PASSWORDS_OK, Listing());
  }

  // The listed credential, or the status that explains why there's none.
  const CredentialUIEntry* Find(const std::string& listing, uint32_t credential,
                                ArxSavedPasswordsStatus* status) const {
    if (listing != listing_) {
      *status = ARX_SAVED_PASSWORDS_STALE;
      return nullptr;
    }
    auto found = listed_.find(credential);
    if (found == listed_.end()) {
      *status = ARX_SAVED_PASSWORDS_NOT_FOUND;
      return nullptr;
    }
    return &found->second;
  }

  bool HasUsername(const std::string& signon_realm, const std::u16string& username) {
    for (const auto& entry : presenter_.GetSavedPasswords())
      if (!entry.facets.empty() && entry.GetFirstSignonRealm() == signon_realm &&
          entry.username == username)
        return true;
    return false;
  }

  SavedPasswordsPresenter& presenter() { return presenter_; }

  // Imports a CSV export; a site and username already saved are kept and reported.
  void Import(uint64_t request, const base::FilePath& path) {
    if (importer_ && importer_->IsState(PasswordImporter::kInProgress))
      return Reply(request, ARX_SAVED_PASSWORDS_BUSY);
    importer_ = std::make_unique<PasswordImporter>(presenter_);
    importer_->Import(path, PasswordForm::Store::kProfileStore,
                      base::BindOnce(&ProfilePasswords::Imported, GetWeakPtr(), request,
                                     base::ListValue(), 0));
  }

 private:
  ProfilePasswords(affiliations::AffiliationService* affiliations,
                   scoped_refptr<password_manager::PasswordStoreInterface> store)
      : presenter_(affiliations, std::move(store), nullptr) {
    presenter_.AddObserver(this);
    load_timeout_.Start(FROM_HERE, kLoadTimeout,
                        base::BindOnce(&ProfilePasswords::Loaded, base::Unretained(this), false));
    presenter_.Init(base::BindOnce(&ProfilePasswords::Loaded, GetWeakPtr(), true));
  }

  void Loaded(bool success) {
    load_timeout_.Stop();
    loaded_ = loaded_ || success;
    auto waiters = std::move(loading_);
    loading_.clear();
    for (auto& waiter : waiters) std::move(waiter).Run(loaded_);
  }

  void OnSavedPasswordsChanged(const password_manager::PasswordStoreChangeList&) override {
    Settled();
  }

  void Settled() {
    settle_.Stop();
    auto callbacks = std::move(changing_);
    changing_.clear();
    for (auto& callback : callbacks) std::move(callback).Run();
  }

  base::DictValue Listing() {
    listing_ = base::UnguessableToken::Create().ToString();
    listed_.clear();
    uint32_t next = 1;
    base::ListValue passwords;
    for (auto& entry : presenter_.GetSavedPasswords()) {
      if (passwords.size() >= kMaximumListed) break;
      if (entry.facets.empty() || !entry.passkey_credential_id.empty()) continue;
      const GURL url = entry.GetURL();
      if (Site(url).empty()) continue;
      const uint32_t id = next++;
      base::DictValue item;
      item.Set("id", static_cast<int>(id));
      item.Set("site", Site(url));
      item.Set("origin", url::Origin::Create(url).Serialize());
      item.Set("username", base::UTF16ToUTF8(entry.username));
      passwords.Append(std::move(item));
      listed_.emplace(id, std::move(entry));
    }
    base::ListValue blocked;
    for (auto& entry : presenter_.GetBlockedSites()) {
      if (blocked.size() >= kMaximumListed) break;
      if (entry.facets.empty()) continue;
      const GURL url = entry.GetURL();
      if (Site(url).empty()) continue;
      const uint32_t id = next++;
      base::DictValue item;
      item.Set("id", static_cast<int>(id));
      item.Set("site", Site(url));
      item.Set("origin", url::Origin::Create(url).Serialize());
      blocked.Append(std::move(item));
      listed_.emplace(id, std::move(entry));
    }
    base::DictValue body;
    body.Set("listing", listing_);
    body.Set("passwords", std::move(passwords));
    body.Set("blocked", std::move(blocked));
    return body;
  }

  static void AppendRow(base::ListValue& rows, const ImportEntry& entry, const char* reason) {
    if (rows.size() >= kMaximumRows) return;
    base::DictValue row;
    row.Set("site", SiteName(entry.url));
    row.Set("username", entry.username);
    if (reason) row.Set("reason", reason);
    rows.Append(std::move(row));
  }

  void Imported(uint64_t request, base::ListValue conflicts, int conflict_count,
                const ImportResults& results) {
    // Cancelled: import nothing more. A waiting importer is replaced by the next import.
    if (!State().pending.contains(request)) return;
    switch (results.status) {
      case ImportResults::CONFLICTS: {
        // Existing site and username pairs are kept. Every other row still imports.
        for (const auto& entry : results.displayed_entries) {
          AppendRow(conflicts, entry, nullptr);
          conflict_count++;
        }
        importer_->ContinueImport(
            {}, base::BindOnce(&ProfilePasswords::Imported, GetWeakPtr(), request,
                               std::move(conflicts), conflict_count));
        return;
      }
      case ImportResults::SUCCESS: break;
      case ImportResults::IO_ERROR: return Fail(request, ARX_SAVED_PASSWORDS_FAILED, "io");
      case ImportResults::BAD_FORMAT: return Fail(request, ARX_SAVED_PASSWORDS_INVALID, "format");
      case ImportResults::MAX_FILE_SIZE:
        return Fail(request, ARX_SAVED_PASSWORDS_INVALID, "tooLarge");
      case ImportResults::NUM_PASSWORDS_EXCEEDED:
        return Fail(request, ARX_SAVED_PASSWORDS_INVALID, "tooMany");
      case ImportResults::IMPORT_ALREADY_ACTIVE: return Reply(request, ARX_SAVED_PASSWORDS_BUSY);
      default: return Fail(request, ARX_SAVED_PASSWORDS_FAILED, "unknown");
    }
    base::ListValue skipped;
    int skipped_count = 0;
    for (const auto& entry : results.displayed_entries) {
      if (entry.status == ImportEntry::VALID) continue;
      AppendRow(skipped, entry, SkipReason(entry.status));
      skipped_count++;
    }
    base::DictValue body;
    body.Set("imported", static_cast<int>(results.number_imported));
    body.Set("conflicts", std::move(conflicts));
    body.Set("conflictCount", conflict_count);
    body.Set("skipped", std::move(skipped));
    body.Set("skippedCount", skipped_count);
    if (!results.number_imported) return Reply(request, ARX_SAVED_PASSWORDS_OK, std::move(body));
    AfterChange(base::BindOnce(
        [](uint64_t request, base::DictValue body) {
          Reply(request, ARX_SAVED_PASSWORDS_OK, std::move(body));
        }, request, std::move(body)));
  }

  SavedPasswordsPresenter presenter_;
  std::unique_ptr<PasswordImporter> importer_;
  bool loaded_ = false;
  std::vector<base::OnceCallback<void(bool)>> loading_;
  std::vector<base::OnceClosure> changing_;
  base::OneShotTimer load_timeout_;
  base::OneShotTimer settle_;
  std::string listing_;
  std::map<uint32_t, CredentialUIEntry> listed_;
  base::WeakPtrFactory<ProfilePasswords> weak_{this};
};

// Starts a request for an ordinary profile: the presenter, loaded. False has
// already replied.
bool Begin(Profile* profile, uint64_t request,
           base::OnceCallback<void(ProfilePasswords&)> run) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto& state = State();
  if (!request || state.pending.contains(request)) return false;
  if (!state.reply) return false;
  state.pending.insert(request);
  if (!profile || profile->IsOffTheRecord()) {
    Reply(request, ARX_SAVED_PASSWORDS_UNAVAILABLE);
    return false;
  }
  if (state.pending.size() > kMaximumPending) {
    Reply(request, ARX_SAVED_PASSWORDS_BUSY);
    return false;
  }
  auto& owner = state.profiles[profile];
  if (!owner) owner = ProfilePasswords::Create(profile);
  if (!owner) {
    state.profiles.erase(profile);
    Reply(request, ARX_SAVED_PASSWORDS_UNAVAILABLE);
    return false;
  }
  owner->WhenLoaded(base::BindOnce(
      [](base::WeakPtr<ProfilePasswords> owner, uint64_t request,
         base::OnceCallback<void(ProfilePasswords&)> run, bool loaded) {
        if (!State().pending.contains(request)) return;
        if (!owner || !loaded) return Reply(request, ARX_SAVED_PASSWORDS_FAILED);
        std::move(run).Run(*owner);
      }, owner->GetWeakPtr(), request, std::move(run)));
  return true;
}

void ClearPasteboardIfUnchanged(NSInteger change) {
  NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
  if (pasteboard.changeCount == change) [pasteboard clearContents];
  if (State().pasteboard_change == change) State().pasteboard_change = -1;
}

void Revealed(uint64_t request, bool success) {
  auto& state = State();
  auto found = state.reveals.find(request);
  if (found == state.reveals.end()) return;
  Reveal reveal = std::move(found->second);
  state.reveals.erase(found);
  if (!state.pending.contains(request)) return;
  reveal.context = nil;
  if (!success) return Reply(request, ARX_SAVED_PASSWORDS_DENIED);
  if (!reveal.owner) return Reply(request, ARX_SAVED_PASSWORDS_UNAVAILABLE);

  ArxSavedPasswordsStatus status = ARX_SAVED_PASSWORDS_OK;
  const auto* entry = reveal.owner->Find(reveal.listing, reveal.credential, &status);
  if (!entry || entry->blocked_by_user || entry->password.empty())
    return Reply(request, entry ? ARX_SAVED_PASSWORDS_NOT_FOUND : status);

  // Chromium 157 keeps saved passwords in a PasswordString; read it only here.
  const auto secret = entry->password.secure_value();
  NSString* value = base::SysUTF16ToNSString(secret);
  if (reveal.mode == ARX_PASSWORD_REVEAL_SHOW) {
    NSTextField* field = reveal.field;
    if (!field || !field.window) return Reply(request, ARX_SAVED_PASSWORDS_STALE);
    field.stringValue = value;
    return Reply(request, ARX_SAVED_PASSWORDS_OK);
  }

  NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
  [pasteboard clearContents];
  // Concealed: clipboard managers that honor it neither show nor keep it.
  [pasteboard declareTypes:@[ NSPasteboardTypeString, @"org.nspasteboard.ConcealedType" ]
                     owner:nil];
  [pasteboard setString:value forType:NSPasteboardTypeString];
  [pasteboard setString:@"" forType:@"org.nspasteboard.ConcealedType"];
  const NSInteger change = pasteboard.changeCount;
  state.pasteboard_change = change;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&ClearPasteboardIfUnchanged, change), kPasteboardLifetime);
  Reply(request, ARX_SAVED_PASSWORDS_OK);
}
}  // namespace

void StartPasswordSettings(SavedPasswordsReply reply) {
  State().reply = reply;
}

void StopPasswordSettings() {
  auto& state = State();
  for (auto& [request, reveal] : state.reveals) [reveal.context invalidate];
  state.reveals.clear();
  for (uint64_t request : std::set<uint64_t>(state.pending))
    Reply(request, ARX_SAVED_PASSWORDS_CANCELLED);
  state.profiles.clear();
  if (state.pasteboard_change >= 0) ClearPasteboardIfUnchanged(state.pasteboard_change);
  state.reply = nullptr;
}

void ListSavedPasswords(Profile* profile, uint64_t request) {
  Begin(profile, request, base::BindOnce(
      [](uint64_t request, ProfilePasswords& owner) { owner.ReplyListing(request); }, request));
}

void SaveSavedPassword(Profile* profile, uint64_t request, const char* listing,
                       uint32_t credential, const char* url, const char* username,
                       void* password_field) {
  // The field is read once, now, while the caller still holds it, and cleared.
  std::optional<std::u16string> password;
  bool valid_field = true;
  if (password_field) {
    NSTextField* field = (__bridge NSTextField*)password_field;
    if ([field isKindOfClass:[NSTextField class]]) {
      password = base::SysNSStringToUTF16(field.stringValue ?: @"");
      field.stringValue = @"";
    } else {
      valid_field = false;
    }
  }
  const auto listing_text = listing ? Text(listing, kMaximumTokenBytes) : std::string();
  const auto url_text = url ? Text(url, kMaximumTextBytes) : std::string();
  const auto username_text = Text(username, kMaximumTextBytes);
  const bool valid = valid_field && listing_text && url_text && username_text &&
      (credential ? Token(*listing_text) : !url_text->empty()) &&
      (!password || password->size() <= kMaximumTextBytes);
  Begin(profile, request, base::BindOnce(
      [](uint64_t request, bool valid, std::string listing, uint32_t credential,
         std::string url, std::u16string username, std::optional<std::u16string> password,
         ProfilePasswords& owner) {
        if (!valid) return Reply(request, ARX_SAVED_PASSWORDS_INVALID);
        auto settled = base::BindOnce(&ProfilePasswords::ReplyListing, owner.GetWeakPtr(), request);

        if (!credential) {
          // Add: a site, a username (may be empty) and a password that isn't.
          if (!password || password->empty()) return Reply(request, ARX_SAVED_PASSWORDS_INVALID);
          CredentialFacet facet;
          facet.url = password_manager_util::StripAuthAndParams(
              password_manager_util::ConstructGURLWithScheme(url));
          if (Site(facet.url).empty()) return Reply(request, ARX_SAVED_PASSWORDS_INVALID);
          facet.signon_realm = password_manager_util::GetSignonRealm(facet.url);
          if (owner.HasUsername(facet.signon_realm, username))
            return Reply(request, ARX_SAVED_PASSWORDS_EXISTS);
          CredentialUIEntry entry;
          entry.facets.push_back(std::move(facet));
          entry.username = std::move(username);
          entry.password = PasswordString(std::move(*password));
          entry.stored_in = {PasswordForm::Store::kProfileStore};
          if (!owner.presenter().AddCredential(entry))
            return Reply(request, ARX_SAVED_PASSWORDS_INVALID);
          return owner.AfterChange(std::move(settled));
        }

        ArxSavedPasswordsStatus status = ARX_SAVED_PASSWORDS_OK;
        const auto* original = owner.Find(listing, credential, &status);
        if (!original) return Reply(request, status);
        if (original->blocked_by_user) return Reply(request, ARX_SAVED_PASSWORDS_INVALID);
        CredentialUIEntry updated = *original;
        updated.username = std::move(username);
        // An empty field keeps the saved password.
        if (password && !password->empty()) updated.password = PasswordString(std::move(*password));
        switch (owner.presenter().EditSavedCredentials(*original, updated)) {
          case SavedPasswordsPresenter::EditResult::kSuccess:
            return owner.AfterChange(std::move(settled));
          case SavedPasswordsPresenter::EditResult::kNothingChanged:
            return std::move(settled).Run();
          case SavedPasswordsPresenter::EditResult::kNotFound:
            return Reply(request, ARX_SAVED_PASSWORDS_NOT_FOUND);
          case SavedPasswordsPresenter::EditResult::kAlreadyExisits:
            return Reply(request, ARX_SAVED_PASSWORDS_EXISTS);
          case SavedPasswordsPresenter::EditResult::kEmptyPassword:
            return Reply(request, ARX_SAVED_PASSWORDS_INVALID);
        }
        Reply(request, ARX_SAVED_PASSWORDS_FAILED);
      }, request, valid, listing_text.value_or(std::string()), credential,
      url_text.value_or(std::string()),
      base::UTF8ToUTF16(username_text.value_or(std::string())), std::move(password)));
}

void RemoveSavedPassword(Profile* profile, uint64_t request, const char* listing,
                         uint32_t credential) {
  const auto listing_text = Text(listing, kMaximumTokenBytes);
  const bool valid = listing_text && Token(*listing_text) && credential;
  Begin(profile, request, base::BindOnce(
      [](uint64_t request, bool valid, std::string listing, uint32_t credential,
         ProfilePasswords& owner) {
        if (!valid) return Reply(request, ARX_SAVED_PASSWORDS_INVALID);
        ArxSavedPasswordsStatus status = ARX_SAVED_PASSWORDS_OK;
        const auto* entry = owner.Find(listing, credential, &status);
        if (!entry) return Reply(request, status);
        if (!owner.presenter().RemoveCredential(*entry))
          return Reply(request, ARX_SAVED_PASSWORDS_NOT_FOUND);
        owner.AfterChange(base::BindOnce(&ProfilePasswords::ReplyListing, owner.GetWeakPtr(), request));
      }, request, valid, listing_text.value_or(std::string()), credential));
}

void RevealSavedPassword(Profile* profile, uint64_t request, const char* listing,
                         uint32_t credential, ArxPasswordReveal mode, const char* reason,
                         void* field) {
  auto& state = State();
  const auto listing_text = Text(listing, kMaximumTokenBytes);
  const auto reason_text = Text(reason, kMaximumTextBytes);
  NSTextField* target = field ? (__bridge NSTextField*)field : nil;
  const bool valid = listing_text && Token(*listing_text) && credential && reason_text &&
      !reason_text->empty() &&
      (mode == ARX_PASSWORD_REVEAL_COPY ||
       (mode == ARX_PASSWORD_REVEAL_SHOW && [target isKindOfClass:[NSTextField class]]));
  // The lent field waits here, weakly, rather than in a bound callback.
  if (request && !state.pending.contains(request) && !state.reveals.contains(request))
    state.reveals[request].field = target;
  if (!Begin(profile, request, base::BindOnce(
      [](uint64_t request, bool valid, std::string listing, uint32_t credential,
         ArxPasswordReveal mode, std::string reason, ProfilePasswords& owner) {
        auto found = State().reveals.find(request);
        if (!valid || found == State().reveals.end())
          return Reply(request, ARX_SAVED_PASSWORDS_INVALID);
        ArxSavedPasswordsStatus status = ARX_SAVED_PASSWORDS_OK;
        const auto* entry = owner.Find(listing, credential, &status);
        if (!entry) return Reply(request, status);
        if (entry->blocked_by_user) return Reply(request, ARX_SAVED_PASSWORDS_INVALID);

        LAContext* context = [[LAContext alloc] init];
        NSError* error = nil;
        if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error])
          return Reply(request, ARX_SAVED_PASSWORDS_DENIED);
        found->second.owner = owner.GetWeakPtr();
        found->second.listing = listing;
        found->second.credential = credential;
        found->second.mode = mode;
        found->second.context = context;
        auto runner = base::SingleThreadTaskRunner::GetCurrentDefault();
        [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                localizedReason:base::SysUTF8ToNSString(reason)
                          reply:^(BOOL success, NSError*) {
                            runner->PostTask(FROM_HERE,
                                             base::BindOnce(&Revealed, request, success == YES));
                          }];
      }, request, valid, listing_text.value_or(std::string()), credential, mode,
      reason_text.value_or(std::string()))))
    if (!state.pending.contains(request)) state.reveals.erase(request);
}

void ImportSavedPasswords(Profile* profile, uint64_t request, const char* path) {
  const auto path_text = Text(path, kMaximumPathBytes);
  const bool valid = path_text && !path_text->empty() && (*path_text)[0] == '/';
  Begin(profile, request, base::BindOnce(
      [](uint64_t request, bool valid, std::string path, ProfilePasswords& owner) {
        if (!valid) return Reply(request, ARX_SAVED_PASSWORDS_INVALID);
        owner.Import(request, base::FilePath(path));
      }, request, valid, path_text.value_or(std::string())));
}

void CancelSavedPasswords(uint64_t request) {
  Reply(request, ARX_SAVED_PASSWORDS_CANCELLED);
}

void ForgetPasswordSettingsProfile(Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  // The presenter borrows the profile's affiliation service and stores.
  State().profiles.erase(profile);
}
}  // namespace arx
