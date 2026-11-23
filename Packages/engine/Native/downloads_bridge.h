#ifndef ARX_DOWNLOADS_BRIDGE_H
#define ARX_DOWNLOADS_BRIDGE_H

#include <string>
#include "chrome/browser/arx/ChromiumBridge.h"
#include "services/network/public/mojom/referrer_policy.mojom-forward.h"

class GURL;
class Profile;
namespace content { class RenderFrameHost; class WebContents; }
namespace arx {
// Only for a freshly created Arx OTR context, before publishing it to pages.
void InitializePrivateDownloadPreferences(Profile* profile);
void ObserveDownloads(Profile* profile, const std::string& key,
                      const ArxEngineCallbacks& callbacks);
bool CancelDownload(const std::string& key, const std::string& guid);
// DEV-892, exported outside the ABI table as ArxEngineSetDownloadPaused and
// ArxEngineDownloadControl. Ordinary and private transfers alike.
bool SetDownloadPaused(const std::string& key, const std::string& guid, bool paused);
uint32_t DownloadControl(const std::string& key, const std::string& guid);
// DEV-892 Remove from List, exported as ArxEngineRemoveDownload.
bool RemoveDownload(const std::string& key, const std::string& guid);
// ABI33. Ordinary observed profiles only; replies once through download_started.
bool StartDownload(Profile* profile, const std::string& key, uint64_t request,
                   const GURL& url, const ArxEngineCallbacks& callbacks);
// ABI56 (DEV-851). A link menu's Download Linked File, as Chrome's Save Link As:
// started from the link's own frame, with that frame's sanitized referrer, its
// charset and the link's suggested name. Otherwise as StartDownload.
bool StartLinkDownload(content::RenderFrameHost* source, Profile* profile,
                       const std::string& key, uint64_t request, const GURL& url,
                       const GURL& frame_url, network::mojom::ReferrerPolicy referrer_policy,
                       const std::string& frame_charset, const std::u16string& suggested_name,
                       const ArxEngineCallbacks& callbacks);
uint64_t ActiveDownloadCount();
// DEV-1130, exported outside the ABI table as ArxEngineLostOnQuitDownloadCount: transfers in
// progress, paused ones included, that a quit would lose. Private ones always; ordinary ones
// Chromium couldn't continue where they stopped.
uint64_t LostOnQuitDownloadCount();
void CancelAllDownloads();
// Active transfers and queued native notifications retain this exact context.
bool DownloadsRetainProfile(Profile* profile);
void StopDownloads(Profile* profile);
void StopAllDownloads();
uint64_t PageIdentifier(content::WebContents* contents);
void DownloadActivityChanged(Profile* profile);
}
#endif
