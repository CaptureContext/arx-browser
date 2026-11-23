"""webRequest routing for several private windows of one profile (DEV-889).

Arx makes each private window's context a unique off-the-record child of the
profile that opened it, so a profile can have several at once. Chromium's
webRequest router pairs each regular profile with one off-the-record context
(`CrossContextData`), which is how a spanning extension allowed in private
windows hears the private pages' requests in its regular background. Pairing
a second child replaced the first's reverse entry only on the regular side,
but destroying any child cleared the regular profile's pairing, and with it
the surviving child's: its requests stopped reaching the extension.

This overlay keeps every child's entry (child to regular profile), points the
regular profile at a child that's still alive, and has a destroyed child
remove only its own entry. Destroying the regular profile removes all of them.

If an anchor changes, the build stops.
"""
from .overlay import replace_once

SOURCE = "extensions/browser/api/web_request/extension_web_request_event_router.cc"

REMOVE = """  void RemoveContext(content::BrowserContext* browser_context) {
    // This context can be either the original one, or the OTR one. Either
    // way, we need to remove both entries.
    auto it = cross_context_data_.find(browser_context);
    if (it != cross_context_data_.end()) {
      cross_context_data_.erase(it->second);
      cross_context_data_.erase(it);
    }
  }
"""

ARX_REMOVE = """  // Arx (DEV-889): a profile may have several off-the-record children at
  // once, one per private window. Each child maps to the profile, and the
  // profile to one child that's still alive; removing a child leaves its
  // siblings' entries alone, and removing the profile removes them all.
  void RemoveContext(content::BrowserContext* browser_context) {
    auto it = cross_context_data_.find(browser_context);
    if (it == cross_context_data_.end()) {
      return;
    }
    if (!browser_context->IsOffTheRecord()) {
      for (auto entry = cross_context_data_.begin();
           entry != cross_context_data_.end();) {
        if (entry->first == browser_context ||
            entry->second == browser_context) {
          entry = cross_context_data_.erase(entry);
        } else {
          ++entry;
        }
      }
      return;
    }
    content::BrowserContext* original = it->second;
    cross_context_data_.erase(it);
    auto paired = cross_context_data_.find(original);
    if (paired == cross_context_data_.end() ||
        paired->second != browser_context) {
      return;
    }
    content::BrowserContext* sibling = nullptr;
    for (const auto& [context, partner] : cross_context_data_) {
      if (context->IsOffTheRecord() && partner == original) {
        sibling = context;
      }
    }
    if (sibling) {
      paired->second = sibling;
    } else {
      cross_context_data_.erase(paired);
    }
  }
"""

DESTROYED = """    content::BrowserContext* otr_browser_context) {
  ClearCrossContextData(original_browser_context);
"""

ARX_DESTROYED = """    content::BrowserContext* otr_browser_context) {
  // Arx (DEV-889): only this child's pairing; its siblings keep theirs.
  ClearCrossContextData(otr_browser_context);
"""


def patches():
    yield SOURCE, REMOVE, ARX_REMOVE
    yield SOURCE, DESTROYED, ARX_DESTROYED


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
