#ifndef ARX_PAGE_ZOOM_BRIDGE_H
#define ARX_PAGE_ZOOM_BRIDGE_H

namespace content { class WebContents; }

namespace arx {
// ABI41 (DEV-726). The page's zoom factor (1.0 is 100%), temporary or for its
// host, or 0 without contents. default_factor, when given, receives the
// profile's default zoom, which Zoom In and Zoom Out step through too.
double PageZoomFactor(content::WebContents* contents, double* default_factor);

// Sets the page's zoom factor (0.25-5.0), as Chrome's Zoom In and Zoom Out do:
// for the committed URL's host in the page's own HostZoomMap, so every page on
// that host follows. An ordinary profile's map is persistent and reaches Site
// Settings; a private profile's map lives only as long as that profile. A page
// without a host (file:, data:) or one already on a temporary level keeps the
// factor to itself, Actual Size included. Factor 0 returns to the default zoom and resets pinch
// magnification. False without
// contents or for a factor out of range.
bool SetPageZoomFactor(content::WebContents* contents, double factor);
}  // namespace arx

#endif
