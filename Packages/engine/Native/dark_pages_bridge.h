#ifndef ARX_DARK_PAGES_BRIDGE_H_
#define ARX_DARK_PAGES_BRIDGE_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace blink::web_pref {
struct WebPreferences;
}  // namespace blink::web_pref

namespace content {
class WebContents;
}  // namespace content

namespace arx {
// DEV-1020 dark pages: Blink's forced darkening for the sites of Arx's pages
// that have no dark look of their own. A darkened page gets
// force_dark_mode_enabled and a dark preferred color scheme, so an element
// whose color-scheme includes dark keeps the site's own dark theme, `only
// light` opts out, and everything else is darkened by Blink's auto dark mode.
// Main thread.

// The setting a page starts with before the app sets its own: on or off. A new
// page that starts dark shows its blank document dark, so it never flashes
// white before its first site loads.
void SetDefaultDarkPages(bool enabled);

// Arx's own pages only: gives contents the default setting, before its first
// navigation.
void AttachDarkPages(content::WebContents* contents);

// Sets contents' dark pages: on or off, and the sites it stays off on, each a
// lowercased host without "www." that also covers its subdomains, as
// KeptLoadedSite matches. Applies to the current document at once and to
// every later navigation.
void SetDarkPages(content::WebContents* contents,
                  bool enabled,
                  std::vector<std::string> off_sites);

// From ChromeContentBrowserClient::OverrideWebPreferences and
// OverrideWebPreferencesAfterNavigation, after the color scheme is computed:
// darkens an Arx page whose main document should be dark. Contents without a
// setting (Chrome's own, DevTools, extension pages) are left alone. Returns
// whether it changed prefs.
bool ApplyDarkPages(content::WebContents* contents,
                    blink::web_pref::WebPreferences* prefs);
}  // namespace arx

extern "C" {
// DEV-1020, outside the ABI table so engines built before it still load
// (ChromiumDarkPages.swift looks it up). Main thread, once the engine runs.
// page 0 sets the default for pages created later (off_sites is ignored);
// otherwise sets that page's, ordinary or private. off_sites is borrowed for
// the call. False for an unknown page or a site list over 4,096 entries.
__attribute__((visibility("default")))
bool ArxEngineSetPageDarkPages(uint64_t page,
                               bool enabled,
                               const char* const* off_sites,
                               size_t count);
}

#endif  // ARX_DARK_PAGES_BRIDGE_H_
