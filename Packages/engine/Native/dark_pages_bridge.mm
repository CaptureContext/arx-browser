#include "chrome/browser/arx/dark_pages_bridge.h"

#include <utility>

#include "base/strings/string_util.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_user_data.h"
#include "third_party/blink/public/common/web_preferences/web_preferences.h"
#include "third_party/blink/public/mojom/css/preferred_color_scheme.mojom-shared.h"
#include "url/gurl.h"

namespace arx {

// A page's dark pages setting, kept with its contents.
class DarkPagesData final : public content::WebContentsUserData<DarkPagesData> {
 public:
  ~DarkPagesData() override = default;

  bool enabled = false;
  std::vector<std::string> off_sites;

 private:
  explicit DarkPagesData(content::WebContents* contents)
      : content::WebContentsUserData<DarkPagesData>(*contents) {}

  friend class content::WebContentsUserData<DarkPagesData>;
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(DarkPagesData);

namespace {

// Main thread. A plain bool: base::NoDestructor rejects trivially destructible
// types.
bool g_default_enabled = false;

// The site of an http(s) address as KeptLoadedSite.site(of:) reads it: the
// lowercased host without a trailing dot or a leading "www.". IPv6 hosts keep
// their brackets, as GURL gives them. Empty for any other address.
std::string SiteOf(const GURL& url) {
  if (!url.SchemeIsHTTPOrHTTPS()) return std::string();
  std::string host = base::ToLowerASCII(url.host());
  if (base::EndsWith(host, ".")) host.pop_back();
  if (base::StartsWith(host, "www.") && host.size() > 4) host.erase(0, 4);
  return host;
}

bool IsOff(const std::string& site, const std::vector<std::string>& off_sites) {
  for (const auto& off : off_sites) {
    if (site == off || base::EndsWith(site, "." + off)) return true;
  }
  return false;
}

// Whether the page's main document is darkened: an http(s) site that isn't
// turned off, or the blank document a new page starts with.
bool ShouldDarken(content::WebContents* contents, const DarkPagesData& data) {
  if (!data.enabled) return false;
  const GURL& url = contents->GetPrimaryMainFrame()->GetLastCommittedURL();
  if (url.is_empty() || url.IsAboutBlank()) return true;
  const std::string site = SiteOf(url);
  return !site.empty() && !IsOff(site, data.off_sites);
}

}  // namespace

void SetDefaultDarkPages(bool enabled) {
  g_default_enabled = enabled;
}

void AttachDarkPages(content::WebContents* contents) {
  if (DarkPagesData::FromWebContents(contents)) return;
  DarkPagesData::CreateForWebContents(contents);
  auto* data = DarkPagesData::FromWebContents(contents);
  data->enabled = g_default_enabled;
  if (data->enabled) contents->NotifyPreferencesChanged();
}

void SetDarkPages(content::WebContents* contents,
                  bool enabled,
                  std::vector<std::string> off_sites) {
  auto* data = DarkPagesData::FromWebContents(contents);
  if (!data) {
    DarkPagesData::CreateForWebContents(contents);
    data = DarkPagesData::FromWebContents(contents);
  }
  const bool was = ShouldDarken(contents, *data);
  data->enabled = enabled;
  data->off_sites = std::move(off_sites);
  // Recomputing runs ApplyDarkPages again; only a change is worth a restyle.
  if (ShouldDarken(contents, *data) != was) contents->NotifyPreferencesChanged();
}

bool ApplyDarkPages(content::WebContents* contents,
                    blink::web_pref::WebPreferences* prefs) {
  const auto* data = DarkPagesData::FromWebContents(contents);
  if (!data || !ShouldDarken(contents, *data)) {
    // A page that stops being dark goes back to Chrome's own values, which
    // OverrideWebPreferences just computed; after a navigation they stand.
    if (!data || !prefs->force_dark_mode_enabled) return false;
    prefs->force_dark_mode_enabled = false;
    return true;
  }
  bool changed = !prefs->force_dark_mode_enabled ||
                 prefs->preferred_color_scheme != blink::mojom::PreferredColorScheme::kDark;
  prefs->force_dark_mode_enabled = true;
  // A site whose color-scheme includes dark keeps its own dark theme. One with
  // only prefers-color-scheme rules gets them, still marked forced: Blink's
  // thresholds leave its dark colors, but accents and images may change
  // (DEV-1077).
  prefs->preferred_color_scheme = blink::mojom::PreferredColorScheme::kDark;
  prefs->preferred_root_scrollbar_color_scheme = blink::mojom::PreferredColorScheme::kDark;
  return changed;
}

}  // namespace arx
