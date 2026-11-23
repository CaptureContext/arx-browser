#include "chrome/browser/arx/page_zoom_bridge.h"

#include <string>

#include "content/public/browser/host_zoom_map.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "net/base/url_util.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "url/gurl.h"

namespace arx {
namespace {
constexpr double kMinimumFactor = 0.25;
constexpr double kMaximumFactor = 5.0;
}  // namespace

double PageZoomFactor(content::WebContents* contents, double* default_factor) {
  if (!contents) return 0;
  if (default_factor) {
    auto* map = content::HostZoomMap::GetForWebContents(contents);
    *default_factor = map ? blink::ZoomLevelToZoomFactor(map->GetDefaultZoomLevel()) : 1;
  }
  return blink::ZoomLevelToZoomFactor(content::HostZoomMap::GetZoomLevel(contents));
}

bool SetPageZoomFactor(content::WebContents* contents, double factor) {
  if (!contents) return false;
  if (factor != 0 && !(factor >= kMinimumFactor && factor <= kMaximumFactor)) return false;
  auto* map = content::HostZoomMap::GetForWebContents(contents);
  if (!map) return false;
  const content::GlobalRenderFrameHostId frame =
      contents->GetPrimaryMainFrame()->GetGlobalId();
  // Actual Size also undoes a pinch or smart magnification, as Chrome's reset does.
  if (factor == 0) contents->SetPageScale(1.f);
  const GURL url = content::HostZoomMap::GetURLForWebContents(contents);
  const double level = factor == 0 ? map->GetDefaultZoomLevel()
                                   : blink::ZoomFactorToZoomLevel(factor);
  if (map->UsesTemporaryZoomLevel(frame) || !url.has_host()) {
    // Clearing would fall back to the host's level and end the page's isolation.
    map->SetTemporaryZoomLevel(frame, level);
    return true;
  }
  // Matches the default: HostZoomMap erases the host's entry instead.
  map->SetZoomLevelForHost(net::GetHostOrSpecFromURL(url), level);
  return true;
}
}  // namespace arx
