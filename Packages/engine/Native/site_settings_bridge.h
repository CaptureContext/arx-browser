#ifndef ARX_SITE_SETTINGS_BRIDGE_H
#define ARX_SITE_SETTINGS_BRIDGE_H

#include <cstdint>

#include "chrome/browser/arx/ChromiumBridge.h"

class Profile;

namespace arx {
// ABI38 (DEV-716). Site permissions over the profile's HostContentSettingsMap
// and per-host zoom over its HostZoomMap, one ordinary profile at a time.
using SiteSettingsReply = void (*)(uint64_t request, ArxSiteSettingsStatus status,
                                   const uint8_t* json, size_t size);
using SiteSettingsChanged = void (*)(const char* profile_key);

void StartSiteSettings(SiteSettingsReply reply, SiteSettingsChanged changed);
// Stops watching every profile. Replies already posted are dropped.
void StopSiteSettings();

// A null profile (unknown, private or stopped) replies UNAVAILABLE. Listing a
// profile starts watching it for changes until it is destroyed or Stop.
void ListSiteSettings(Profile* profile, const char* key, uint64_t request);
void SetSitePermission(Profile* profile, const char* key, uint64_t request, const char* origin,
                       ArxSitePermission permission, ArxSitePermissionSetting setting);
void SetSiteZoom(Profile* profile, const char* key, uint64_t request, const char* host,
                 double factor);
}  // namespace arx

#endif
