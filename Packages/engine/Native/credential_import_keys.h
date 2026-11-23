#ifndef ARX_CREDENTIAL_IMPORT_KEYS_H
#define ARX_CREDENTIAL_IMPORT_KEYS_H

// ABI46 credential migration (DEV-650, DEV-830): the rules credential_import.mm
// applies, in standard C++ only so Scripts/tests can compile and run them
// without Chromium. Nothing here sees a password or cookie value.

#include <cstddef>
#include <cstdint>
#include <algorithm>
#include <cstring>
#include <optional>
#include <set>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

namespace arx::credential_import {

inline constexpr size_t kMaximumPasswords = 10000;
inline constexpr size_t kMaximumCookies = 20000;
// PasswordImporter's limits for one row.
inline constexpr size_t kMaximumURLBytes = 2048;
inline constexpr size_t kMaximumUsernameBytes = 1000;
inline constexpr size_t kMaximumPasswordBytes = 1000;
// RFC 6265bis and Chromium's own limits for one cookie.
inline constexpr size_t kMaximumDomainBytes = 255;
inline constexpr size_t kMaximumNameAndValueBytes = 4096;
// A stored path has no length limit of its own (a default path comes from the
// request URL), so a cookie's strings are only read up to this bound; the app
// never sends longer ones. Longer than this makes the whole call invalid.
inline constexpr size_t kMaximumFieldReadBytes = 1024 * 1024;
inline constexpr size_t kMaximumSiteBytes = 2048;
// A keys argument to check_cookies or undo_credential_import.
inline constexpr size_t kMaximumKeysBytes = 16 * 1024 * 1024;

// A borrowed C string no longer than maximum bytes; nullopt when it's missing or
// longer. The caller copies what it keeps.
inline std::optional<std::string_view> Bounded(const char* value, size_t maximum) {
  if (!value) return std::nullopt;
  const size_t length = strnlen(value, maximum + 1);
  if (length > maximum) return std::nullopt;
  return std::string_view(value, length);
}

// A saved password's identity in the store, as the reply and undo name it.
struct PasswordKey {
  std::string signon_realm;
  std::string username;

  friend bool operator==(const PasswordKey&, const PasswordKey&) = default;
  friend auto operator<=>(const PasswordKey&, const PasswordKey&) = default;
};

// A cookie's full identity: name, domain and path, its partition (top-frame
// site and cross-site ancestor bit) and its source scheme and port. Check and
// undo compare all seven fields, so a sibling that differs only in partition,
// scheme or port is never mistaken for an imported cookie.
struct CookieKey {
  std::string domain;
  std::string name;
  std::string path;
  std::string top_frame_site_key;
  bool has_cross_site_ancestor = false;
  int32_t source_scheme = 0;
  int32_t source_port = -1;

  friend bool operator==(const CookieKey&, const CookieKey&) = default;
  friend auto operator<=>(const CookieKey&, const CookieKey&) = default;
};

// The ancestor bit means nothing without a partition, and Chromium serializes
// an unpartitioned cookie's as true (CookiePartitionKey::Serialize), so keys
// carry false for every unpartitioned cookie, whatever the source stored.
inline CookieKey Normalized(CookieKey key) {
  if (key.top_frame_site_key.empty()) key.has_cross_site_ancestor = false;
  return key;
}

// net::CookieSameSite, net::CookiePriority and net::CookieSourceScheme as stored.
inline bool ValidSameSite(int32_t value) { return value >= -1 && value <= 2; }
inline bool ValidPriority(int32_t value) { return value >= 0 && value <= 2; }
inline bool ValidSourceScheme(int32_t value) { return value >= 0 && value <= 2; }
// url::PORT_UNSPECIFIED (-1) or a real port.
inline bool ValidSourcePort(int32_t value) { return value >= -1 && value <= 65535; }

// A host_key: a leading dot marks a domain cookie. Lowercase letters, digits,
// '-', '.', '_' only (Chromium stores domains canonicalized), no empty label
// other than the leading dot's, and no IP literal brackets.
inline bool ValidCookieDomain(std::string_view domain) {
  if (domain.empty() || domain.size() > kMaximumDomainBytes) return false;
  std::string_view host = domain.front() == '.' ? domain.substr(1) : domain;
  if (host.empty() || host.front() == '.' || host.back() == '.') return false;
  char previous = 0;
  for (char character : host) {
    const bool allowed = (character >= 'a' && character <= 'z') ||
        (character >= '0' && character <= '9') || character == '-' || character == '.' ||
        character == '_';
    if (!allowed) return false;
    if (character == '.' && previous == '.') return false;
    previous = character;
  }
  return true;
}

// The URL Chromium checks a set against: https when the cookie is Secure or
// came from a secure scheme, else http, with the source port when it isn't the
// scheme's default. Empty for an invalid domain or port.
inline std::string CookieSourceURL(std::string_view domain, bool secure, int32_t source_scheme,
                                   int32_t source_port) {
  if (!ValidCookieDomain(domain) || !ValidSourcePort(source_port)) return std::string();
  const std::string_view host = domain.front() == '.' ? domain.substr(1) : domain;
  const bool https = secure || source_scheme == 2;
  std::string url = https ? "https://" : "http://";
  url.append(host);
  const int32_t default_port = https ? 443 : 80;
  if (source_port > 0 && source_port != default_port) url += ":" + std::to_string(source_port);
  url += "/";
  return url;
}

// What import_password_records does with each row, in input order.
enum class PasswordOutcome { kImported, kConflict, kSkipped };

// Classifies rows against the profile store's existing (signon_realm, username)
// pairs. A row that isn't valid is skipped; a pair already in the store, or
// earlier in the same call, is a conflict and keeps the stored password.
inline std::vector<PasswordOutcome> ClassifyPasswords(
    const std::vector<std::optional<PasswordKey>>& rows, std::set<PasswordKey> existing) {
  std::vector<PasswordOutcome> outcomes;
  outcomes.reserve(rows.size());
  for (const auto& row : rows) {
    if (!row) {
      outcomes.push_back(PasswordOutcome::kSkipped);
    } else if (!existing.insert(*row).second) {
      outcomes.push_back(PasswordOutcome::kConflict);
    } else {
      outcomes.push_back(PasswordOutcome::kImported);
    }
  }
  return outcomes;
}

// A stored password entry's identity and stamps, in microseconds since 1601.
struct StoredPassword {
  PasswordKey key;
  int64_t created = 0;
  int64_t modified = 0;
};

// Whether a stored entry is still exactly what an import with this stamp added.
// An import sets both its creation and password-modified times to the stamp;
// editing the password later (Settings, or an update offered on sign-in) moves
// the modified time, and that entry is the user's again.
inline bool StillImported(const StoredPassword& stored, int64_t stamp) {
  return stamp > 0 && stored.created == stamp && stored.modified == stamp;
}

// The attempted keys the store holds now, read back after the write: a store
// that failed (a full disk, a backend error) still runs its completion, so only
// entries found with the import's stamp count as imported.
inline std::vector<PasswordKey> ConfirmedImports(const std::vector<PasswordKey>& attempted,
                                                 const std::vector<StoredPassword>& stored,
                                                 int64_t stamp) {
  std::set<PasswordKey> found;
  for (const auto& entry : stored)
    if (StillImported(entry, stamp)) found.insert(entry.key);
  std::vector<PasswordKey> confirmed;
  for (const auto& key : attempted)
    if (found.contains(key)) confirmed.push_back(key);
  return confirmed;
}

// Chromium caps a cookie's expiry at 400 days after its creation time
// (CanonicalCookie::ValidateAndAdjustExpiryDate, applied by
// CookieManager::SetCanonicalCookie).
inline constexpr int64_t kMaximumCookieLifetime = 400LL * 24 * 60 * 60 * 1000 * 1000;

// Times in microseconds since 1601, as Chromium stores them.
struct CookieTimes {
  int64_t creation = 0;
  int64_t expiry = 0;
  int64_t last_access = 0;
  // The expiry Chromium will keep: expiry capped at creation + 400 days.
  int64_t effective_expiry = 0;
};

// The times to insert a source cookie with. A site that renews a cookie
// without changing its value keeps its first creation time and moves only the
// expiry, so an old, renewed cookie would come in capped at creation + 400
// days: shortened, or already expired. Creation moves forward just enough to
// keep the source's expiry (never past now; a missing or future creation is
// now), so the cookie keeps its remaining lifetime where Chromium allows it.
// Creation isn't part of a cookie's key, so check and undo are unaffected.
inline CookieTimes InsertionTimes(int64_t creation, int64_t expiry, int64_t last_access,
                                  int64_t now) {
  CookieTimes times;
  times.expiry = expiry;
  times.creation = creation > 0 && creation <= now ? creation : now;
  if (expiry - times.creation > kMaximumCookieLifetime)
    times.creation = std::min(now, expiry - kMaximumCookieLifetime);
  times.last_access = std::clamp(last_access > 0 ? last_access : times.creation, times.creation, now);
  times.effective_expiry = std::min(expiry, times.creation + kMaximumCookieLifetime);
  return times;
}

// The keys present now: requested keys that equal a live cookie's key.
inline std::vector<CookieKey> PresentKeys(const std::vector<CookieKey>& requested,
                                          const std::set<CookieKey>& live) {
  std::vector<CookieKey> present;
  std::set<CookieKey> seen;
  for (const auto& key : requested)
    if (live.contains(key) && seen.insert(key).second) present.push_back(key);
  return present;
}
}  // namespace arx::credential_import

#endif
