#ifndef ARX_SITE_ICONS_BRIDGE_H_
#define ARX_SITE_ICONS_BRIDGE_H_

#include <memory>
#include "chrome/browser/arx/ChromiumBridge.h"

class Profile;
class GURL;
namespace content { class WebContents; }

namespace arx {
// ABI51 (DEV-940): icon_url is the favicon the page now shows, empty if unknown.
using SiteIconChanged = void (*)(uint64_t page, const char* page_url, const char* icon_url);
// ABI51 (DEV-940): a committed main-frame navigation's redirect chain, oldest
// first, ending with the committed URL. Only sent when it redirected.
using SiteIconRedirected = void (*)(uint64_t page, const char* const* page_urls, size_t count,
                                    bool truncated);
// ABI51 (DEV-940): icon_url is the favicon the bitmap belongs to, empty if unknown.
// DEV-1108: a MISSING reply with an icon_url dropped the icon fetched at that URL
// as another host's and found none of the page's own; callers forget their copy.
using SiteIconCompleted = void (*)(uint64_t request, ArxSiteIconStatus status,
                                   const uint8_t* png, size_t size, uint32_t width,
                                   uint32_t height, const char* icon_url);

// The page owns this observation and destroys it before its WebContents.
// Private WebContents are deliberately unsupported, including parent cache reads.
class SiteIconObservation {
 public:
  virtual ~SiteIconObservation() = default;
};
std::unique_ptr<SiteIconObservation> ObserveSiteIcons(
    uint64_t page, content::WebContents* contents, SiteIconChanged changed,
    SiteIconRedirected redirected);

// All entry points run on the UI sequence. Lookup reads the profile database
// for the exact page, never another URL on the host. On a miss with
// `may_fetch`, it fetches the icon the app's directory or the site's root page
// declares, or /favicon.ico, through that profile's own network context; the
// pages go with the profile's cookies for their site (none saved back), the
// icons without (DEV-1108). A page that redirected to another host gives only
// the site's own /favicon.ico;
// the saved URL itself is never requested. The icon is decoded in the data
// decoder, stored as an on-demand favicon for the page (replaced by the page's
// own on its first load) and returned. Nothing navigates or renders; private
// profiles are refused. Callers pass false while a page shows the URL, since
// its favicon driver is about to fill the database. An on-demand icon fetched
// before DEV-1108 (no `#arx-site-icon-2` marker) is a miss to a database-only
// read and fetched again when the lookup may; it is replaced only once that
// refetch has an answer.
void LookupSiteIcon(Profile* profile, const GURL& page_url, bool may_fetch,
                    uint64_t request, SiteIconCompleted completed);
void CancelSiteIcon(uint64_t request);
// ABI50 (DEV-796, Settings). Whether a lookup that misses may fetch at all; on
// by default. Rechecked before each network stage, so turning it off also stops
// lookups already fetching. Any thread; settable before the runtime starts.
void SetSiteIconFetchEnabled(bool enabled);
bool SiteIconFetchEnabled();
// UI sequence: ends lookups that are fetching (their downloads stop and they
// answer MISSING); database reads are left to finish.
void StopSiteIconFetches();
void StopSiteIcons();
}  // namespace arx

#endif  // ARX_SITE_ICONS_BRIDGE_H_
