"""Compile out Helium's services; nothing in the engine can reach Helium's servers (DEV-930).

Helium keeps its services code compiled in, dormant behind a consent pref Arx never sets: every
`helium::Get*URL` returns a dummy host unless `ShouldAccessServices` sees the services pref and
consent. One stray pref, or a later Helium change, would start requests to Helium. This overlay
removes that path:

* `ShouldAccessServices` always answers no, so every service helper (extension proxy, web store
  snippets, spellcheck dictionaries, browser and component updates, uBlock assets, bangs) returns
  `helium::GetDummyURL()`, an unresolvable host.
* `GetServicesBaseURL` returns that dummy host too, ignoring the services-origin pref, and
  `kHeliumDefaultOrigin` and Helium's update feed base are the dummy host, so their real hosts
  aren't in the binary at all.
* The default web push server (Helium 0.21.3's Autopush client) is the dummy host too; push
  connects only when `ShouldAccessServices` allows it, so it never does.
* Chromium's crash upload URL is empty: Crashpad keeps reports on the Mac and never uploads.
  Arx reads them itself (DEV-887).
* Extension update pings are tied to a domain that can't exist, so no update request carries one.

Features that need the network have their own paths that don't go through Helium's services:
component updates (DEV-874) and uBlock Origin's lists (DEV-884). `make engine-hosts` checks the
built framework for any Google or Helium host outside its allowlist.

Google hosts for features Arx doesn't have are taken out the same way, as ungoogled-chromium's
domain substitution does (`.qjz9zk`, a suffix that can't resolve), so the allowlist keeps only
what Arx uses:

* Chrome Enterprise: profile enrollment, the Microsoft sign-in page of the managed new tab page
  and its CSP, the enterprise release notes, and the policy link in two console messages
  (`chromeenterprise.google`). Content analysis connectors (`scan.webprotect-*.goog`).
* Tab context sync's allowed origin (`chromestorage.goog`).
* Google's "Search image" through Lens (`lens.google.com/upload`): Arx's page menus don't offer it.
* Safe Browsing's OHTTP relay for real-time lookups: Arx uses no Google Safe Browsing (DEV-923
  blocks with uBlock's lists, as Helium does), and the engine is built with `safe_browsing_mode=0`.
"""
from .overlay import replace_once

HELPERS_HEADER = "components/helium_services/helium_services_helpers.h"
HELPERS = "components/helium_services/helium_services_helpers.cc"
CRASH_CLIENT = "components/crash/core/app/crash_reporter_client.cc"
DOWNLOADER = "chrome/browser/extensions/updater/chrome_extension_downloader_factory.cc"

DUMMY_ORIGIN = "https://helium-services-are-disabled.qjz9zk"

DEFAULT_ORIGIN = '''const char kHeliumDefaultOrigin[] =
    "https://services.helium.imput.net";
'''

ARX_DEFAULT_ORIGIN = f'''// Arx (DEV-930): Helium's services are compiled out. The default origin is the
// same unreachable host as kHeliumDummyOrigin.
const char kHeliumDefaultOrigin[] =
    "{DUMMY_ORIGIN}";
'''

PUSH_SERVER = '''const char kHeliumDefaultPushServer[] = "wss://push.helium.computer/";
'''

# Helium 0.21.3's web push (an Autopush client in GCM) connects only when
# ShouldAccessServices allows it, so it never does; its server leaves the binary too.
ARX_PUSH_SERVER = '''// Arx (DEV-930): web push through Helium is compiled out; unreachable host.
const char kHeliumDefaultPushServer[] = "wss://helium-services-are-disabled.qjz9zk/";
'''

UPDATE_BASE = '''constexpr std::string_view kUpdateBaseUrl = "https://updates.helium.computer/";
'''

ARX_UPDATE_BASE = f'''// Arx (DEV-930): Arx updates itself with Sparkle; Helium's feed is unreachable.
constexpr std::string_view kUpdateBaseUrl = "{DUMMY_ORIGIN}/";
'''

BASE_URL = '''GURL GetServicesBaseURL(const PrefService& prefs) {
    std::optional<GURL> user_url = GetValidUserOverridenURL(prefs);
    if (user_url) {
        return *user_url;
    }

    return GURL(kHeliumDefaultOrigin);
}
'''

ARX_BASE_URL = '''GURL GetServicesBaseURL(const PrefService& prefs) {
    // Arx (DEV-930): no services origin, whatever the pref says.
    return GetDummyURL();
}
'''

SHOULD_ACCESS = '''bool ShouldAccessServices(const PrefService& prefs) {
    return prefs.GetBoolean(prefs::kHeliumServicesEnabled) &&
           prefs.GetBoolean(prefs::kHeliumServicesConsented);
}
'''

ARX_SHOULD_ACCESS = '''bool ShouldAccessServices(const PrefService& prefs) {
    // Arx (DEV-930): Helium's services are never used, whatever the prefs say.
    // Every helper below then returns GetDummyURL().
    return false;
}
'''

UPLOAD_URL = '''#if defined(OFFICIAL_BUILD)
  return "https://crash.helium.computer/crash";
#else
  return std::string();
#endif
'''

ARX_UPLOAD_URL = '''  // Arx (DEV-930): no crash server. Crashpad keeps reports on the Mac, where
  // Arx reads them itself and sends them only with the person's consent.
  return std::string();
'''

PING_DOMAIN = '''  downloader->set_ping_enabled_domain("helium.computer");
'''

ARX_PING_DOMAIN = '''  // Arx (DEV-930): a domain no update URL can have, so no request carries pings.
  downloader->set_ping_enabled_domain("arx-pings-are-disabled.invalid");
'''


# MARK: - Google hosts for features Arx doesn't have

CONNECTORS = "components/enterprise/connectors/core/service_provider_config.cc"
TAB_CONTEXT = "components/sync_tab_context/http_rpc_constants.cc"
OIDC_THROTTLE = "chrome/browser/enterprise/profile_management/oidc_auth_response_capture_navigation_throttle.cc"
NTP_MICROSOFT_THROTTLE = "chrome/browser/ui/webui/ntp_microsoft_auth/ntp_microsoft_auth_response_capture_navigation_throttle.cc"
NTP_MICROSOFT_UI = "chrome/browser/ui/webui/ntp_microsoft_auth/ntp_microsoft_auth_untrusted_ui.cc"
CHROME_PAGES = "chrome/browser/ui/chrome_pages.cc"
CONTENT_CLIENT = "chrome/browser/chrome_content_browser_client.cc"
SEARCH_ENGINES = "third_party/search_engines_data/resources/definitions/prepopulated_engines.json"
SAFE_BROWSING = "components/safe_browsing/core/common/features.cc"

CONNECTOR_URLS = '''     "https://scan.webprotect-us.goog/uploads",
     "https://scan.webprotect-eu.goog/uploads"}
'''

ARX_CONNECTOR_URLS = '''     // Arx (DEV-930): no enterprise content analysis.
     "https://scan.webprotect-us.qjz9zk/uploads",
     "https://scan.webprotect-eu.qjz9zk/uploads"}
'''

TAB_CONTEXT_ORIGIN = '''const char kDefaultTabContextAllowedOrigin[] = "https://chromestorage.goog";
'''

ARX_TAB_CONTEXT_ORIGIN = '''// Arx (DEV-930): no tab context sync.
const char kDefaultTabContextAllowedOrigin[] = "https://chromestorage.qjz9zk";
'''

OIDC_URL = '''constexpr char kEnterpriseOidcRegisterUrl[] =
    "https://chromeenterprise.google/profile-enrollment/register-handler";
'''

ARX_OIDC_URL = '''// Arx (DEV-930): no enterprise profile enrollment.
constexpr char kEnterpriseOidcRegisterUrl[] =
    "https://chromeenterprise.qjz9zk/profile-enrollment/register-handler";
'''

NTP_MICROSOFT_URL = '''constexpr char kEnrollmentFallbackUrl[] =
    "https://chromeenterprise.google/ntp-microsoft-auth";
'''

ARX_NTP_MICROSOFT_URL = '''// Arx (DEV-930): no managed new tab page.
constexpr char kEnrollmentFallbackUrl[] =
    "https://chromeenterprise.qjz9zk/ntp-microsoft-auth";
'''

NTP_MICROSOFT_CSP = '''      "child-src https://login.microsoftonline.com "
      "https://chromeenterprise.google;");
'''

ARX_NTP_MICROSOFT_CSP = '''      // Arx (DEV-930): no managed new tab page.
      "child-src https://login.microsoftonline.com "
      "https://chromeenterprise.qjz9zk;");
'''

RELEASE_NOTES = '''      {"https://chromeenterprise.google/resources/release-notes/",
'''

ARX_RELEASE_NOTES = '''      // Arx (DEV-930): Arx has no enterprise release notes.
      {"https://chromeenterprise.qjz9zk/resources/release-notes/",
'''

# The two console messages share their text, so each anchor takes what follows it.
SANDBOX_BLOCKED = '''              "https://chromestatus.com/feature/5680742077038592 and "
              "https://chromeenterprise.google/policies/"
              "#SandboxExternalProtocolBlocked");
          return;
'''

ARX_SANDBOX_BLOCKED = '''              // Arx (DEV-930): no enterprise policy link.
              "https://chromestatus.com/feature/5680742077038592.");
          return;
'''

SANDBOX_WARNING = '''              "https://chromestatus.com/feature/5680742077038592 and "
              "https://chromeenterprise.google/policies/"
              "#SandboxExternalProtocolBlocked");
        }
'''

ARX_SANDBOX_WARNING = '''              // Arx (DEV-930): no enterprise policy link.
              "https://chromestatus.com/feature/5680742077038592.");
        }
'''

LENS = '''      "suggest_url": "https://www.google.com/complete/search?client=chrome&q={searchTerms}",
      "image_url": "https://lens.google.com/upload",
      "image_url_post_params": "encoded_image={google:imageThumbnail}",
'''

ARX_LENS = '''      "suggest_url": "https://www.google.com/complete/search?client=chrome&q={searchTerms}",
      // Arx (DEV-930): no "Search image with Google" (Lens).
'''


SAFE_BROWSING_RELAY = """    /*default_value=*/
    "https://ohttp-relay-safebrowsing-chrome.google.fastly-edge.com/"};
"""

ARX_SAFE_BROWSING_RELAY = """    // Arx (DEV-930): no Google Safe Browsing.
    /*default_value=*/
    "https://ohttp-relay-safebrowsing-chrome.qjz9zk/"};
"""


def patches():
    yield HELPERS_HEADER, DEFAULT_ORIGIN, ARX_DEFAULT_ORIGIN
    yield HELPERS_HEADER, PUSH_SERVER, ARX_PUSH_SERVER
    yield HELPERS, UPDATE_BASE, ARX_UPDATE_BASE
    yield HELPERS, BASE_URL, ARX_BASE_URL
    yield HELPERS, SHOULD_ACCESS, ARX_SHOULD_ACCESS
    yield CRASH_CLIENT, UPLOAD_URL, ARX_UPLOAD_URL
    yield DOWNLOADER, PING_DOMAIN, ARX_PING_DOMAIN
    yield CONNECTORS, CONNECTOR_URLS, ARX_CONNECTOR_URLS
    yield TAB_CONTEXT, TAB_CONTEXT_ORIGIN, ARX_TAB_CONTEXT_ORIGIN
    yield OIDC_THROTTLE, OIDC_URL, ARX_OIDC_URL
    yield NTP_MICROSOFT_THROTTLE, NTP_MICROSOFT_URL, ARX_NTP_MICROSOFT_URL
    yield NTP_MICROSOFT_UI, NTP_MICROSOFT_CSP, ARX_NTP_MICROSOFT_CSP
    yield CHROME_PAGES, RELEASE_NOTES, ARX_RELEASE_NOTES
    yield CONTENT_CLIENT, SANDBOX_BLOCKED, ARX_SANDBOX_BLOCKED
    yield CONTENT_CLIENT, SANDBOX_WARNING, ARX_SANDBOX_WARNING
    yield SEARCH_ENGINES, LENS, ARX_LENS
    yield SAFE_BROWSING, SAFE_BROWSING_RELAY, ARX_SAFE_BROWSING_RELAY


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
