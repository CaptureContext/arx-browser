"""Let Arx offer plain clicks on links to other sites to the app (ABI43, DEV-727).

Chrome's throttles for every navigation gain one Arx throttle, added only for a
plain click on a link to another site in an Arx page. Its code lives in the
whole file `Native/link_navigation_bridge.mm`; this overlay adds one call.
"""
from .overlay import replace_once

CLIENT = "chrome/browser/chrome_content_browser_client.cc"


def patches():
    yield CLIENT, """    content::NavigationThrottleRegistry& registry) {
  CreateAndAddChromeThrottlesForNavigation(registry);
}""", """    content::NavigationThrottleRegistry& registry) {
  CreateAndAddChromeThrottlesForNavigation(registry);
#if BUILDFLAG(IS_MAC)
  arx::AddLinkNavigationThrottle(registry);
#endif
}"""


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
