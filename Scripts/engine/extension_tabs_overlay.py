"""Let the tabs API see embedder-owned pages; stock Chrome keeps its window list.

ABI21 inserted the embedder hook; ABI22 (`extension_windows_overlay.upgrade`)
gives those tabs windows and indexes, and ABI56 (DEV-973) the incognito
permission. A tree prepared at ABI21 or ABI22 is migrated in place, so
preparation stays repeatable.
"""
from .extension_windows_overlay import upgrade, upgrade_abi22
from .overlay import replace_once

UTIL_HEADER = "chrome/browser/extensions/extension_tab_util.h"
UTIL_SOURCE = "chrome/browser/extensions/extension_tab_util.cc"
TABS_SOURCE = "chrome/browser/extensions/api/tabs/tabs_api.cc"


def abi21_patches():
    yield UTIL_HEADER, '#include "base/functional/callback.h"\n', '#include "base/functional/callback.h"\n#include "base/memory/raw_ptr.h"\n'
    yield UTIL_HEADER, "  // Any out parameter (`window`, `contents`, & `tab_index`) may be null.\n", '''  // Embedder-owned tab contents outside Chrome's window list. An installed
  // embedder returns only the contents an extension running in
  // `browser_context` may reach; Chrome's own windows are searched first.
  // These tabs have no Chrome window, index, group, split or pin.
  struct EmbedderTab {
    raw_ptr<content::WebContents> contents;
    bool active = false;
    bool focused_window = false;
  };
  using EmbedderTabs = base::RepeatingCallback<std::vector<EmbedderTab>(
      content::BrowserContext* browser_context, bool include_incognito)>;
  static void SetEmbedderTabs(EmbedderTabs tabs);
  static std::vector<EmbedderTab> GetEmbedderTabs(
      content::BrowserContext* browser_context, bool include_incognito);

  // Any out parameter (`window`, `contents`, & `tab_index`) may be null.
'''
    yield UTIL_SOURCE, '#include "base/hash/hash.h"\n', '#include "base/hash/hash.h"\n#include "base/no_destructor.h"\n'
    yield UTIL_SOURCE, '''bool ExtensionTabUtil::GetTabById(int tab_id,
                                  content::BrowserContext* browser_context,
                                  bool include_incognito,
                                  WindowController** out_window,
''', '''static ExtensionTabUtil::EmbedderTabs& EmbeddedTabs() {
  static base::NoDestructor<ExtensionTabUtil::EmbedderTabs> tabs;
  return *tabs;
}

// static
void ExtensionTabUtil::SetEmbedderTabs(EmbedderTabs tabs) {
  EmbeddedTabs() = std::move(tabs);
}

// static
std::vector<ExtensionTabUtil::EmbedderTab> ExtensionTabUtil::GetEmbedderTabs(
    content::BrowserContext* browser_context,
    bool include_incognito) {
  if (!browser_context || !EmbeddedTabs()) {
    return {};
  }
  // Copy before running: the embedder may clear the hook during shutdown.
  auto tabs = EmbeddedTabs();
  return tabs.Run(browser_context, include_incognito);
}

bool ExtensionTabUtil::GetTabById(int tab_id,
                                  content::BrowserContext* browser_context,
                                  bool include_incognito,
                                  WindowController** out_window,
'''
    yield UTIL_SOURCE, "  // Prerendering tab is not visible and it cannot be in `TabStripModel`, if the\n", '''  // Embedder-owned tabs are scoped to `browser_context` by the embedder and
  // have no window or index.
  for (const auto& tab : GetEmbedderTabs(browser_context, include_incognito)) {
    if (tab.contents &&
        sessions::SessionTabHelper::IdForTab(tab.contents.get()).id() ==
            tab_id) {
      if (out_contents) {
        *out_contents = tab.contents.get();
      }
      return true;
    }
  }

  // Prerendering tab is not visible and it cannot be in `TabStripModel`, if the
'''
    yield TABS_SOURCE, "  return result;\n}\n\nbool TabsQueryFunction::MatchesWindow(", '''  // Embedder-owned tabs have no Chrome window, index, group, split or pin, so
  // any filter on those excludes them. Their window is the focused one when
  // it is the key window; a visible tab counts as active and highlighted.
  const bool embedder_tabs_match_window =
      (window_id == extension_misc::kUnknownWindowId ||
       window_id == extension_misc::kCurrentWindowId) &&
      tab_index < 0 && (window_type.empty() || window_type == "normal") &&
      !query_info_.pinned.value_or(false) &&
      query_info_.group_id.value_or(-1) == -1 &&
      query_info_.split_view_id.value_or(-1) == -1 &&
      !query_info_.frozen.value_or(false) &&
      !query_info_.discarded.value_or(false) &&
      !query_info_.auto_discardable.value_or(false);
  if (embedder_tabs_match_window) {
    for (const auto& tab : ExtensionTabUtil::GetEmbedderTabs(
             browser_context(), include_incognito_information())) {
      content::WebContents* web_contents = tab.contents.get();
      if (!web_contents ||
          (window_id == extension_misc::kCurrentWindowId &&
           !tab.focused_window) ||
          !MatchesBool(query_info_.current_window, tab.focused_window) ||
          !MatchesBool(query_info_.last_focused_window, tab.focused_window) ||
          !MatchesBool(query_info_.active, tab.active) ||
          !MatchesBool(query_info_.highlighted, tab.active) ||
          !MatchesBool(query_info_.audible,
                       web_contents->IsCurrentlyAudible()) ||
          !MatchesBool(query_info_.muted, web_contents->IsAudioMuted())) {
        continue;
      }
      ExtensionTabUtil::ScrubTabBehavior scrub_tab_behavior =
          ExtensionTabUtil::GetScrubTabBehavior(
              extension(), source_context_type(), web_contents);
      if (query_info_.title && !query_info_.title->empty() &&
          (scrub_tab_behavior.committed_info ==
               ExtensionTabUtil::kScrubTabFully ||
           !base::MatchPattern(web_contents->GetTitle(),
                               base::UTF8ToUTF16(*query_info_.title)))) {
        continue;
      }
      if (!url_patterns.is_empty()) {
        content::NavigationEntry* pending_entry =
            web_contents->GetController().GetPendingEntry();
        const bool matches_committed =
            scrub_tab_behavior.committed_info !=
                ExtensionTabUtil::kScrubTabFully &&
            url_patterns.MatchesURL(web_contents->GetLastCommittedURL());
        const bool matches_pending =
            pending_entry &&
            scrub_tab_behavior.pending_info !=
                ExtensionTabUtil::kScrubTabFully &&
            url_patterns.MatchesURL(pending_entry->GetVirtualURL());
        if (!matches_committed && !matches_pending) {
          continue;
        }
      }
      if (query_info_.status != tabs::TabStatus::kNone &&
          query_info_.status !=
              ExtensionTabUtil::GetLoadingStatus(web_contents)) {
        continue;
      }
      result.Append(CreateTabObjectHelper(web_contents, extension(),
                                          source_context_type(), nullptr, -1)
                        .ToValue());
    }
  }
  return result;
}

bool TabsQueryFunction::MatchesWindow('''


def patches():
    for relative, before, after in abi21_patches():
        yield relative, before, upgrade(after)


def apply(source):
    for (relative, before, previous), (_, _, after) in zip(abi21_patches(), patches()):
        path = source / relative
        text = path.read_text()
        # A tree prepared at ABI21 or ABI22 holds an older form of this insertion.
        for older in (previous, upgrade_abi22(previous)):
            if older != after and after not in text and text.count(older) == 1:
                path.write_text(text.replace(older, after, 1))
                break
        replace_once(path, before, after)
