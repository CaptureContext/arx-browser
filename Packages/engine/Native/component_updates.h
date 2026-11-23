// Components Arx keeps updating over the network (DEV-874).
//
// Helium sends component update checks to its own services and gets a dummy
// host until the person consents on Helium's onboarding page, which Arx never
// shows. Arx instead checks Google's component update service directly, for
// these components only. Every other component is never registered, so it is
// neither loaded from disk nor requested.
//
// Header-only and dependency-free: `components/component_updater` and
// `chrome/browser/component_updater` include it with `nogncheck`.

#ifndef CHROME_BROWSER_ARX_COMPONENT_UPDATES_H_
#define CHROME_BROWSER_ARX_COMPONENT_UPDATES_H_

#include <algorithm>
#include <array>
#include <string_view>

namespace arx {

// Certificate revocation list (crl_set_component_installer.cc).
inline constexpr std::string_view kCRLSetComponentId =
    "hfnkpimlhhgieaddgfemjhofmfblmnib";
// Certificate Transparency logs, Chrome Root Store and key pins
// (pki_metadata_component_installer_policy.cc).
inline constexpr std::string_view kPKIMetadataComponentId =
    "efniojlnjndmcbiieegkicadnoecjjef";
// The explanations on certificate error pages
// (ssl_error_assistant_component_installer.cc).
inline constexpr std::string_view kSSLErrorAssistantComponentId =
    "giekcmmlnklenlaomppkphknjmnnpneh";

// To add a component (the Widevine CDM, "oimompecagnajdejgnnjijobebaeigek", if
// DEV-877 picks it), add its ID here, list its install directory in
// BrowserSecurityComponent.Kind and Scripts/component_updates_smoke.py, and say
// in the manual's privacy page what it downloads.
inline constexpr auto kNetworkUpdatedComponents = std::to_array<std::string_view>({
    kCRLSetComponentId,
    kPKIMetadataComponentId,
    kSSLErrorAssistantComponentId,
});

inline bool IsNetworkUpdatedComponent(std::string_view crx_id) {
  return std::ranges::find(kNetworkUpdatedComponents, crx_id) !=
         kNetworkUpdatedComponents.end();
}

// Google's component update service. Responses are signed (CUP) and every
// download is a CRX3 checked against its component's key.
inline constexpr char kComponentUpdateURL[] =
    "https://update.googleapis.com/service/update2/json";

// What an update check tells the service: enough to answer it, and nothing
// that identifies this Mac, counts its use or describes its hardware. Every
// other field Chromium would send (hw, updaters, ping, cohort, install dates,
// brand, events, ...) is removed before the request is signed and sent.
inline constexpr auto kComponentRequestKeys = std::to_array<std::string_view>({
    "@os", "@updater", "acceptformat", "apps", "arch", "dedup", "ismachine",
    "os", "prodchannel", "prodversion", "protocol", "requestid", "sessionid",
    "updaterchannel", "updaterversion",
});
inline constexpr auto kComponentAppKeys = std::to_array<std::string_view>({
    "appid", "updatecheck", "version",
});

}  // namespace arx

#endif  // CHROME_BROWSER_ARX_COMPONENT_UPDATES_H_
