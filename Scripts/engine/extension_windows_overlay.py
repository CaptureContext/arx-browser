"""Give embedder-owned tabs windows, indexes and a current window (ABI22).

`upgrade` rewrites the code `extension_tabs_overlay` inserts; that overlay
applies the result and migrates a tree prepared at ABI21 or ABI22. `patches`
are this overlay's own edits at upstream anchors.

ABI56 (DEV-973) passes the caller's incognito permission to the windows hook,
so an extension allowed in private windows sees them from its worker too, and
a window says whether it's private (`incognito`). `upgrade_abi22` is the text a
tree prepared before it holds, which `apply` and the tabs overlay migrate.

DEV-1019: tabs.executeScript and tabs.insertCSS (MV2, which uBlock Origin uses
for its element picker, site-specific hiding and scriptlets) also take an
embedder tab, which has no Chrome window. chrome.scripting never needed one.
"""
from .overlay import replace_once

UTIL_HEADER = "chrome/browser/extensions/extension_tab_util.h"
UTIL_SOURCE = "chrome/browser/extensions/extension_tab_util.cc"
# Chromium 157 moved the windows.* functions out of tabs_api.cc.
WINDOWS_SOURCE = "chrome/browser/extensions/api/tabs/windows_api.cc"
TABS_SOURCE = "chrome/browser/extensions/api/tabs/tabs_api.cc"

# The ABI21 tabs.query block this overlay replaces; kept verbatim to anchor it.
ABI21_QUERY = '''  // Embedder-owned tabs have no Chrome window, index, group, split or pin, so
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
'''

ABI22_QUERY = '''  // Embedder-owned tabs have no Chrome group, split or pin, so any filter on
  // those excludes them. ABI22: they carry the embedder's window, index and
  // active state. The embedder's current and last focused windows count only
  // when Chrome has none of its own for this call.
  const bool embedder_tabs_match_window =
      (window_type.empty() || window_type == "normal") &&
      !query_info_.pinned.value_or(false) &&
      query_info_.group_id.value_or(-1) == -1 &&
      query_info_.split_view_id.value_or(-1) == -1 &&
      !query_info_.frozen.value_or(false) &&
      !query_info_.discarded.value_or(false) &&
      !query_info_.auto_discardable.value_or(false);
  if (embedder_tabs_match_window) {
    const ExtensionTabUtil::EmbedderWindows embedder_windows =
        ExtensionTabUtil::GetEmbedderWindows(browser_context(),
                                             GetSenderWebContents());
    const int embedder_current = current_browser
                                     ? extension_misc::kUnknownWindowId
                                     : embedder_windows.current;
    const int embedder_last_focused = last_active_browser
                                          ? extension_misc::kUnknownWindowId
                                          : embedder_windows.last_focused;
    for (const auto& tab : ExtensionTabUtil::GetEmbedderTabs(
             browser_context(), include_incognito_information())) {
      content::WebContents* web_contents = tab.contents.get();
      const bool placed = tab.window_id >= 0;
      const bool in_current = placed && tab.window_id == embedder_current;
      const bool in_last_focused =
          placed && tab.window_id == embedder_last_focused;
      if (!web_contents ||
          (window_id >= 0 && tab.window_id != window_id) ||
          (window_id == extension_misc::kCurrentWindowId && !in_current) ||
          (tab_index > -1 && tab.index != tab_index) ||
          (!window_type.empty() && !placed) ||
          !MatchesBool(query_info_.current_window, in_current) ||
          !MatchesBool(query_info_.last_focused_window, in_last_focused) ||
          !MatchesBool(query_info_.active, tab.active) ||
          !MatchesBool(query_info_.highlighted, tab.highlighted) ||
'''

WINDOWS_HELPER = '''namespace {

// ABI22 embedder windows: normal windows outside Chrome's window list that hold
// the caller's own embedder tabs. Their IDs are SessionIDs, like Chrome's, so
// they never collide with a Chrome window.
enum class EmbedderWindowSelection { kAll, kId, kCurrent, kLastFocused };

base::ListValue EmbedderWindowValues(ExtensionFunction& function,
                                     EmbedderWindowSelection selection,
                                     int window_id,
                                     bool populate,
                                     WindowController::TypeFilter filter) {
  base::ListValue values;
  const WindowController::TypeFilter normal =
      1u << static_cast<uint32_t>(windows::WindowType::kNormal);
  if (filter && !(filter & normal)) {
    return values;
  }
  const ExtensionTabUtil::EmbedderWindows embedder =
      ExtensionTabUtil::GetEmbedderWindows(function.browser_context(),
                                           function.GetSenderWebContents());
  for (const auto& window : embedder.windows) {
    if ((selection == EmbedderWindowSelection::kId && window.id != window_id) ||
        (selection == EmbedderWindowSelection::kCurrent &&
         window.id != embedder.current) ||
        (selection == EmbedderWindowSelection::kLastFocused &&
         window.id != embedder.last_focused)) {
      continue;
    }
    values.Append(ExtensionTabUtil::CreateEmbedderWindowValue(
        window, function.browser_context(),
        function.include_incognito_information(), function.extension(),
        populate ? WindowController::kPopulateTabs
                 : WindowController::kDontPopulateTabs,
        function.source_context_type()));
  }
  return values;
}

}  // namespace

ExtensionFunction::ResponseAction WindowsGetFunction::Run() {
'''


# Fragments of the ABI21 insertions and what ABI22 makes of them.
EMBEDDER_TAB = "    bool focused_window = false;\n  };\n"
EMBEDDER_WINDOWS = '''    bool focused_window = false;
    // ABI22: the embedder window the tab is in and its position there, or
    // extension_misc::kUnknownWindowId and -1 outside every window.
    int window_id = -1;
    int index = -1;
    bool highlighted = false;
  };
  // ABI22: an embedder window holding embedder tabs. Its ID is a SessionID.
  struct EmbedderWindow {
    int id = -1;
    bool focused = false;
    bool minimized = false;
    bool fullscreen = false;
    int left = 0;
    int top = 0;
    int width = 0;
    int height = 0;
  };
  // The embedder windows an extension running in a browser context may reach.
  // `current` is the window of the calling page, or of the page an extension
  // popup was opened for; otherwise the last focused one. Either may be
  // extension_misc::kUnknownWindowId.
  struct EmbedderWindows {
    std::vector<EmbedderWindow> windows;
    int current = -1;
    int last_focused = -1;
  };
  using EmbedderWindowList = base::RepeatingCallback<EmbedderWindows(
      content::BrowserContext* browser_context, content::WebContents* sender)>;
  static void SetEmbedderWindows(EmbedderWindowList windows);
  static EmbedderWindows GetEmbedderWindows(
      content::BrowserContext* browser_context,
      content::WebContents* sender);
  // The embedder placement of `contents`, if it is an embedder tab.
  static std::optional<EmbedderTab> GetEmbedderTab(
      const content::WebContents* contents);
  static base::DictValue CreateEmbedderWindowValue(
      const EmbedderWindow& window,
      content::BrowserContext* browser_context,
      bool include_incognito,
      const Extension* extension,
      WindowController::PopulateTabBehavior populate_tab_behavior,
      mojom::ContextType context);
'''

GET_TABS = "  return tabs.Run(browser_context, include_incognito);\n}\n"
GET_WINDOWS = '''  return tabs.Run(browser_context, include_incognito);
}

static ExtensionTabUtil::EmbedderWindowList& EmbeddedWindows() {
  static base::NoDestructor<ExtensionTabUtil::EmbedderWindowList> windows;
  return *windows;
}

// static
void ExtensionTabUtil::SetEmbedderWindows(EmbedderWindowList windows) {
  EmbeddedWindows() = std::move(windows);
}

// static
ExtensionTabUtil::EmbedderWindows ExtensionTabUtil::GetEmbedderWindows(
    content::BrowserContext* browser_context,
    content::WebContents* sender) {
  if (!browser_context || !EmbeddedWindows()) {
    return {};
  }
  auto windows = EmbeddedWindows();
  return windows.Run(browser_context, sender);
}

// static
std::optional<ExtensionTabUtil::EmbedderTab> ExtensionTabUtil::GetEmbedderTab(
    const content::WebContents* contents) {
  if (!contents) {
    return std::nullopt;
  }
  for (const auto& tab :
       GetEmbedderTabs(
           const_cast<content::WebContents*>(contents)->GetBrowserContext(),
           false)) {
    if (tab.contents.get() == contents) {
      return tab;
    }
  }
  return std::nullopt;
}

// static
base::DictValue ExtensionTabUtil::CreateEmbedderWindowValue(
    const EmbedderWindow& window,
    content::BrowserContext* browser_context,
    bool include_incognito,
    const Extension* extension,
    WindowController::PopulateTabBehavior populate_tab_behavior,
    mojom::ContextType context) {
  base::DictValue dict;
  dict.Set(extension_misc::kId, window.id);
  dict.Set("type", "normal");
  dict.Set("focused", window.focused);
  dict.Set("incognito", false);
  dict.Set("alwaysOnTop", false);
  dict.Set("state", window.minimized    ? "minimized"
                    : window.fullscreen ? "fullscreen"
                                        : "normal");
  dict.Set("left", window.left);
  dict.Set("top", window.top);
  dict.Set("width", window.width);
  dict.Set("height", window.height);
  if (populate_tab_behavior == WindowController::kPopulateTabs) {
    base::ListValue tabs;
    for (const auto& tab : GetEmbedderTabs(browser_context, include_incognito)) {
      if (!tab.contents || tab.window_id != window.id) {
        continue;
      }
      tabs.Append(CreateTabObject(tab.contents.get(),
                                  GetScrubTabBehavior(extension, context,
                                                      tab.contents.get()),
                                  extension, nullptr, tab.index)
                      .ToValue());
    }
    dict.Set(kTabsKey, std::move(tabs));
  }
  return dict;
}
'''

UPGRADES = [(EMBEDDER_TAB, EMBEDDER_WINDOWS), (GET_TABS, GET_WINDOWS), (ABI21_QUERY, ABI22_QUERY)]

# ABI56 (DEV-973): the incognito permission through the windows hook, and a
# window's own incognito flag. Each fragment occurs once in the ABI22 text.
ABI56_UPGRADES = [
    ("    bool minimized = false;\n    bool fullscreen = false;\n",
     "    bool minimized = false;\n    bool fullscreen = false;\n"
     "    // ABI56 (DEV-973): a private window, listed only for callers allowed there.\n"
     "    bool incognito = false;\n"),
    ("      content::BrowserContext* browser_context, content::WebContents* sender)>;\n",
     "      content::BrowserContext* browser_context, content::WebContents* sender,\n"
     "      bool include_incognito)>;\n"),
    ("  static EmbedderWindows GetEmbedderWindows(\n"
     "      content::BrowserContext* browser_context,\n"
     "      content::WebContents* sender);\n",
     "  static EmbedderWindows GetEmbedderWindows(\n"
     "      content::BrowserContext* browser_context,\n"
     "      content::WebContents* sender,\n"
     "      bool include_incognito);\n"),
    ("ExtensionTabUtil::EmbedderWindows ExtensionTabUtil::GetEmbedderWindows(\n"
     "    content::BrowserContext* browser_context,\n"
     "    content::WebContents* sender) {\n",
     "ExtensionTabUtil::EmbedderWindows ExtensionTabUtil::GetEmbedderWindows(\n"
     "    content::BrowserContext* browser_context,\n"
     "    content::WebContents* sender,\n"
     "    bool include_incognito) {\n"),
    ("  return windows.Run(browser_context, sender);\n",
     "  return windows.Run(browser_context, sender, include_incognito);\n"),
    ('  dict.Set("incognito", false);\n', '  dict.Set("incognito", window.incognito);\n'),
    ("        ExtensionTabUtil::GetEmbedderWindows(browser_context(),\n"
     "                                             GetSenderWebContents());\n",
     "        ExtensionTabUtil::GetEmbedderWindows(browser_context(),\n"
     "                                             GetSenderWebContents(),\n"
     "                                             include_incognito_information());\n"),
    ("      ExtensionTabUtil::GetEmbedderWindows(function.browser_context(),\n"
     "                                           function.GetSenderWebContents());\n",
     "      ExtensionTabUtil::GetEmbedderWindows(\n"
     "          function.browser_context(), function.GetSenderWebContents(),\n"
     "          function.include_incognito_information());\n"),
]


def upgrade_abi22(text):
    """The ABI22 form of an ABI21 insertion; other text is returned unchanged."""
    for before, after in UPGRADES:
        if before in text and after not in text:
            text = text.replace(before, after, 1)
    return text


def upgrade(text):
    """The current (ABI56) form of an ABI21 or ABI22 insertion; other text is returned unchanged."""
    text = upgrade_abi22(text)
    for before, after in ABI56_UPGRADES:
        if before in text and after not in text:
            text = text.replace(before, after, 1)
    return text


def patches():
    yield UTIL_HEADER, "#include <memory>\n#include <string>\n", "#include <memory>\n#include <optional>\n#include <string>\n"
    yield UTIL_SOURCE, '''int ExtensionTabUtil::GetWindowIdOfTab(const WebContents* web_contents) {
  return sessions::SessionTabHelper::IdForWindowContainingTab(web_contents)
      .id();
}''', '''int ExtensionTabUtil::GetWindowIdOfTab(const WebContents* web_contents) {
  const SessionID window =
      sessions::SessionTabHelper::IdForWindowContainingTab(web_contents);
  if (!window.is_valid()) {
    // ABI22: an embedder tab's window.
    if (auto embedder = GetEmbedderTab(web_contents)) {
      return embedder->window_id;
    }
  }
  return window.id();
}'''
    yield UTIL_SOURCE, "  tab_object.pinned = tab_interface && tab_interface->IsPinned();\n", '''  tab_object.pinned = tab_interface && tab_interface->IsPinned();
  if (!tab_interface) {
    // ABI22: an embedder tab's place in its embedder window.
    if (auto embedder = GetEmbedderTab(contents)) {
      tab_object.index = embedder->index;
      tab_object.active = embedder->active;
      tab_object.selected = embedder->active;
      tab_object.highlighted = embedder->highlighted;
    }
  }
'''
    yield WINDOWS_SOURCE, "ExtensionFunction::ResponseAction WindowsGetFunction::Run() {\n", upgrade(WINDOWS_HELPER)
    # windows.get: Chrome's windows first, then an embedder window by ID.
    yield WINDOWS_SOURCE, '''  if (!windows_util::GetControllerFromWindowID(this, params->window_id,
                                               extractor.type_filters(),
                                               &window_controller, &error)) {
    return RespondNow(Error(std::move(error)));
  }
''', '''  if (!windows_util::GetControllerFromWindowID(this, params->window_id,
                                               extractor.type_filters(),
                                               &window_controller, &error)) {
    base::ListValue embedder = EmbedderWindowValues(
        *this,
        params->window_id == extension_misc::kCurrentWindowId
            ? EmbedderWindowSelection::kCurrent
            : EmbedderWindowSelection::kId,
        params->window_id, extractor.populate_tabs(), extractor.type_filters());
    if (!embedder.empty()) {
      return RespondNow(WithArguments(std::move(embedder.front())));
    }
    return RespondNow(Error(std::move(error)));
  }
'''
    yield WINDOWS_SOURCE, '''          this, extension_misc::kCurrentWindowId, extractor.type_filters(),
          &window_controller, &error)) {
    return RespondNow(Error(std::move(error)));
  }
''', '''          this, extension_misc::kCurrentWindowId, extractor.type_filters(),
          &window_controller, &error)) {
    base::ListValue embedder = EmbedderWindowValues(
        *this, EmbedderWindowSelection::kCurrent,
        extension_misc::kCurrentWindowId, extractor.populate_tabs(),
        extractor.type_filters());
    if (!embedder.empty()) {
      return RespondNow(WithArguments(std::move(embedder.front())));
    }
    return RespondNow(Error(std::move(error)));
  }
'''
    yield WINDOWS_SOURCE, '''  if (!last_focused_browser) {
    return RespondNow(Error(tabs_constants::kNoLastFocusedWindowError));
  }
''', '''  if (!last_focused_browser) {
    base::ListValue embedder = EmbedderWindowValues(
        *this, EmbedderWindowSelection::kLastFocused,
        extension_misc::kUnknownWindowId, extractor.populate_tabs(),
        extractor.type_filters());
    if (!embedder.empty()) {
      return RespondNow(WithArguments(std::move(embedder.front())));
    }
    return RespondNow(Error(tabs_constants::kNoLastFocusedWindowError));
  }
'''
    yield WINDOWS_SOURCE, '''        populate_tab_behavior, source_context_type()));
  }

  return RespondNow(WithArguments(std::move(window_list)));
''', '''        populate_tab_behavior, source_context_type()));
  }
  for (auto& window : EmbedderWindowValues(
           *this, EmbedderWindowSelection::kAll,
           extension_misc::kUnknownWindowId, extractor.populate_tabs(),
           extractor.type_filters())) {
    window_list.Append(std::move(window));
  }

  return RespondNow(WithArguments(std::move(window_list)));
'''


    # DEV-1019: an MV2 extension's tabs.executeScript and tabs.insertCSS (uBlock Origin's
    # element picker, site-specific hiding and scriptlets) take a tab only with a Chrome
    # window. An embedder tab has none, so take it as GetTabById found it.
    yield TABS_SOURCE, '''                                       &contents, nullptr, error) &&
                 contents && window;
''', '''                                       &contents, nullptr, error) &&
                 contents &&
                 (window || ExtensionTabUtil::GetEmbedderTab(contents));
'''


def apply(source):
    # A tree prepared at ABI22 holds the helper without the incognito permission.
    path = source / WINDOWS_SOURCE
    if path.exists():
        text = path.read_text()
        current = upgrade(WINDOWS_HELPER)
        if current not in text and text.count(WINDOWS_HELPER) == 1:
            path.write_text(text.replace(WINDOWS_HELPER, current, 1))
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
