// Runs Packages/engine/Native/credential_import_keys.h (DEV-830) on its own.
// No Chromium: the header uses the standard library only.
#include "credential_import_keys.h"

#include <cstdio>
#include <string>

using namespace arx::credential_import;

namespace {
int failures = 0;

void Expect(bool condition, const char* what) {
  if (!condition) {
    std::printf("FAILED: %s\n", what);
    ++failures;
  }
}

void Bounds() {
  Expect(!Bounded(nullptr, 4), "null is missing");
  Expect(Bounded("abcd", 4) == std::string_view("abcd"), "a string at the limit is kept");
  Expect(!Bounded("abcde", 4), "a longer string is refused");
  Expect(Bounded("", 4) == std::string_view(""), "an empty string is kept");
}

void Domains() {
  Expect(ValidCookieDomain("example.test"), "host cookie");
  Expect(ValidCookieDomain(".example.test"), "domain cookie");
  Expect(ValidCookieDomain("127.0.0.1"), "IP host");
  Expect(!ValidCookieDomain(""), "empty");
  Expect(!ValidCookieDomain("."), "dot only");
  Expect(!ValidCookieDomain("..example.test"), "two leading dots");
  Expect(!ValidCookieDomain("example..test"), "empty label");
  Expect(!ValidCookieDomain("example.test."), "trailing dot");
  Expect(!ValidCookieDomain("Example.test"), "not canonical");
  Expect(!ValidCookieDomain("exa mple.test"), "space");
  Expect(!ValidCookieDomain("[::1]"), "IPv6 literal");
  Expect(!ValidCookieDomain(std::string(256, 'a')), "too long");
}

void SourceURLs() {
  Expect(CookieSourceURL(".example.test", false, 0, -1) == "http://example.test/", "plain");
  Expect(CookieSourceURL("example.test", true, 0, -1) == "https://example.test/", "secure");
  Expect(CookieSourceURL("example.test", false, 2, 443) == "https://example.test/", "secure scheme, default port");
  Expect(CookieSourceURL("example.test", false, 1, 8080) == "http://example.test:8080/", "custom port");
  Expect(CookieSourceURL("example.test", true, 2, 80) == "https://example.test:80/", "https on port 80");
  Expect(CookieSourceURL("example.test", false, 0, 70000).empty(), "invalid port");
  Expect(CookieSourceURL("bad..test", false, 0, -1).empty(), "invalid domain");
}

void Ranges() {
  Expect(ValidSameSite(-1) && ValidSameSite(2) && !ValidSameSite(3) && !ValidSameSite(-2), "same site");
  Expect(ValidPriority(0) && ValidPriority(2) && !ValidPriority(3) && !ValidPriority(-1), "priority");
  Expect(ValidSourceScheme(0) && ValidSourceScheme(2) && !ValidSourceScheme(3), "source scheme");
  Expect(ValidSourcePort(-1) && ValidSourcePort(0) && ValidSourcePort(65535) &&
         !ValidSourcePort(-2) && !ValidSourcePort(65536), "source port");
}

void Keys() {
  CookieKey unpartitioned{"example.test", "id", "/", "", true, 2, 443};
  Expect(!Normalized(unpartitioned).has_cross_site_ancestor, "unpartitioned drops the ancestor bit");
  CookieKey partitioned{"example.test", "id", "/", "https://top.test", true, 2, 443};
  Expect(Normalized(partitioned).has_cross_site_ancestor, "partitioned keeps the ancestor bit");

  const CookieKey base{"example.test", "id", "/", "", false, 2, 443};
  auto other_port = base; other_port.source_port = 8443;
  auto other_scheme = base; other_scheme.source_scheme = 1;
  auto other_partition = base; other_partition.top_frame_site_key = "https://top.test";
  auto other_bit = other_partition; other_bit.has_cross_site_ancestor = true;
  Expect(!(base == other_port) && !(base == other_scheme) && !(base == other_partition) &&
         !(other_partition == other_bit), "every field takes part in identity");

  // Check finds only the exact keys, once each, in request order.
  const std::set<CookieKey> live{base, other_partition};
  const auto present = PresentKeys({other_port, base, other_partition, base}, live);
  Expect(present.size() == 2 && present[0] == base && present[1] == other_partition,
         "present keys are exact and unique");
}

void Passwords() {
  const PasswordKey stored{"https://a.test/", "ann"};
  const PasswordKey fresh{"https://b.test/", "bob"};
  const auto outcomes = ClassifyPasswords(
      {fresh, std::nullopt, stored, fresh, PasswordKey{"https://a.test/", "ANN"}}, {stored});
  Expect(outcomes.size() == 5, "one outcome per row");
  Expect(outcomes[0] == PasswordOutcome::kImported, "new pair is imported");
  Expect(outcomes[1] == PasswordOutcome::kSkipped, "invalid row is skipped");
  Expect(outcomes[2] == PasswordOutcome::kConflict, "stored pair keeps its password");
  Expect(outcomes[3] == PasswordOutcome::kConflict, "a pair repeated in the call conflicts");
  Expect(outcomes[4] == PasswordOutcome::kImported, "usernames are compared exactly");
}
void Stamps() {
  const PasswordKey ann{"https://a.test/", "ann"};
  const PasswordKey bob{"https://b.test/", "bob"};
  const int64_t stamp = 13370000000000000;
  Expect(StillImported({ann, stamp, stamp}, stamp), "an untouched import is still the import's");
  Expect(!StillImported({ann, stamp, stamp + 1}, stamp), "a password changed since is the user's");
  Expect(!StillImported({ann, stamp + 5, stamp + 5}, stamp), "a password saved again is the user's");
  Expect(!StillImported({ann, 0, 0}, 0), "no stamp matches nothing");

  // Read back after a write: only entries stored with the stamp count, so a
  // store that failed reports nothing imported.
  const auto confirmed = ConfirmedImports({ann, bob}, {{ann, stamp, stamp}, {bob, stamp - 1, stamp - 1}}, stamp);
  Expect(confirmed.size() == 1 && confirmed[0] == ann, "only stored rows are imported");
  Expect(ConfirmedImports({ann, bob}, {}, stamp).empty(), "a failed store imports nothing");
}
void Times() {
  const int64_t day = 24LL * 60 * 60 * 1000 * 1000;
  const int64_t now = 13400000000000000;

  // An ordinary cookie keeps its times.
  auto plain = InsertionTimes(now - 10 * day, now + 30 * day, now - day, now);
  Expect(plain.creation == now - 10 * day && plain.effective_expiry == now + 30 * day &&
         plain.last_access == now - day, "an ordinary cookie keeps its times");

  // Created 500 days ago, renewed to expire in 30 days: the old creation time
  // would cap it at 100 days ago, already expired.
  auto renewed = InsertionTimes(now - 500 * day, now + 30 * day, now - day, now);
  Expect(renewed.effective_expiry == now + 30 * day, "a renewed cookie keeps its expiry");
  Expect(renewed.creation == now - 370 * day, "creation moves forward only as far as needed");
  Expect(renewed.last_access == now - day, "last access stays when it's after creation");

  // Renewed to expire beyond 400 days from now: as long as Chromium allows.
  auto far = InsertionTimes(now - 500 * day, now + 500 * day, now - 600 * day, now);
  Expect(far.creation == now && far.effective_expiry == now + 400 * day,
         "a far expiry gets Chromium's longest lifetime");
  Expect(far.last_access == now, "last access is never before creation");

  // Missing or future creation times become now.
  Expect(InsertionTimes(0, now + day, 0, now).creation == now, "missing creation is now");
  Expect(InsertionTimes(now + day, now + 2 * day, 0, now).creation == now, "future creation is now");
}
}  // namespace

int main() {
  Bounds();
  Domains();
  SourceURLs();
  Ranges();
  Keys();
  Passwords();
  Stamps();
  Times();
  return failures ? 1 : 0;
}
