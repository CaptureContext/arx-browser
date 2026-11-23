#ifndef ARX_LINK_NAVIGATION_BRIDGE_H
#define ARX_LINK_NAVIGATION_BRIDGE_H

class GURL;
namespace content { class NavigationHandle; }

namespace arx {
// ABI43 (DEV-727). True for a plain click on a link to another site: a
// renderer-initiated GET in the primary main frame with a user gesture and a
// link transition, not a reload, history or same-document navigation, from a
// committed http(s) page to an http(s) URL of a different site (eTLD+1,
// private registries included). Redirects are never asked: only the request's
// start is checked.
bool IsCrossSiteLinkClick(content::NavigationHandle& navigation);
bool IsCrossSite(const GURL& from, const GURL& to);
}  // namespace arx

#endif
