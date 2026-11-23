"""Keep pages that hold a WebSocket or WebTransport connection out of infinite tabs freezing (DEV-879).

Blink fails a page's WebSocket and closes its WebTransport session when the page freezes, so a chat
tab pushed out of the most recent tabs disconnects at every freeze. `content::ArxPageHoldsLiveConnection`
(Native/content/arx_live_connection.*) reads the frames' back/forward cache features; FreezingPolicy then
leaves such a page running under InfiniteTabsFreezing, with or without memory pressure. Voting and
Battery Saver freezing stay Chrome's. Tab unloading asks the same function (page_unload_bridge.mm).

Runs after media_freeze_overlay and anchors only on upstream text that overlay leaves alone.
"""

import shutil

POLICY = "components/performance_manager/freezing/freezing_policy.cc"

HELPER = """// Arx (DEV-879): a page holding a WebSocket or WebTransport connection, which a
// freeze would end. Not a CannotFreezeReason: nothing reports when it changes,
// so UpdateFrozenState asks it when it would freeze for infinite tabs.
bool ArxPageNodeHoldsLiveConnection(const PageNode* page_node) {
  base::WeakPtr<content::WebContents> contents = page_node->GetWebContents();
  return contents && content::ArxPageHoldsLiveConnection(contents.get());
}

"""

LIVE_CONNECTION = """
  // Arx (DEV-879): asked only when infinite tabs freezing would freeze.
  const auto holds_live_connection = [&connected_pages] {
    for (const PageNode* connected_page : connected_pages) {
      if (ArxPageNodeHoldsLiveConnection(connected_page)) {
        return true;
      }
    }
    return false;
  };
"""


def patches():
    """(relative path, upstream anchor, replacement) for each edit."""
    yield ("content/public/browser/BUILD.gn", '    "attribution_data_model.cc",',
           '    "arx_live_connection.h",\n    "attribution_data_model.cc",')
    yield ("content/browser/BUILD.gn", '    "renderer_host/agent_scheduling_group_host.cc",',
           '    "renderer_host/agent_scheduling_group_host.cc",\n    "renderer_host/arx_live_connection.cc",')
    yield (POLICY, '#include "content/public/common/url_constants.h"',
           '#include "content/public/browser/arx_live_connection.h"\n'
           '#include "content/public/browser/web_contents.h"\n'
           '#include "content/public/common/url_constants.h"')
    yield (POLICY, "bool IsPageCapturingDisplay(const PageNode* page_node) {",
           HELPER + "bool IsPageCapturingDisplay(const PageNode* page_node) {")
    yield (POLICY, "  const bool is_periodic_unfreezing_active = IsPeriodicUnfreezingActive();\n",
           "  const bool is_periodic_unfreezing_active = IsPeriodicUnfreezingActive();\n" + LIVE_CONNECTION)
    yield (POLICY,
           "             !is_in_periodic_unfreeze &&\n"
           "             base::FeatureList::IsEnabled(features::kInfiniteTabsFreezing)) {",
           "             !is_in_periodic_unfreeze &&\n"
           "             base::FeatureList::IsEnabled(features::kInfiniteTabsFreezing) &&\n"
           "             !holds_live_connection()) {")
    yield (POLICY,
           "             base::FeatureList::IsEnabled(\n"
           "                 features::kInfiniteTabsFreezingOnMemoryPressure)) {",
           "             base::FeatureList::IsEnabled(\n"
           "                 features::kInfiniteTabsFreezingOnMemoryPressure) &&\n"
           "             !holds_live_connection()) {")


def apply(source):
    from .config import PACKAGE
    from .overlay import replace_once

    public_header = source / "content/public/browser/arx_live_connection.h"
    public_header.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(PACKAGE / "Native/content/arx_live_connection.h", public_header)
    implementation = source / "content/browser/renderer_host/arx_live_connection.cc"
    implementation.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(PACKAGE / "Native/content/arx_live_connection.cc", implementation)
    for relative, old, new in patches():
        replace_once(source / relative, old, new)
