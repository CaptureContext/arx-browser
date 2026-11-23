#ifndef ARX_EXTERNAL_LINK_BRIDGE_H
#define ARX_EXTERNAL_LINK_BRIDGE_H

#include <optional>

#include "base/functional/callback.h"
#include "ui/base/page_transition_types.h"

class GURL;
namespace content { class WebContents; }
namespace url { class Origin; }

namespace arx {
// ABI50 (DEV-857). Called from ExternalProtocolHandler::LaunchUrl after
// Chrome's block policy, anti-flood check and source guard, before its handler
// lookup, dialog, remembered consent or OS launch. Declared apart from
// engine_bridge.h so Chrome's external_protocol target needs only this.
//
// True when `contents` is an Arx page and the app takes external link offers.
bool OffersExternalLinks(content::WebContents* contents);
// Offers `url` to the app after a posted task. `chrome_path` is the rest of
// Chrome's own path (handler lookup, dialog, launch): it runs when the app
// declines and is dropped when the app takes the link, the page's document
// changed first or `source_guard` (Chrome's exact initiator check, empty when
// there is none) fails. `source_origin` is the actual initiating origin; an
// opaque one is reported as unknown. Always consumes `chrome_path`.
void OfferExternalLink(content::WebContents* contents, const GURL& url,
                       const std::optional<url::Origin>& source_origin,
                       ui::PageTransition transition, bool has_user_gesture,
                       base::RepeatingCallback<bool()> source_guard,
                       base::OnceClosure chrome_path);
}  // namespace arx

#endif
