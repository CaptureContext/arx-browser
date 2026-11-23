#ifndef ARX_BROWSING_DATA_BRIDGE_H
#define ARX_BROWSING_DATA_BRIDGE_H

#include <cstdint>

#include "chrome/browser/arx/ChromiumBridge.h"

class Profile;

namespace arx {
// ABI39 (DEV-647). Clear Browsing Data over the profile's BrowsingDataRemover
// and Chromium's counters, and the profile's downloads location and "Ask
// where to save" over DownloadPrefs, one ordinary profile at a time.
using ProfileDataReply = void (*)(uint64_t request, ArxProfileDataStatus status,
                                  const uint8_t* json, size_t size);

void StartProfileData(ProfileDataReply reply);
// Drops every count and clear in flight. Replies already posted are dropped.
void StopProfileData();

// A null profile (unknown, private or stopped) replies UNAVAILABLE.
void CountBrowsingData(Profile* profile, uint64_t request, uint32_t kinds, double since);
void ClearBrowsingData(Profile* profile, uint64_t request, uint32_t kinds, double since);
void ReadDownloadSettings(Profile* profile, uint64_t request);
void SetDownloadSettings(Profile* profile, uint64_t request, const char* directory, bool ask);
// ABI40 (DEV-633). One site's cookies and site storage, or cache, from the
// site menu: the url's registrable domain (or its host when it has none).
void SiteDataScope(Profile* profile, uint64_t request, const char* url);
void ClearSiteData(Profile* profile, uint64_t request, const char* url, uint32_t kinds);
}  // namespace arx

#endif
