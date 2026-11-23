#include "chrome/browser/arx/link_navigation_bridge.h"

#include <memory>

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/reload_type.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "ui/base/page_transition_types.h"
#include "url/gurl.h"

namespace arx {
namespace {

// Defers a cross-site link click and asks the app after a posted task, so the
// app never runs inside Chromium's throttle call. The navigation goes on unless
// the app takes the link; a navigation that ends first drops the question.
class LinkNavigationThrottle : public content::NavigationThrottle {
 public:
  explicit LinkNavigationThrottle(content::NavigationThrottleRegistry& registry)
      : content::NavigationThrottle(registry) {}

  ThrottleCheckResult WillStartRequest() override {
    content::NavigationHandle& navigation = *navigation_handle();
    if (!IsCrossSiteLinkClick(navigation) || !AsksForCrossSiteLinks(navigation.GetWebContents()))
      return PROCEED;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&LinkNavigationThrottle::Ask, weak_factory_.GetWeakPtr()));
    return DEFER;
  }

  const char* GetNameForLogging() override { return "ArxLinkNavigationThrottle"; }

 private:
  void Ask() {
    content::NavigationHandle& navigation = *navigation_handle();
    const auto weak = weak_factory_.GetWeakPtr();
    const bool taken = OfferCrossSiteLink(navigation.GetWebContents(), navigation.GetURL(),
                                          navigation.GetNavigationId());
    // The app may have closed the page, which destroys this throttle.
    if (!weak) return;
    if (taken) {
      CancelDeferredNavigation(CANCEL_AND_IGNORE);
    } else {
      Resume();
    }
  }

  base::WeakPtrFactory<LinkNavigationThrottle> weak_factory_{this};
};

}  // namespace

bool IsCrossSite(const GURL& from, const GURL& to) {
  if (!from.is_valid() || !to.is_valid() || !from.SchemeIsHTTPOrHTTPS() ||
      !to.SchemeIsHTTPOrHTTPS()) return false;
  return !net::registry_controlled_domains::SameDomainOrHost(
      from, to, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
}

bool IsCrossSiteLinkClick(content::NavigationHandle& navigation) {
  if (!navigation.IsInPrimaryMainFrame() || !navigation.IsRendererInitiated() ||
      !navigation.HasUserGesture() || navigation.IsSameDocument() || navigation.IsHistory() ||
      navigation.IsPost() || navigation.IsExternalProtocol() ||
      navigation.GetReloadType() != content::ReloadType::NONE)
    return false;
  const ui::PageTransition transition = navigation.GetPageTransition();
  if (!ui::PageTransitionCoreTypeIs(transition, ui::PAGE_TRANSITION_LINK) ||
      (transition & ui::PAGE_TRANSITION_FORWARD_BACK) ||
      (transition & ui::PAGE_TRANSITION_CLIENT_REDIRECT))
    return false;
  const GURL& url = navigation.GetURL();
  if (url.has_username() || url.has_password() || url.spec().size() > 8192) return false;
  content::RenderFrameHost* current = navigation.GetWebContents()->GetPrimaryMainFrame();
  return current && IsCrossSite(current->GetLastCommittedURL(), url);
}

void AddLinkNavigationThrottle(content::NavigationThrottleRegistry& registry) {
  content::NavigationHandle& navigation = registry.GetNavigationHandle();
  if (!IsCrossSiteLinkClick(navigation) || !AsksForCrossSiteLinks(navigation.GetWebContents()))
    return;
  registry.AddThrottle(std::make_unique<LinkNavigationThrottle>(registry));
}

}  // namespace arx
