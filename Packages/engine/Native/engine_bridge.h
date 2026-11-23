#ifndef ARX_ENGINE_BRIDGE_INTERNAL_H
#define ARX_ENGINE_BRIDGE_INTERNAL_H

#include <string>
#include <optional>

class ChromeBrowserMainParts;
class Profile;
class GURL;
#include <cstdint>
struct NavigateParams;
namespace content { class BrowserContext; class NavigationThrottleRegistry; class RenderFrameHost; class WebContents; }
namespace extensions { class Extension; }
namespace base { class FilePath; }
namespace arx {
bool IsEmbedded();
bool ProfileErasureMayQueue(const std::string& key);
// DEV-880. Whether the profile at `path`, released earlier in this run, keeps
// its session cookies when it loads again (session_cookies_overlay.py).
bool ProfileReloadKeepsSession(const base::FilePath& path);

// Called only after native inventory/manifest authority has been established.
// Never takes a caller-supplied URL or foreign WebContents.
bool AdoptExtensionOptions(Profile* profile, const std::string& key,
    const std::string& extension_id, const GURL& manifest_url, uint64_t request);

// Actual RuntimeAPI origin only; never exposed as a caller-supplied C request.
std::optional<std::string> CurrentExtensionProfileKey(Profile* profile);
bool AdoptRuntimeExtensionOptions(Profile* profile, const std::string& key,
    const extensions::Extension* exact_extension, const GURL& manifest_url);

void CapturePopupSource(content::RenderFrameHost* opener);
// True means Arx owns the source, including a refused/stale UI action. Foreign
// Chrome sources retain their original navigator. No arbitrary URL entry point.
bool NavigateBlockedPopup(NavigateParams* params);
bool ExtensionProfileIsCurrent(Profile* profile, const std::string& key);
// The Arx page showing `contents`, or 0.
uint64_t PageIdentifier(content::WebContents* contents);
// DEV-877, DEV-927. The contents of the Arx page `page`, or null. Main thread.
content::WebContents* PageContents(uint64_t page);
// DEV-1172. The identity Arx gave page `page`'s current document, or "" while
// the engine isn't running or `page` isn't an Arx page. Main thread.
std::string PageDocumentID(uint64_t page);
// DEV-877. An ordinary profile Arx loaded ("" for the legacy one), or null
// while it isn't loaded, is being erased or is private.
Profile* LoadedOrdinaryProfile(const char* key);
void AttachEngine(ChromeBrowserMainParts* parts);
// ABI24. The view saw a Force Click; true when the app took the hovered link,
// so the press must skip Look Up and never complete as a click.
bool HandleLinkForceClick(content::WebContents* contents);
// ABI43 (DEV-727). AddLinkNavigationThrottle is called from Chrome's
// CreateThrottlesForNavigation; its throttle (link_navigation_bridge.mm) asks
// whether an Arx page wants cross-site link offers, then offers one after a
// posted task. True from OfferCrossSiteLink means the app took the link.
void AddLinkNavigationThrottle(content::NavigationThrottleRegistry& registry);
bool AsksForCrossSiteLinks(content::WebContents* contents);
bool OfferCrossSiteLink(content::WebContents* contents, const GURL& url, int64_t navigation_id);
// DEV-907. Chromium's BadgeManager reports the Badging API for a tab's main
// document (badge_overlay.py): `set` false clears it, `flag` is a badge
// without a number, else `count`.
void PageBadgeChanged(content::WebContents* contents, bool set, uint64_t count, bool flag);
// DEV-956. A private window's context whose opener profile is loaded and shows
// extensions, so its pages get the extensions allowed in private windows.
bool PrivateExtensionContextIsCurrent(content::BrowserContext* context);
// ABI56 (DEV-963). Posts page_permission_prompt_changed for Arx page `page`: its
// hosted prompt `token` became current, or 0 when it went away.
void PagePermissionPromptChanged(uint64_t page, uint64_t token);
}

#endif
