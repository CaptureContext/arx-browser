#include "chrome/browser/arx/extensions_bridge.h"

#import <AppKit/AppKit.h>

#include "chrome/browser/arx/extensions_install_bridge.h"
#include "chrome/browser/arx/webstore_install_bridge.h"
#include "chrome/browser/arx/content_blocking_bridge.h"
#include "chrome/browser/arx/engine_bridge.h"
#include "chrome/browser/extensions/api/runtime/chrome_runtime_api_delegate.h"
#include "chrome/browser/extensions/api/management/chrome_management_api_delegate.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "base/functional/callback_helpers.h"
#include "base/strings/sys_string_conversions.h"
#include "ui/gfx/native_ui_types.h"
#include "extensions/common/manifest_handlers/background_info.h"
#include "extensions/common/manifest_handlers/incognito_info.h"
#include "extensions/common/manifest_handlers/options_page_info.h"
#include "extensions/common/manifest_handlers/icons_handler.h"
#include "extensions/common/api/extension_action/action_info.h"
#include "base/strings/string_number_conversions.h"
#include "base/base64.h"
#include "base/memory/ref_counted_memory.h"
#include "extensions/browser/component_extension_resource_manager.h"
#include "ui/base/resource/resource_bundle.h"
#include "extensions/common/constants.h"
#include "extensions/common/manifest_constants.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "extensions/browser/extension_file_task_runner.h"
#include "extensions/browser/extension_management_client.h"
#include "extensions/browser/extensions_browser_client.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>

#include "base/check.h"
#include "base/base_paths.h"
#include "base/path_service.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/one_shot_event.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/scoped_observation.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/browser/extensions/chrome_extension_web_contents_observer.h"
#include "chrome/browser/extensions/extension_util.h"
#include "chrome/browser/extensions/tab_helper.h"
#include "chrome/browser/profiles/profile.h"
#include "components/crx_file/crx_creator.h"
#include "components/crx_file/id_util.h"
#include "crypto/keypair.h"
#include "third_party/zlib/google/zip.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_prefs_observer.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/extension_util.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/management_policy.h"
#include "extensions/browser/process_manager.h"
#include "extensions/browser/unpacked_installer.h"
#include "extensions/browser/view_type_utils.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest.h"
#include "extensions/common/manifest_handlers/permissions_parser.h"
#include "extensions/common/permissions/permission_set.h"
#include "extensions/common/permissions/permissions_data.h"

namespace arx {
namespace {
constexpr size_t kMaximumInventoryBytes = 1024 * 1024;
constexpr size_t kMaximumExtensions = 512;
constexpr size_t kMaximumPermissionStrings = 512;
constexpr size_t kMaximumStringBytes = 4096;
constexpr size_t kMaximumRequests = 32;
constexpr size_t kMaximumUnpackedPathBytes = 4096;
constexpr size_t kMaximumLoadErrorBytes = 2048;

// File-sequence classification before Chromium reads the folder. Distinct
// statuses let the app name the user's next step; Chromium still owns loading.
struct UnpackedDirectory {
  ArxExtensionStatus status = ARX_EXTENSION_FAILED;
  base::FilePath path;
  std::string detail;
};

UnpackedDirectory InspectUnpackedDirectory(const base::FilePath& requested) {
  const auto path = base::MakeAbsoluteFilePath(requested);
  if (path.empty() || !base::DirectoryExists(path)) return {ARX_EXTENSION_DIRECTORY_MISSING, {}, {}};
  if (access(path.value().c_str(), R_OK | X_OK) != 0) return {ARX_EXTENSION_DIRECTORY_UNREADABLE, {}, {}};
  const auto manifest = path.Append(extensions::kManifestFilename);
  if (!base::PathExists(manifest) || base::DirectoryExists(manifest)) {
    return {ARX_EXTENSION_MANIFEST_INVALID, {}, extensions::manifest_errors::kManifestUnreadable};
  }
  if (access(manifest.value().c_str(), R_OK) != 0) return {ARX_EXTENSION_DIRECTORY_UNREADABLE, {}, {}};
  return {ARX_EXTENSION_SUCCESS, path, {}};
}

// Chromium's load error is user-actionable text (for example a JSON position
// or a missing script). Keep it bounded, valid UTF-8 and free of controls.
std::string LoadErrorDetail(const std::u16string& error) {
  std::string detail;
  base::TruncateUTF8ToByteSize(base::UTF16ToUTF8(error), kMaximumLoadErrorBytes, &detail);
  for (auto& byte : detail) if (static_cast<unsigned char>(byte) < 32 || byte == 127) byte = ' ';
  return detail;
}

// This loader intentionally accepts no caller-supplied path or manifest. Its
// only source is these files inside the fresh directory owned by fixture Run.
constexpr char kFixtureManifest[] = R"({
  "manifest_version": 3, "name": "Arx Disposable Extension Fixture",
  "author": "CaptureContext fixtures", "version": "1.0", "permissions": ["storage", "declarativeNetRequest", "contextMenus"],
  "host_permissions": ["http://127.0.0.1/*"],
  "background": {"service_worker": "worker.js"},
  "options_ui": {"page": "options.html", "open_in_tab": true},
  "action": {"default_popup": "popup.html"},
  "commands": {
    "_execute_action": {"suggested_key": {"default": "Ctrl+Shift+Y", "mac": "Command+Shift+Y"}},
    "arx-fixture-command": {"description": "Verify profile-scoped shortcut",
      "suggested_key": {"default": "Ctrl+Shift+U", "mac": "Command+Shift+U"}}
  },
  "content_scripts": [{"matches": ["http://127.0.0.1/*"],
    "js": ["content.js"], "run_at": "document_idle"}],
  "declarative_net_request": {"rule_resources": [
    {"id": "fixture", "enabled": true, "path": "rules.json"}]}
})";
constexpr char kFixtureNative[] = R"(
(async () => {
  try {
    const message = {kind: 'arx-native-fixture'};
    const origin = `chrome-extension://${chrome.runtime.id}/`;
    const one = await chrome.runtime.sendNativeMessage('dev.capturecontext.arx.fixture', message);
    if (one.kind !== message.kind || one.origin !== origin || one.framed !== true ||
        !Number.isSafeInteger(one.pid) || one.pid <= 0) throw Error('response');
    let forbidden = false;
    try { await chrome.runtime.sendNativeMessage('dev.capturecontext.arx.forbidden', message); }
    catch (error) { forbidden = /forbidden/i.test(String(error.message)); }
    if (!forbidden) throw Error('allowlist');
    const port = chrome.runtime.connectNative('dev.capturecontext.arx.fixture');
    globalThis.arxFixturePort = port;
    port.onMessage.addListener(value => {
      if (value.kind !== message.kind || value.origin !== origin || value.framed !== true ||
          !Number.isSafeInteger(value.pid) || value.pid <= 0 || value.pid === one.pid) {
        document.title = 'ARX_EXTENSION_NATIVE_FAILED'; return;
      }
      document.title = `ARX_EXTENSION_NATIVE:${chrome.runtime.id}:once=${one.pid}:port=${value.pid}:forbidden=true`;
    });
    port.onDisconnect.addListener(() => { document.title = 'ARX_EXTENSION_NATIVE_DISCONNECTED'; });
    port.postMessage(message);
  } catch { document.title = 'ARX_EXTENSION_NATIVE_FAILED'; }
})();
)";
constexpr char kFixtureWorker[] = R"(
// ABI21: Arx pages are reachable through the tabs API. Probe the exact source
// tab, then message it directly; private and other-profile pages never count.
// ABI22: an Arx page carries its window and index. Window-scoped queries and
// chrome.windows see only this profile's windows; a page outside every
// window reports 'none'.
async function windowFacts(tab, own) {
  if (own.windowId < 0) return 'none';
  const inWindow = await chrome.tabs.query({windowId: own.windowId});
  const indexed = await chrome.tabs.query({windowId: own.windowId, index: own.index});
  const current = await chrome.tabs.query({active: true, currentWindow: true});
  const focused = await chrome.tabs.query({lastFocusedWindow: true});
  const all = await chrome.windows.getAll({populate: true});
  const got = await chrome.windows.get(own.windowId, {populate: true});
  const currentWindow = await chrome.windows.getCurrent();
  const lastFocused = await chrome.windows.getLastFocused();
  return [`index=${own.index}`, `active=${own.active}`,
    `window=${inWindow.length}/${inWindow.findIndex(item => item.id === tab.id)}`,
    `indexed=${indexed.length === 1 && indexed[0].id === tab.id}`,
    `current=${current.map(item => item.index).join(',')}`,
    `focused=${focused.length === inWindow.length}`,
    `windows=${all.length}/${all.map(window => window.tabs.length).join(',')}`,
    `fetched=${got.id === own.windowId && got.tabs.some(item => item.id === tab.id)}`,
    `own=${currentWindow.id === own.windowId && lastFocused.id === own.windowId}`,
    `incognito=${all.some(window => window.incognito)}`].join(':');
}
async function reachTab(source, tab, invocations) {
  const own = await chrome.tabs.get(tab.id);
  const windows = await windowFacts(tab, own).catch(error => `failed/${error.message}`);
  const all = await chrome.tabs.query({});
  // Session IDs are process-wide and sequential; probe every ID near this one.
  const first = Math.max(1, tab.id - 256);
  const found = await Promise.all(Array.from({length: tab.id + 257 - first}, (_, index) =>
      chrome.tabs.get(first + index).then(() => 1, () => 0)));
  const reply = await chrome.tabs.sendMessage(tab.id, {kind: 'arx-fixture-tabs', source, tab: tab.id,
      invocations, tabs: all.length, reach: found.reduce((sum, value) => sum + value, 0), windows,
      get: own.id === tab.id && own.url === tab.url && !own.incognito &&
          all.some(item => item.id === tab.id) && all.every(item => !item.incognito)});
  if (!reply || reply.tab !== tab.id) throw Error('reply');
}
// DEV-956: a link item. Allowed in private windows, it shows on a private
// page's links and reaches that page, which the tabs API then lists.
chrome.contextMenus.removeAll(() => chrome.contextMenus.create(
    {id: 'arx-fixture-menu', title: 'Arx fixture item', contexts: ['link']}));
chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== 'arx-fixture-menu' || !tab || tab.id < 0) return;
  const all = await chrome.tabs.query({}).catch(() => []);
  chrome.tabs.sendMessage(tab.id, {kind: 'arx-fixture-menu', tab: tab.id, incognito: tab.incognito,
      query: all.some(item => item.id === tab.id && item.incognito)}).catch(() => {});
});
chrome.commands.onCommand.addListener((command, tab) => {
  if (command !== 'arx-fixture-command' || !tab || tab.id < 0) return;
  chrome.storage.local.get({count: 0, commandCount: 0}).then(async values => {
    const commandCount = values.commandCount + 1;
    // The original relay: the command's own tab ID travels through profile storage.
    await chrome.storage.local.set({commandCount, commandTab: tab.id, commandFixtureCount: values.count});
    await reachTab('command', tab, commandCount);
  }).catch(() => {});
});
chrome.action.onClicked.addListener(tab => {
  if (!tab || tab.id < 0) return;
  // The next press opens a popup that finds this page from its current window.
  chrome.action.setPopup({tabId: tab.id, popup: 'popup.html?tabs=1'})
      .then(() => reachTab('action', tab, 0)).catch(() => {});
});
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (!sender.tab || sender.tab.id < 0) return;
  if (message === 'arx-fixture-popup-child') {
    chrome.storage.local.get({count: 0}).then(({count}) => reply({count, tab: sender.tab.id}));
    return true;
  }
  if (message === 'arx-fixture-tabs-arm') {
    // Only this tab's action dispatches action.onClicked instead of the popup.
    chrome.action.setPopup({tabId: sender.tab.id, popup: ''}).then(() => reply({tab: sender.tab.id}));
    return true;
  }
  if (message !== 'arx-fixture') return;
  chrome.storage.local.get({count: 0}).then(({count}) => {
    const next = count + 1;
    chrome.storage.local.set({count: next, fixtureOrigin: new URL(sender.url).origin}).then(() => reply({count: next, tab: sender.tab.id}));
  });
  return true;
});
)";
constexpr char kFixtureContent[] = R"(
let ownTab = -1;
let relayed = null, direct = null;
// A command title needs both the storage relay and the direct tabs message.
const showCommand = () => {
  if (!relayed || !direct || direct.invocations !== relayed.commandCount) return;
  document.title = `ARX_EXTENSION_COMMAND:${chrome.runtime.id}:count=${relayed.commandFixtureCount}` +
      `:invocations=${relayed.commandCount}:direct=${direct.invocations}:get=${direct.get}` +
      `:tabs=${direct.tabs}:reach=${direct.reach}`;
};
chrome.storage.onChanged.addListener(async (changes, area) => {
  if (area !== 'local' || !changes.commandCount || ownTab < 0) return;
  // Unchanged keys are absent from changes; read the one atomic record.
  const {commandCount, commandTab, commandFixtureCount} = await chrome.storage.local.get(
      {commandCount: 0, commandTab: -1, commandFixtureCount: 0});
  if (commandTab !== ownTab || !Number.isSafeInteger(commandCount) || commandCount < 1) return;
  relayed = {commandCount, commandFixtureCount};
  showCommand();
});
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id !== chrome.runtime.id || sender.tab || !message ||
      message.kind !== 'arx-fixture-tabs' || ownTab < 0 || message.tab !== ownTab) return;
  reply({tab: ownTab});
  if (message.source === 'command') {
    direct = message;
    showCommand();
  } else if (message.source === 'action') {
    document.title = `ARX_EXTENSION_TABS:action:${chrome.runtime.id}:get=${message.get}` +
        `:tabs=${message.tabs}:reach=${message.reach}:${message.windows}`;
  } else if (message.source === 'popup') {
    document.title = `ARX_EXTENSION_TABS:popup:${chrome.runtime.id}:${message.popup}`;
  }
});
chrome.runtime.onMessage.addListener((message, sender) => {
  if (sender.id !== chrome.runtime.id || sender.tab || !message ||
      message.kind !== 'arx-fixture-menu' || ownTab < 0 || message.tab !== ownTab) return;
  document.title = `ARX_EXTENSION_MENU:${chrome.runtime.id}:incognito=${message.incognito}` +
      `:query=${message.query}`;
});
(async () => {
  try {
    const parameters = new URL(location.href).searchParams;
    if (parameters.get('popup_child') === '1') {
      const result = await chrome.runtime.sendMessage('arx-fixture-popup-child');
      document.title = `ARX_EXTENSION_POPUP_CHILD:${chrome.runtime.id}:count=${result.count}`;
      return;
    }
    if (parameters.get('tabs_action') === '1') {
      ownTab = (await chrome.runtime.sendMessage('arx-fixture-tabs-arm')).tab;
      document.title = `ARX_EXTENSION_TABS_ARMED:${chrome.runtime.id}`;
      return;
    }
    const result = await chrome.runtime.sendMessage('arx-fixture');
    ownTab = result.tab;
    let blocked = false;
    try { await fetch('/extension-blocked'); } catch { blocked = true; }
    // DEV-956: a private page gets a link for the item, at the page's top left.
    if (chrome.extension.inIncognitoContext) {
      document.body.insertAdjacentHTML('afterbegin', '<a id="arx-fixture-link" ' +
          'href="https://capturecontext.dev/arx-fixture-menu" style="position:fixed;left:0;top:0;' +
          'width:160px;height:40px;display:block;background:#ddd">Arx fixture link</a>');
    }
    document.title = `ARX_EXTENSION_READY:worker=${result.tab >= 0}:dnr=${blocked}:count=${result.count}`;
  } catch { document.title = 'ARX_EXTENSION_FAILED'; }
})();
)";
constexpr char kFixturePopup[] = R"(
if (new URLSearchParams(location.search).get('tabs') === '1') {
  // ABI22: the usual popup query finds the page this popup was opened for.
  Promise.all([chrome.tabs.query({active: true, currentWindow: true}),
               chrome.windows.getCurrent({populate: true})]).then(([tabs, window]) => {
    const tab = tabs[0];
    return chrome.tabs.sendMessage(tab.id, {kind: 'arx-fixture-tabs', source: 'popup', tab: tab.id,
        popup: `active=${tabs.length}:window=${window.id === tab.windowId}` +
            `:index=${tab.index}:highlighted=${tab.highlighted}`});
  }).then(() => { document.title = 'ARX_EXTENSION_TABS_POPUP_SENT'; },
          () => { document.title = 'ARX_EXTENSION_TABS_POPUP_FAILED'; });
} else {
  chrome.storage.local.get({count: 0, fixtureOrigin: ''}).then(v => {
    const u = new URL(v.fixtureOrigin);
    if (u.protocol !== 'http:' || u.hostname !== '127.0.0.1' || !u.port) return;
    document.getElementById('outgoing').href = u.origin + '/index.html?popup_child=1';
    document.getElementById('options').onclick = () => chrome.runtime.openOptionsPage()
        .catch(() => document.title = 'ARX_EXTENSION_OPTIONS_REQUEST_FAILED');
    const proof = 'ARX_EXTENSION_ACTION:' + chrome.runtime.id + ':count=' + v.count;
    // DEV-1316: what's typed shows in the proof and grows the page, so its
    // window follows; "!" closes the popup with window.close().
    const field = document.getElementById('field');
    field.oninput = () => {
      if (field.value.endsWith('!')) { window.close(); return; }
      document.documentElement.style.width = document.body.style.width = '340px';
      document.documentElement.style.height = document.body.style.height = '200px';
      document.title = proof + ':input=' + field.value.slice(0, 16);
    };
    field.focus();
    document.title = proof;
  });
}
)";
constexpr char kFixtureRules[] = R"([
  {"id": 1, "priority": 1, "action": {"type": "block"},
   "condition": {"urlFilter": "/extension-blocked", "resourceTypes": ["xmlhttprequest"]}}
])";

// Startup-only diagnostics for the same fresh-root runner independently
// validated by Swift before seeding/launch. This grants no install authority.
base::FilePath OwnedSettingsDiagnosticProfile() {
  const char* root_value = std::getenv("ARX_EXTENSION_SETTINGS_SMOKE_ROOT");
  const char* profile_value = std::getenv("ARX_ENGINE_PROFILE");
  if (!root_value || !profile_value) return {};
  const base::FilePath root(root_value), profile(profile_value);
  if (!root.IsAbsolute() || !root.BaseName().value().starts_with("app-extension-install-smoke-") ||
      profile != root.AppendASCII("profile")) return {};
  for (const auto& path : {root, profile}) {
    struct stat info;
    if (lstat(path.value().c_str(), &info) || !S_ISDIR(info.st_mode) ||
        info.st_uid != getuid() || (info.st_mode & 0777) != 0700 ||
        base::MakeAbsoluteFilePath(path) != path) return {};
  }
  constexpr char expected[] = "Arx extension Settings disposable fixture v1\n";
  const int marker = open(root.AppendASCII(".arx-extension-settings-smoke").value().c_str(),
      O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
  if (marker < 0) return {};
  struct stat info;
  char bytes[sizeof(expected)];
  const bool valid = !fstat(marker, &info) && S_ISREG(info.st_mode) &&
      info.st_uid == getuid() && (info.st_mode & 0777) == 0600 &&
      info.st_size == sizeof(expected) - 1 && read(marker, bytes, sizeof(bytes)) == sizeof(expected) - 1 &&
      std::string_view(bytes, sizeof(expected) - 1) == std::string_view(expected, sizeof(expected) - 1);
  close(marker);
  return valid ? profile : base::FilePath();
}

uint64_t NextRevision() {
  static uint64_t revision = 0;
  CHECK_LT(revision, std::numeric_limits<uint64_t>::max());
  return ++revision;
}

bool ConsumeStringBudget(size_t bytes, size_t& remaining) {
  // JSON can escape each byte into six ASCII bytes. Reserve before copying
  // strings into the aggregate; the final serialized-size check is not enough.
  if (bytes > kMaximumStringBytes || bytes * 6 + 3 > remaining) return false;
  remaining -= bytes * 6 + 3;
  return true;
}

// DEV-824 follow-up: an icon set's files by their size in pixels, each joined
// to the extension's folder and never resolved, so nothing touches the disk on
// the UI thread. A path with "..", or one too long for the budget, is left
// out; the app falls back to another size or to the extension's letter.
constexpr size_t kMaximumIconSizes = 16;

base::DictValue IconPaths(const extensions::Extension& extension,
                          const ExtensionIconSet& icons, size_t& remaining) {
  base::DictValue paths;
  size_t count = 0;
  for (const auto& [size, relative] : icons.map()) {
    if (size <= 0 || size > 4096 || relative.empty() || relative.find("..") != std::string::npos)
      continue;
    if (++count > kMaximumIconSizes) break;
    const auto path = extension.path().Append(base::FilePath::FromUTF8Unsafe(relative)).value();
    if (!base::IsStringUTF8(path) || path.size() > kMaximumUnpackedPathBytes ||
        !ConsumeStringBudget(path.size(), remaining))
      continue;
    paths.Set(base::NumberToString(size), path);
  }
  return paths;
}

// DEV-824 follow-up: a component extension, such as Helium's uBlock Origin,
// keeps its files in resources.pak, so its icon paths name nothing on disk and
// the app would draw its letter. Its manifest icon nearest 64 pixels, else
// nearest 32, goes into the inventory as base64 PNG bytes instead, read from
// the resource bundle already in memory.
constexpr size_t kMaximumComponentIconBytes = 16 * 1024;

std::string ComponentIcon(const extensions::Extension& extension) {
  auto* client = extensions::ExtensionsBrowserClient::Get();
  const auto* manager = client ? client->GetComponentExtensionResourceManager() : nullptr;
  if (!manager) return {};
  const auto& icons = extensions::IconsInfo::GetIcons(&extension);
  for (const auto& [pixels, match] : {std::pair{64, ExtensionIconSet::Match::kBigger},
                                      std::pair{64, ExtensionIconSet::Match::kSmaller},
                                      std::pair{32, ExtensionIconSet::Match::kSmaller}}) {
    const std::string relative = icons.Get(pixels, match);
    int resource_id = 0;
    if (relative.empty() || relative.find("..") != std::string::npos ||
        !manager->IsComponentExtensionResource(extension.path(), base::FilePath::FromUTF8Unsafe(relative),
                                               &resource_id))
      continue;
    const auto bytes = ui::ResourceBundle::GetSharedInstance().LoadDataResourceBytes(resource_id);
    if (bytes && bytes->size() > 0 && bytes->size() <= kMaximumComponentIconBytes)
      return base::Base64Encode(base::span<const uint8_t>(*bytes));
  }
  return {};
}

// Base64 is ASCII that JSON never escapes, so it reserves its own length.
bool ConsumeBase64Budget(size_t bytes, size_t& remaining) {
  if (bytes + 3 > remaining) return false;
  remaining -= bytes + 3;
  return true;
}

bool AddStrings(base::DictValue& target, const char* key,
                const std::set<std::string>& strings, size_t& remaining) {
  if (strings.size() > kMaximumPermissionStrings) return false;
  base::ListValue values;
  for (const auto& value : strings) {
    if (!ConsumeStringBudget(value.size(), remaining)) return false;
    values.Append(value);
  }
  target.Set(key, std::move(values));
  return true;
}

bool AddPermissions(base::DictValue& target, const char* key,
                    const extensions::PermissionSet& permissions, size_t& remaining) {
  base::DictValue value;
  std::set<std::string> hosts;
  for (const auto& host : permissions.effective_hosts()) {
    auto text = host.GetAsString();
    if (text.size() > kMaximumStringBytes || hosts.size() >= kMaximumPermissionStrings) return false;
    hosts.insert(std::move(text));
  }
  if (!AddStrings(value, "apis", permissions.GetAPIsAsStrings(), remaining) ||
      !AddStrings(value, "hosts", hosts, remaining)) return false;
  target.Set(key, std::move(value));
  return true;
}

// DEV-884: Helium's uBlock Origin component, Arx's content blocking. Its
// options page (uBlock's dashboard) opens like an MV3 extension's.
bool IsContentBlocker(const extensions::Extension& extension) {
  return extension.id() == kContentBlockerID &&
      extensions::Manifest::IsComponentLocation(extension.location());
}

// DEV-889. Whether the person may allow the extension in private windows.
// Arx's private windows are unique off-the-record children of their opener,
// and Chromium wakes a split-mode extension's event page or service worker
// only in a profile's primary off-the-record context (EventDispatchHelper,
// task_queue_util), so such an extension would miss private windows' events.
// It doesn't get the switch. Spanning extensions, the default, run in the
// opener and see its private pages; a persistent split page starts with each
// private context (PreparePrivateExtensions).
bool CanRunInPrivateWindows(const extensions::Extension& extension) {
  return extensions::util::CanBeIncognitoEnabled(&extension) &&
      !(extensions::IncognitoInfo::IsSplitMode(&extension) &&
        extensions::BackgroundInfo::HasLazyContext(&extension));
}

// Registry observers catch transitions even if values later return to their
// old state. Rebuilding the bounded snapshot also catches policy changes.
class Inventory final : public extensions::ExtensionRegistryObserver,
                        public extensions::ExtensionPrefsObserver {
 public:
  explicit Inventory(Profile* profile, bool owned_fixture = false)
      : profile_(profile), revision_(NextRevision()), owned_fixture_(owned_fixture) {
    registry_observation_.Observe(extensions::ExtensionRegistry::Get(profile));
    prefs_observation_.Observe(extensions::ExtensionPrefs::Get(profile));
  }

  uint64_t revision() const { return revision_; }
  Profile* profile() const { return profile_; }

  std::optional<std::string> Read(const base::FilePath& fixture_path) {
    last_fixture_path_ = fixture_path;
    auto* registry = extensions::ExtensionRegistry::Get(profile_);
    auto* prefs = extensions::ExtensionPrefs::Get(profile_);
    auto* policy = extensions::ExtensionSystem::Get(profile_)->management_policy();
    const auto installed = registry->GenerateInstalledExtensionsSet();
    if (installed.size() > kMaximumExtensions) return std::nullopt;
    base::ListValue entries;
    size_t remaining = kMaximumInventoryBytes - 64;
    for (const auto& extension : installed) {
      const auto reasons = prefs->GetDisableReasons(extension->id());
      const auto version = extension->version().GetString();
      // Fixed JSON fields and numeric reasons have bounded overhead.
      const size_t overhead = 1024 + reasons.size() * 12;
      if (overhead > remaining) return std::nullopt;
      remaining -= overhead;
      if (!ConsumeStringBudget(extension->id().size(), remaining) ||
          !ConsumeStringBudget(extension->name().size(), remaining) ||
          !ConsumeStringBudget(version.size(), remaining)) return std::nullopt;
      const bool escalated = prefs->DidExtensionEscalatePermissions(extension->id());
      const bool enabled = registry->enabled_extensions().Contains(extension->id());
      const bool disabled = registry->disabled_extensions().Contains(extension->id());
      const bool modifiable = policy->UserMayModifySettings(extension.get(), nullptr) &&
          !extensions::Manifest::IsComponentLocation(extension->location());
      const bool solely_user_disabled = reasons == extensions::DisableReasonSet{
          extensions::disable_reason::DISABLE_USER_ACTION};
      std::string state = "terminated";
      if (enabled) state = "enabled";
      else if (registry->blocklisted_extensions().Contains(extension->id())) state = "blocklisted";
      else if (registry->blocked_extensions().Contains(extension->id())) state = "blocked";
      else if (disabled) state = "disabled";
      base::ListValue disable_reasons;
      for (auto reason : reasons) disable_reasons.Append(static_cast<int>(reason));
      base::DictValue entry;
      entry.Set("id", extension->id());
      entry.Set("name", extension->name());
      entry.Set("version", version);
      entry.Set("manifestVersion", extension->manifest_version());
      entry.Set("location", static_cast<int>(extension->location()));
      entry.Set("fromWebStore", extension->from_webstore());
      entry.Set("state", state);
      entry.Set("disableReasons", std::move(disable_reasons));
      entry.Set("permissionsIncreased", escalated);
      entry.Set("isFixture", !fixture_path.empty() && extension->path() == fixture_path);
      entry.Set("canEnable", modifiable && disabled && solely_user_disabled && !escalated &&
          extension->manifest_version() == 3 && !policy->MustRemainDisabled(extension.get(), nullptr));
      entry.Set("canDisable", modifiable && enabled && !policy->MustRemainEnabled(extension.get(), nullptr));
      entry.Set("canRemove", modifiable && !policy->MustRemainInstalled(extension.get(), nullptr));
      const bool unpacked = extension->location() == extensions::mojom::ManifestLocation::kUnpacked;
      entry.Set("canReload", modifiable && unpacked);
      // DEV-889: Chromium's per-extension incognito switch, off by default.
      entry.Set("allowedInPrivate", extensions::util::IsIncognitoEnabled(extension.get(), profile_));
      // One already allowed keeps the switch, so it can be turned off.
      entry.Set("canAllowInPrivate", modifiable &&
          (CanRunInPrivateWindows(*extension) ||
           (extensions::util::CanBeIncognitoEnabled(extension.get()) &&
            extensions::util::IsIncognitoEnabled(extension->id(), profile_))));
      // DEV-956: whether it can run in Arx's private windows at all, whatever the
      // switch says; a private window's site menu names the ones that can't.
      entry.Set("canRunInPrivate", CanRunInPrivateWindows(*extension));
      if (unpacked) {
        const auto& source = extension->path().value();
        if (!base::IsStringUTF8(source) || source.size() > kMaximumUnpackedPathBytes ||
            !ConsumeStringBudget(source.size(), remaining)) return std::nullopt;
        entry.Set("sourcePath", source);
      }
      // DEV-824: the manifest icon nearest 32px, for the site menu. The path is
      // joined, never resolved: no disk access on the UI thread. Swift reads it
      // with its own bounds and falls back to a letter tile.
      {
        const auto& icons = extensions::IconsInfo::GetIcons(extension.get());
        std::string relative = icons.Get(32, ExtensionIconSet::Match::kBigger);
        if (relative.empty()) relative = icons.Get(32, ExtensionIconSet::Match::kSmaller);
        if (!relative.empty() && relative.find("..") == std::string::npos) {
          const auto icon = extension->path().Append(base::FilePath::FromUTF8Unsafe(relative)).value();
          if (base::IsStringUTF8(icon) && icon.size() <= kMaximumUnpackedPathBytes &&
              ConsumeStringBudget(icon.size(), remaining))
            entry.Set("iconPath", icon);
        }
      }
      // DEV-824 follow-up: every manifest icon, and the action's default icons,
      // by size, so the app draws the size its display needs and prefers the
      // action's own icon. iconPath stays for apps that predate them.
      entry.Set("icons", IconPaths(*extension, extensions::IconsInfo::GetIcons(extension.get()), remaining));
      if (const auto* action = extensions::ActionInfo::GetExtensionActionInfo(extension.get()))
        entry.Set("actionIcons", IconPaths(*extension, action->default_icon, remaining));
      if (extensions::Manifest::IsComponentLocation(extension->location())) {
        std::string icon = ComponentIcon(*extension);
        if (!icon.empty() && ConsumeBase64Budget(icon.size(), remaining))
          entry.Set("componentIcon", std::move(icon));
      }
      // DEV-884: Helium's uBlock Origin component (MV2) opens its dashboard here too.
      entry.Set("canOpenOptions", enabled && !escalated &&
          extensions::OptionsPageInfo::HasOptionsPage(extension.get()) &&
          (IsContentBlocker(*extension) ||
           (extension->manifest_version() == 3 &&
            !extensions::Manifest::IsComponentLocation(extension->location()))));
      if (!AddPermissions(entry, "requiredPermissions", extensions::PermissionsParser::GetRequiredPermissions(extension.get()), remaining) ||
          !AddPermissions(entry, "optionalPermissions", extensions::PermissionsParser::GetOptionalPermissions(extension.get()), remaining) ||
          !AddPermissions(entry, "activePermissions", extension->permissions_data()->active_permissions(), remaining) ||
          !AddPermissions(entry, "withheldPermissions", extension->permissions_data()->withheld_permissions(), remaining)) return std::nullopt;
      entries.Append(std::move(entry));
    }
    base::DictValue payload;
    payload.Set("extensions", std::move(entries));
    auto json = base::WriteJson(payload);
    if (!json || json->size() > kMaximumInventoryBytes) return std::nullopt;
    if (*json != last_json_) { revision_ = NextRevision(); last_json_ = *json; }
    return json;
  }

  void OnExtensionLoaded(content::BrowserContext*, const extensions::Extension*) override { Changed(); }
  void OnExtensionReady(content::BrowserContext*, const extensions::Extension*) override { Changed(); }
  void OnExtensionUnloaded(content::BrowserContext*, const extensions::Extension*, extensions::UnloadedExtensionReason) override { Changed(); }
  void OnExtensionEnabled(content::BrowserContext*, const extensions::Extension*) override { Changed(); }
  void OnExtensionInstalled(content::BrowserContext*, const extensions::Extension*, bool) override { Changed(); }
  void OnExtensionUninstalled(content::BrowserContext*, const extensions::Extension*, extensions::UninstallReason) override { Changed(); }
  void OnExtensionDisableReasonsChanged(const extensions::ExtensionId&, extensions::DisableReasonSet) override { Changed(); }
  void OnExtensionPrefsUpdated(const extensions::ExtensionId&) override { Changed(); }
  void OnExtensionPrefUpdated(const extensions::ExtensionId&, std::string_view key) override {
    // Pinned ExtensionPrefs names: active_bit is updater ping bookkeeping;
    // running/is_active are AppRestoreService state, never permission authority.
    // Do NOT infer safety from unchanged public JSON: granted/desired permission
    // prefs and other hidden security changes must still invalidate even ABA.
    const int operational = key == "active_bit" ? 1 : key == "running" ? 2 : key == "is_active" ? 3 : 0;
    if (owned_fixture_ && diagnostic_count_ < 64) {
      ++diagnostic_count_;
      // Keys only, never preference values or profile paths. A small ASCII
      // label makes a future unknown-key rejection actionable without log
      // injection or unbounded renderer/extension-controlled output.
      char label[97] = {};
      const size_t count = std::min(key.size(), sizeof(label) - 1);
      for (size_t index = 0; index < count; ++index) {
        const char byte = key[index];
        label[index] = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
            (byte >= '0' && byte <= '9') || byte == '_' || byte == '.' || byte == '-' ? byte : '?';
      }
      std::fprintf(stderr, "ARX_EXTENSION_INVENTORY_PREF category=%d key=%s truncated=%d\n",
          operational, label, key.size() > count);
      std::fflush(stderr);
    }
    if (!operational) { Changed(); return; }
    // Retain semantic/policy drift and bounded-snapshot failure invalidation,
    // using the exact same fixture classification as the last actual read.
    if (!Read(last_fixture_path_)) Changed();
  }
  void OnExtensionRuntimePermissionsChanged(const extensions::ExtensionId&) override { Changed(); }
  void OnShutdown(extensions::ExtensionRegistry*) override { registry_observation_.Reset(); }
  void OnExtensionPrefsWillBeDestroyed(extensions::ExtensionPrefs*) override { prefs_observation_.Reset(); }

 private:
  void Changed() { revision_ = NextRevision(); }
  raw_ptr<Profile> profile_;
  uint64_t revision_;
  std::string last_json_;
  base::FilePath last_fixture_path_;
  bool owned_fixture_ = false;
  size_t diagnostic_count_ = 0;
  base::ScopedObservation<extensions::ExtensionRegistry, extensions::ExtensionRegistryObserver> registry_observation_{this};
  base::ScopedObservation<extensions::ExtensionPrefs, extensions::ExtensionPrefsObserver> prefs_observation_{this};
};

// DEV-889: chrome.management.uninstall with a confirmation (the Chrome Web
// Store's Remove button, or an extension removing another) gets Arx's own sheet
// on the requesting page's window instead of Chrome's Views dialog, which needs
// a Chrome browser window. Chrome has already checked the user gesture and that
// the person may remove this extension. Always takes the request.
bool ConfirmManagementUninstall(content::WebContents* sender, const extensions::Extension& target,
    const extensions::Extension* initiator,
    base::OnceCallback<void(bool, const std::u16string&)> done) {
  auto* profile = sender ? Profile::FromBrowserContext(sender->GetBrowserContext()) : nullptr;
  NSWindow* window = sender ? sender->GetTopLevelNativeWindow().GetNativeNSWindow() : nil;
  if (!profile || profile->IsOffTheRecord() || !window || !window.visible) {
    std::move(done).Run(false, u"");
    return true;
  }
  NSAlert* alert = [[NSAlert alloc] init];
  alert.alertStyle = NSAlertStyleWarning;
  alert.messageText = [NSString stringWithFormat:@"Remove \u201C%@\u201D?",
      base::SysUTF8ToNSString(target.name())];
  alert.informativeText = initiator
      ? [NSString stringWithFormat:@"\u201C%@\u201D wants to remove it from this profile. Its data in this profile may be deleted.",
            base::SysUTF8ToNSString(initiator->name())]
      : @"This removes it from this profile. Its data in this profile may be deleted.";
  [alert addButtonWithTitle:@"Remove"].hasDestructiveAction = YES;
  [alert addButtonWithTitle:@"Cancel"];
  // The page may close, or the extension change, while the sheet is up: look
  // both up again by ID and recheck the policy before removing anything.
  // Blocks copy what they capture; the move-only completion stays on the heap.
  auto completion = std::make_shared<base::OnceCallback<void(bool, const std::u16string&)>>(std::move(done));
  base::WeakPtr<Profile> weak_profile = profile->GetWeakPtr();
  std::string id = target.id();
  [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
    if (!*completion) return;
    Profile* current = weak_profile.get();
    auto* extension = current ? extensions::ExtensionRegistry::Get(current)->GetInstalledExtension(id) : nullptr;
    auto* system = current ? extensions::ExtensionSystem::Get(current) : nullptr;
    std::u16string error;
    bool removed = false;
    if (response == NSAlertFirstButtonReturn && extension && system &&
        system->management_policy()->UserMayModifySettings(extension, nullptr) &&
        !system->management_policy()->MustRemainInstalled(extension, nullptr) &&
        !extensions::Manifest::IsComponentLocation(extension->location())) {
      removed = extensions::ExtensionRegistrar::Get(current)->UninstallExtension(
          id, extensions::UNINSTALL_REASON_MANAGEMENT_API, &error);
    }
    std::move(*completion).Run(removed, error);
  }];
  return true;
}

// Chromium hooks that need no bridge state: the store's Remove button
// (DEV-889). A plain global, so it may be set before ChromeMain.
void ConfigureEmbedderHooks(bool enabled) {
  extensions::ChromeManagementAPIDelegate::SetEmbedderUninstallConfirmation(
      enabled ? &ConfirmManagementUninstall : nullptr);
}

class Extensions final {
 public:
  void Initialize(const ArxEngineCallbacks& callbacks, bool enabled,
                  const base::FilePath& fixture_path,
                  std::map<uint32_t, std::vector<uint8_t>> install_fixtures,
                  const std::string& webstore_fixture_origin) {
    callbacks_ = callbacks;
    enabled_ = enabled;
    ConfigureWebstoreInstalls(callbacks, enabled, webstore_fixture_origin);
    ConfigureEmbedderHooks(enabled);
    ChromeRuntimeAPIDelegate::SetEmbedderOptionsPageOpener(base::BindRepeating(
        [](base::WeakPtr<Extensions> owner, const extensions::Extension* extension,
            content::BrowserContext* context, base::OnceCallback<void(bool)> callback) {
          if (owner) owner->OpenRuntimeOptions(extension, context, std::move(callback));
          else std::move(callback).Run(false);
        }, weak_factory_.GetWeakPtr()));
    fixture_path_ = fixture_path;
    settings_diagnostic_profile_ = OwnedSettingsDiagnosticProfile();
    install_fixtures_ = std::move(install_fixtures);
  }

  bool enabled() const { return enabled_; }
  // DEV-1019: the extensions smoke's fixture run, which may add fixture filters.
  bool IsFixtureRun() const { return !fixture_path_.empty(); }
  bool IsOwnedFixture(const extensions::Extension* extension) const {
    return enabled_ && extension && !fixture_path_.empty() && extension->path() == fixture_path_;
  }

  bool HasViewWork(const std::string& key) const { return runtime_options_profiles_.contains(key); }

  void OpenRuntimeOptions(const extensions::Extension* caller, content::BrowserContext* context,
      base::OnceCallback<void(bool)> callback) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    auto* profile = context ? Profile::FromBrowserContext(context) : nullptr;
    const auto key = CurrentExtensionProfileKey(profile);
    scoped_refptr<const extensions::Extension> extension = caller;
    auto* registry = profile ? extensions::ExtensionRegistry::Get(profile) : nullptr;
    if (!enabled_ || !key || !extension || !registry || runtime_options_profiles_.contains(*key) ||
        extension->manifest_version() != 3 ||
        registry->enabled_extensions().GetByID(extension->id()) != extension.get() ||
        extensions::Manifest::IsComponentLocation(extension->location()) ||
        extensions::ExtensionPrefs::Get(profile)->DidExtensionEscalatePermissions(extension->id()) ||
        !extensions::OptionsPageInfo::HasOptionsPage(extension.get())) {
      std::move(callback).Run(false); return;
    }
    auto keepalive = ScopedProfileKeepAlive::TryAcquire(profile, ProfileKeepAliveOrigin::kBrowserWindow);
    if (!keepalive) { std::move(callback).Run(false); return; }
    runtime_options_profiles_.insert(*key);
    base::ScopedClosureRunner release(base::BindOnce([](base::WeakPtr<Extensions> owner, std::string key) {
      if (owner) owner->runtime_options_profiles_.erase(key);
    }, weak_factory_.GetWeakPtr(), *key));
    const auto url = extensions::OptionsPageInfo::GetOptionsPage(extension.get());
    const bool accepted = AdoptRuntimeExtensionOptions(profile, *key, extension.get(), url);
    // Publication may synchronously disable/remove the extension or stop Arx.
    const bool current = enabled_ && ExtensionProfileIsCurrent(profile, *key) &&
        registry->enabled_extensions().GetByID(extension->id()) == extension.get();
    std::move(callback).Run(accepted && current);
    // Physical profile/retirement ownership lasts through the Chrome reply too.
  }

  void Shutdown() {
    enabled_ = false;
    ChromeRuntimeAPIDelegate::SetEmbedderOptionsPageOpener({});
    ConfigureEmbedderHooks(false);
    runtime_options_profiles_.clear();
    install_observers_.clear();
    ShutdownWebstoreInstalls();
    ShutdownExtensionInstalls();
    weak_factory_.InvalidateWeakPtrs();
    pending_.clear();
    loading_profiles_.clear();
    unpacked_keepalives_.clear();
    inventories_.clear();
    callbacks_ = {};
    fixture_path_.clear();
    settings_diagnostic_profile_.clear();
    install_fixtures_.clear();
  }

  void Request(Profile* profile, const std::string& key, uint64_t request,
               uint64_t revision, const std::string& id, ArxExtensionAction action,
               bool load_fixture) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!enabled_ || !profile || profile->IsOffTheRecord()) {
      Reply(request, key, ARX_EXTENSION_UNAVAILABLE); return;
    }
    if (!request || pending_.contains(request) || pending_.size() >= kMaximumRequests ||
        loading_profiles_.contains(key) || HasExtensionInstallWork(key)) { Reply(request, key, ARX_EXTENSION_BUSY); return; }
    auto* system = extensions::ExtensionSystem::Get(profile);
    if (!system) { Reply(request, key, ARX_EXTENSION_UNAVAILABLE); return; }
    auto& pending = pending_[request];
    pending.key = key;
    pending.timer = std::make_unique<base::OneShotTimer>();
    pending.timer->Start(FROM_HERE, base::Seconds(15), base::BindOnce(
        &Extensions::Timeout, weak_factory_.GetWeakPtr(), request));
    system->ready().Post(FROM_HERE, base::BindOnce(&Extensions::Ready,
        weak_factory_.GetWeakPtr(), profile, key, request, revision, id, action, load_fixture));
  }

  void OpenView(Profile* profile, const std::string& key, uint64_t request,
      uint64_t revision, const std::string& id, ArxExtensionViewKind kind,
      uint64_t source_page, uint64_t source_generation) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!enabled_ || !profile || profile->IsOffTheRecord()) {
      Reply(request, key, ARX_EXTENSION_UNAVAILABLE); return;
    }
    if (!request || pending_.contains(request) || pending_.size() >= kMaximumRequests ||
        loading_profiles_.contains(key) || HasExtensionInstallWork(key)) { Reply(request, key, ARX_EXTENSION_BUSY); return; }
    auto* system = extensions::ExtensionSystem::Get(profile);
    auto found = inventories_.find(key);
    // A real inventory already required a ready ExtensionSystem. Do not retain
    // an unbounded ready-event callback or a raw Profile during host admission.
    if (!system || !system->ready().is_signaled() || found == inventories_.end() ||
        found->second->profile() != profile) { Reply(request, key, ARX_EXTENSION_STALE); return; }
    auto json = found->second->Read(FixturePath());
    if (!json) { Reply(request, key, ARX_EXTENSION_LIMIT_EXCEEDED); return; }
    if (!revision || revision != found->second->revision() || !crx_file::id_util::IdIsValid(id)) {
      Reply(request, key, ARX_EXTENSION_STALE); return;
    }
    scoped_refptr<const extensions::Extension> extension =
        extensions::ExtensionRegistry::Get(profile)->enabled_extensions().GetByID(id);
    if (!extension ||
        extensions::ExtensionPrefs::Get(profile)->DidExtensionEscalatePermissions(id) ||
        (!IsContentBlocker(*extension) &&
         (extension->manifest_version() != 3 ||
          extensions::Manifest::IsComponentLocation(extension->location())))) {
      Reply(request, key, ARX_EXTENSION_POLICY_BLOCKED); return;
    }
    if (kind != ARX_EXTENSION_VIEW_OPTIONS || source_page || source_generation ||
        !extensions::OptionsPageInfo::HasOptionsPage(extension.get())) {
      Reply(request, key, ARX_EXTENSION_INVALID_REQUEST); return;
    }
    const auto url = extensions::OptionsPageInfo::GetOptionsPage(extension.get());
    if (!IsEnabledExtensionPage(profile, url) || url.host() != id) {
      Reply(request, key, ARX_EXTENSION_POLICY_BLOCKED); return;
    }
    pending_[request].key = key;
    const bool accepted = AdoptExtensionOptions(profile, key, id, url, request);
    // Native/Swift cancellation may have consumed the exact logical request
    // during publication. An accepted page remains its host's responsibility.
    Complete(request, key, accepted ? ARX_EXTENSION_SUCCESS : ARX_EXTENSION_FAILED);
  }


  void Cancel(uint64_t request) {
    pending_.erase(request);
    if (CancelWebstoreDownload(request)) return;
    CancelExtensionInstall(request);
  }

  void InstallFixture(Profile* profile, const std::string& key, uint64_t request,
                      uint64_t revision, const std::string& expected_id, uint32_t variant) {
    auto found = install_fixtures_.find(variant);
    if (FixturePath().empty() || found == install_fixtures_.end()) {
      Reply(request, key, ARX_EXTENSION_UNAVAILABLE); return;
    }
    Install(profile, key, request, revision, expected_id, "Arx Disposable Signed Fixture.crx", found->second);
  }

  // `webstore_id` is set only for a Chrome Web Store package (DEV-765), which
  // must carry that ID and the store's publisher signature. `observer` learns
  // the terminal status after the app does.
  void Install(Profile* profile, const std::string& key, uint64_t request, uint64_t revision,
               const std::string& expected_id, const std::string& source_basename,
               base::span<const uint8_t> bytes, const std::string& webstore_id = {},
               base::OnceCallback<void(ArxExtensionStatus)> observer = {}) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    auto refuse = [&](ArxExtensionStatus status) {
      Reply(request, key, status);
      if (observer) std::move(observer).Run(status);
    };
    if (!enabled_ || !profile || profile->IsOffTheRecord()) {
      refuse(ARX_EXTENSION_UNAVAILABLE); return;
    }
    if (!request || pending_.contains(request) || pending_.size() >= kMaximumRequests ||
        loading_profiles_.contains(key) || HasExtensionInstallWork(key)) {
      refuse(ARX_EXTENSION_BUSY); return;
    }
    if (!ValidateInstall(profile, key, revision)) {
      refuse(ARX_EXTENSION_STALE); return;
    }
    pending_[request].key = key;
    if (observer) install_observers_[request] = std::move(observer);
    if (!BeginExtensionInstall(profile, key, request, revision, expected_id, webstore_id,
        source_basename, bytes,
        callbacks_, base::BindRepeating([](base::WeakPtr<Extensions> owner, Profile* profile,
            const std::string& key, uint64_t revision) {
          return owner && owner->ValidateInstall(profile, key, revision);
        }, weak_factory_.GetWeakPtr()),
        base::BindOnce(&Extensions::InstallCompleted, weak_factory_.GetWeakPtr(), request, key))) {
      pending_.erase(request);
      Reply(request, key, ARX_EXTENSION_INVALID_REQUEST);
      NotifyInstallObserver(request, ARX_EXTENSION_INVALID_REQUEST);
    }
  }

  void ReplyRequest(uint64_t request, const std::string& key, ArxExtensionStatus status) {
    if (pending_.contains(request)) return;
    Reply(request, key, status);
  }

  // Developer-selected folder. The inventory revision binds the request to the
  // exact displayed profile state; Chromium performs every content check.
  void LoadUnpacked(Profile* profile, const std::string& key, uint64_t request,
                    uint64_t revision, const std::string& directory) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!enabled_ || !profile || profile->IsOffTheRecord()) {
      Reply(request, key, ARX_EXTENSION_UNAVAILABLE); return;
    }
    if (!request || pending_.contains(request) || pending_.size() >= kMaximumRequests ||
        loading_profiles_.contains(key) || HasExtensionInstallWork(key)) {
      Reply(request, key, ARX_EXTENSION_BUSY); return;
    }
    const base::FilePath path(directory);
    if (directory.empty() || directory.size() > kMaximumUnpackedPathBytes ||
        !base::IsStringUTF8(directory) || !path.IsAbsolute() || path.ReferencesParent()) {
      Reply(request, key, ARX_EXTENSION_INVALID_REQUEST); return;
    }
    auto* system = extensions::ExtensionSystem::Get(profile);
    if (!system || !system->ready().is_signaled() || !ValidateInstall(profile, key, revision)) {
      Reply(request, key, ARX_EXTENSION_STALE); return;
    }
    pending_[request].key = key;
    StartUnpacked(profile, key, request, path, {});
  }

  bool HasLoadWork(const std::string& key) const { return loading_profiles_.contains(key); }

  // DEV-880. A request still owes the profile's reply.
  bool HasRequestWork(const std::string& key) const {
    for (const auto& [request, pending] : pending_)
      if (pending.key == key) return true;
    return false;
  }

  // DEV-880. The profile is being released: its inventory observes the
  // profile's registry and prefs, which go with it. A later inspect reads a new one.
  void ForgetProfile(const std::string& key) { inventories_.erase(key); }

 private:
  bool ValidateInstall(Profile* profile, const std::string& key, uint64_t revision) {
    if (!enabled_ || !ExtensionProfileIsCurrent(profile, key)) return false;
    auto found = inventories_.find(key);
    if (found == inventories_.end() || found->second->profile() != profile) return false;
    auto json = found->second->Read(FixturePath());
    return json && revision && found->second->revision() == revision;
  }

  void InstallCompleted(uint64_t request, std::string key, ArxExtensionStatus status) {
    Complete(request, key, status);
    NotifyInstallObserver(request, status);
  }

  void NotifyInstallObserver(uint64_t request, ArxExtensionStatus status) {
    auto found = install_observers_.find(request);
    if (found == install_observers_.end()) return;
    auto observer = std::move(found->second);
    install_observers_.erase(found);
    std::move(observer).Run(status);
  }

  struct Pending {
    std::string key;
    std::unique_ptr<base::OneShotTimer> timer;
  };

  void Timeout(uint64_t request) {
    auto found = pending_.find(request);
    if (found == pending_.end()) return;
    auto key = found->second.key;
    pending_.erase(found);
    Reply(request, key, ARX_EXTENSION_TIMEOUT);
  }

  void Reply(uint64_t request, const std::string& key, ArxExtensionStatus status,
             uint64_t revision = 0, const std::string& json = {}) {
    if (callbacks_.extensions_completed) callbacks_.extensions_completed(
        callbacks_.context, request, key.c_str(), status, revision,
        reinterpret_cast<const uint8_t*>(json.data()), json.size());
  }

  void Complete(uint64_t request, const std::string& key, ArxExtensionStatus status,
                const std::string& detail = {}) {
    if (!pending_.erase(request)) return;
    if (status != ARX_EXTENSION_SUCCESS && !detail.empty()) {
      base::DictValue payload;
      payload.Set("error", detail);
      const auto json = base::WriteJson(payload);
      Reply(request, key, status, 0, json.value_or(std::string()));
      return;
    }
    if (status != ARX_EXTENSION_SUCCESS) { Reply(request, key, status); return; }
    auto found = inventories_.find(key);
    if (found == inventories_.end()) { Reply(request, key, ARX_EXTENSION_UNAVAILABLE); return; }
    auto json = found->second->Read(FixturePath());
    if (!json) { Reply(request, key, ARX_EXTENSION_LIMIT_EXCEEDED); return; }
    Reply(request, key, status, found->second->revision(), *json);
  }

  base::FilePath FixturePath() const { return fixture_path_; }

  void Ready(Profile* profile, std::string key, uint64_t request, uint64_t revision,
             std::string id, ArxExtensionAction action, bool load_fixture) {
    if (!pending_.contains(request)) return;
    // Requests can be queued together before ExtensionSystem becomes ready.
    // Recheck the physical installation slot at execution, not only enqueue.
    if (loading_profiles_.contains(key) || HasExtensionInstallWork(key)) { Complete(request, key, ARX_EXTENSION_BUSY); return; }
    auto* registrar = extensions::ExtensionRegistrar::Get(profile);
    if (!registrar || !registrar->IsInitialized()) {
      Complete(request, key, ARX_EXTENSION_UNAVAILABLE); return;
    }
    auto& inventory = inventories_[key];
    if (!inventory) {
      const auto path = profile->GetOriginalProfile()->GetPath();
      const bool owned_settings = !settings_diagnostic_profile_.empty() &&
          (path == settings_diagnostic_profile_ || settings_diagnostic_profile_.IsParent(path));
      inventory = std::make_unique<Inventory>(profile, !fixture_path_.empty() || owned_settings);
    }
    if (inventory->profile() != profile) { Complete(request, key, ARX_EXTENSION_STALE); return; }
    if (load_fixture) { LoadFixture(profile, key, request); return; }
    if (action == ARX_EXTENSION_INSPECT) { Complete(request, key, ARX_EXTENSION_SUCCESS); return; }
    auto json = inventory->Read(FixturePath());
    if (!json) { Complete(request, key, ARX_EXTENSION_LIMIT_EXCEEDED); return; }
    if (!revision || revision != inventory->revision()) { Complete(request, key, ARX_EXTENSION_STALE); return; }
    auto* registry = extensions::ExtensionRegistry::Get(profile);
    const auto* extension = registry->GetInstalledExtension(id);
    if (!crx_file::id_util::IdIsValid(id) || !extension) { Complete(request, key, ARX_EXTENSION_STALE); return; }
    auto* prefs = extensions::ExtensionPrefs::Get(profile);
    auto* policy = extensions::ExtensionSystem::Get(profile)->management_policy();
    if (!policy->UserMayModifySettings(extension, nullptr) ||
        extensions::Manifest::IsComponentLocation(extension->location())) {
      Complete(request, key, ARX_EXTENSION_POLICY_BLOCKED); return;
    }
    switch (action) {
      case ARX_EXTENSION_ENABLE: {
        const auto reasons = prefs->GetDisableReasons(id);
        if (prefs->DidExtensionEscalatePermissions(id) ||
            reasons != extensions::DisableReasonSet{extensions::disable_reason::DISABLE_USER_ACTION}) {
          Complete(request, key, ARX_EXTENSION_REVIEW_REQUIRED); return;
        }
        if (!registry->disabled_extensions().Contains(id) || extension->manifest_version() != 3 ||
            policy->MustRemainDisabled(extension, nullptr)) {
          Complete(request, key, ARX_EXTENSION_POLICY_BLOCKED); return;
        }
        // Never grant active permissions or clear all disable reasons here.
        registrar->RemoveDisableReasonAndMaybeEnable(id, extensions::disable_reason::DISABLE_USER_ACTION);
        if (!registry->enabled_extensions().Contains(id)) { Complete(request, key, ARX_EXTENSION_FAILED); return; }
        break;
      }
      case ARX_EXTENSION_DISABLE:
        if (!registry->enabled_extensions().Contains(id) || policy->MustRemainEnabled(extension, nullptr)) { Complete(request, key, ARX_EXTENSION_POLICY_BLOCKED); return; }
        registrar->DisableExtension(id, {extensions::disable_reason::DISABLE_USER_ACTION});
        if (registry->enabled_extensions().Contains(id)) { Complete(request, key, ARX_EXTENSION_FAILED); return; }
        break;
      case ARX_EXTENSION_REMOVE: {
        if (policy->MustRemainInstalled(extension, nullptr)) { Complete(request, key, ARX_EXTENSION_POLICY_BLOCKED); return; }
        std::u16string error;
        // Success means removed from the installed registry. Chromium performs
        // asynchronous storage cleanup; this is not a disk-erasure guarantee.
        if (!registrar->UninstallExtension(id, extensions::UNINSTALL_REASON_USER_INITIATED, &error)) {
          Complete(request, key, ARX_EXTENSION_FAILED); return;
        }
        break;
      }
      case ARX_EXTENSION_RELOAD:
        // Only a developer-loaded folder can be reread; packed installs update
        // through verified CRX consent instead.
        if (extension->location() != extensions::mojom::ManifestLocation::kUnpacked) {
          Complete(request, key, ARX_EXTENSION_POLICY_BLOCKED); return;
        }
        StartUnpacked(profile, key, request, extension->path(), id);
        return;
      case ARX_EXTENSION_ALLOW_PRIVATE:
      case ARX_EXTENSION_DISALLOW_PRIVATE: {
        // DEV-889. Chromium writes the pref and reloads an enabled extension,
        // which takes it out of the registry for a moment; the reply rereads.
        const bool allow = action == ARX_EXTENSION_ALLOW_PRIVATE;
        if (allow ? !CanRunInPrivateWindows(*extension)
                  : !extensions::util::CanBeIncognitoEnabled(extension)) {
          Complete(request, key, ARX_EXTENSION_POLICY_BLOCKED); return;
        }
        if (extensions::util::IsIncognitoEnabled(id, profile) != allow)
          extensions::util::SetIsIncognitoEnabled(id, profile, allow);
        if (extensions::util::IsIncognitoEnabled(id, profile) != allow) {
          Complete(request, key, ARX_EXTENSION_FAILED); return;
        }
        break;
      }
      case ARX_EXTENSION_FIXTURE_REQUIRE_PERMISSIONS:
        if (FixturePath().empty() || extension->path() != FixturePath()) {
          Complete(request, key, ARX_EXTENSION_UNAVAILABLE); return;
        }
        registrar->DisableExtension(id, {extensions::disable_reason::DISABLE_PERMISSIONS_INCREASE});
        break;
      default: Complete(request, key, ARX_EXTENSION_INVALID_REQUEST); return;
    }
    Complete(request, key, ARX_EXTENSION_SUCCESS);
  }

  // The pending request exists. Physical work retains the profile through
  // Chromium's completion, independently of cancellation or timeout.
  void StartUnpacked(Profile* profile, const std::string& key, uint64_t request,
                     const base::FilePath& path, const std::string& expected_id) {
    auto& pending = pending_[request];
    pending.key = key;
    pending.timer = std::make_unique<base::OneShotTimer>();
    pending.timer->Start(FROM_HERE, base::Minutes(1), base::BindOnce(
        &Extensions::Timeout, weak_factory_.GetWeakPtr(), request));
    const auto* developer_mode = profile->GetPrefs()->FindPreference(prefs::kExtensionsUIDeveloperMode);
    const bool developer_mode_locked = !developer_mode ||
        (!developer_mode->IsUserModifiable() && !profile->GetPrefs()->GetBoolean(prefs::kExtensionsUIDeveloperMode));
    if (developer_mode_locked || extensions::ExtensionsBrowserClient::Get()
        ->GetExtensionManagementClient(profile)->BlocklistedByDefault()) {
      Complete(request, key, ARX_EXTENSION_POLICY_BLOCKED); return;
    }
    auto keepalive = ScopedProfileKeepAlive::TryAcquire(profile, ProfileKeepAliveOrigin::kExtensionUpdater);
    if (!keepalive) { Complete(request, key, ARX_EXTENSION_UNAVAILABLE); return; }
    loading_profiles_.insert(key);
    unpacked_keepalives_[key] = std::move(keepalive);
    if (!extensions::GetExtensionFileTaskRunner()->PostTaskAndReplyWithResult(FROM_HERE,
        base::BindOnce(&InspectUnpackedDirectory, path),
        base::BindOnce(&Extensions::UnpackedInspected, weak_factory_.GetWeakPtr(),
            profile->GetWeakPtr(), key, request, expected_id))) {
      FinishUnpacked(key);
      Complete(request, key, ARX_EXTENSION_FAILED);
    }
  }

  void FinishUnpacked(const std::string& key) {
    loading_profiles_.erase(key);
    unpacked_keepalives_.erase(key);
  }

  void UnpackedInspected(base::WeakPtr<Profile> profile, std::string key, uint64_t request,
                         std::string expected_id, UnpackedDirectory directory) {
    if (!pending_.contains(request) || !enabled_ || !profile ||
        !ExtensionProfileIsCurrent(profile.get(), key)) {
      FinishUnpacked(key);
      Complete(request, key, ARX_EXTENSION_UNAVAILABLE);
      return;
    }
    if (directory.status != ARX_EXTENSION_SUCCESS) {
      FinishUnpacked(key);
      Complete(request, key, directory.status, directory.detail);
      return;
    }
    // Chromium disables unpacked extensions while its per-profile developer
    // mode is off. Enable it for this ordinary profile only; a failed first
    // load restores the previous value.
    const bool changed = !profile->GetPrefs()->GetBoolean(prefs::kExtensionsUIDeveloperMode);
    if (changed) extensions::util::SetDeveloperModeForProfile(profile.get(), true);
    auto installer = extensions::UnpackedInstaller::Create(profile.get());
    installer->set_require_modern_manifest_version(true);
    installer->set_allow_incognito_access(false);
    installer->set_be_noisy_on_failure(false);
    installer->set_completion_callback(base::BindOnce(&Extensions::UnpackedLoaded,
        weak_factory_.GetWeakPtr(), profile, key, request, expected_id, changed));
    installer->Load(directory.path);
  }

  void UnpackedLoaded(base::WeakPtr<Profile> profile, std::string key, uint64_t request,
                      std::string expected_id, bool changed_developer_mode,
                      const extensions::Extension* extension, const base::FilePath&,
                      const std::u16string& error) {
    FinishUnpacked(key);
    if (!extension && changed_developer_mode && profile) {
      extensions::util::SetDeveloperModeForProfile(profile.get(), false);
    }
    // Cancellation and timeout never roll back a committed developer load;
    // the next inventory shows Chromium's authoritative result.
    if (!pending_.contains(request)) return;
    if (!profile || !ExtensionProfileIsCurrent(profile.get(), key)) {
      Complete(request, key, ARX_EXTENSION_UNAVAILABLE); return;
    }
    if (!extension) {
      Complete(request, key, ARX_EXTENSION_MANIFEST_INVALID, LoadErrorDetail(error)); return;
    }
    // A policy provider can still refuse registration after a clean read.
    if (!extensions::ExtensionRegistry::Get(profile.get())->GetInstalledExtension(extension->id())) {
      Complete(request, key, ARX_EXTENSION_POLICY_BLOCKED); return;
    }
    if (!expected_id.empty() && extension->id() != expected_id) {
      Complete(request, key, ARX_EXTENSION_STALE); return;
    }
    Complete(request, key, ARX_EXTENSION_SUCCESS);
  }

  void LoadFixture(Profile* profile, const std::string& key, uint64_t request) {
    const auto path = FixturePath();
    if (path.empty()) { Complete(request, key, ARX_EXTENSION_UNAVAILABLE); return; }
    const auto installed = extensions::ExtensionRegistry::Get(profile)->GenerateInstalledExtensionsSet();
    for (const auto& extension : installed) {
      if (extension->path() == path) { Complete(request, key, ARX_EXTENSION_INVALID_REQUEST); return; }
    }
    // This preference is changed only in the fresh root owned by fixture Run.
    extensions::util::SetDeveloperModeForProfile(profile, true);
    loading_profiles_.insert(key);
    auto installer = extensions::UnpackedInstaller::Create(profile);
    installer->set_require_modern_manifest_version(true);
    installer->set_allow_file_access(false);
    installer->set_allow_incognito_access(false);
    installer->set_be_noisy_on_failure(false);
    installer->set_completion_callback(base::BindOnce(&Extensions::FixtureLoaded,
        weak_factory_.GetWeakPtr(), profile, key, request));
    installer->Load(path);
  }

  void FixtureLoaded(Profile* profile, std::string key, uint64_t request,
                     const extensions::Extension* extension, const base::FilePath&,
                     const std::u16string&) {
    loading_profiles_.erase(key);
    if (!pending_.contains(request)) {
      // Cancellation retains the physical install slot until this callback,
      // then removes only this exact disposable fixture if it was installed.
      if (extension && extension->path() == FixturePath()) {
        std::u16string error;
        extensions::ExtensionRegistrar::Get(profile)->UninstallExtension(
            extension->id(), extensions::UNINSTALL_REASON_FOR_TESTING, &error);
      }
      return;
    }
    Complete(request, key, extension ? ARX_EXTENSION_SUCCESS : ARX_EXTENSION_FAILED);
  }

  ArxEngineCallbacks callbacks_ = {};
  std::set<std::string> runtime_options_profiles_;
  bool enabled_ = false;
  base::FilePath fixture_path_;
  base::FilePath settings_diagnostic_profile_;
  std::map<uint32_t, std::vector<uint8_t>> install_fixtures_;
  std::map<std::string, std::unique_ptr<Inventory>> inventories_;
  std::map<uint64_t, Pending> pending_;
  std::map<uint64_t, base::OnceCallback<void(ArxExtensionStatus)>> install_observers_;
  std::set<std::string> loading_profiles_;
  std::map<std::string, std::unique_ptr<ScopedProfileKeepAlive>> unpacked_keepalives_;
  base::WeakPtrFactory<Extensions> weak_factory_{this};
};

Extensions& Bridge() { static base::NoDestructor<Extensions> bridge; return *bridge; }
}  // namespace

// Runs only at explicit fixture startup, before UI-thread blocking restrictions.
// Packages are generated from compiled source with fresh private signing keys;
// production intake still uses SandboxedUnpacker/CRX3 signature verification.
bool PrepareInstallFixtures(const base::FilePath& root,
                            std::map<uint32_t, std::vector<uint8_t>>& fixtures) {
  auto fail = [](uint32_t phase) {
    std::fprintf(stderr, "ARX_EXTENSION_INSTALL_FIXTURE_PREPARE_FAILED phase=%u\n", phase);
    return false;
  };
  // ExtensionCreator performs manifest validation through registries that are
  // not initialized before ChromeMain. The fixture signs only its compiled
  // source here; the ordinary installer validates manifest and CRX3 later.
  const auto key = crypto::keypair::PrivateKey::GenerateRsa2048();
  const auto first_zip = root.AppendASCII("install-v1.zip");
  const auto first_package = root.AppendASCII("install-v1.crx");
  if (!zip::Zip(root.AppendASCII("extension"), first_zip, false)) return fail(1);
  if (crx_file::Create(first_package, first_zip, key) != crx_file::CreatorResult::OK) return fail(2);
  const auto second_source = root.AppendASCII("extension-v2");
  std::string manifest = kFixtureManifest;
  const auto version = manifest.find("\"version\": \"1.0\"");
  const auto permissions = manifest.find("\"storage\", \"declarativeNetRequest\"");
  if (version == std::string::npos || permissions == std::string::npos) return fail(3);
  manifest.replace(permissions, std::string("\"storage\", \"declarativeNetRequest\"").size(),
                   "\"storage\", \"declarativeNetRequest\", \"tabs\", \"nativeMessaging\"");
  manifest.replace(version, std::string("\"version\": \"1.0\"").size(), "\"version\": \"2.0\"");
  if (!base::CreateDirectory(second_source) || !base::SetPosixFilePermissions(second_source, 0700) ||
      !base::WriteFile(second_source.AppendASCII("manifest.json"), manifest) ||
      !base::WriteFile(second_source.AppendASCII("worker.js"), kFixtureWorker) ||
      !base::WriteFile(second_source.AppendASCII("content.js"), kFixtureContent) ||
      !base::WriteFile(second_source.AppendASCII("rules.json"), kFixtureRules)) return fail(4);
  // Keep every manifest-referenced options/action resource in the update.
  for (const char* name : {"options.html", "options.js", "popup.html", "popup.js"}) {
    if (!base::CopyFile(root.AppendASCII("extension").AppendASCII(name),
                        second_source.AppendASCII(name))) return fail(4);
  }
  const auto second_package = root.AppendASCII("install-v2.crx");
  const auto second_zip = root.AppendASCII("install-v2.zip");
  if (!zip::Zip(second_source, second_zip, false)) return fail(5);
  if (crx_file::Create(second_package, second_zip, key) != crx_file::CreatorResult::OK) return fail(6);
  const auto other_package = root.AppendASCII("install-other-key.crx");
  const auto other_key = crypto::keypair::PrivateKey::GenerateRsa2048();
  if (crx_file::Create(other_package, second_zip, other_key) != crx_file::CreatorResult::OK) return fail(7);
  for (const auto& [variant, path] : std::map<uint32_t, base::FilePath>{
      {0, first_package}, {1, second_package}, {2, other_package}}) {
    std::string bytes;
    if (!base::ReadFileToStringWithMaxSize(path, &bytes, 1024 * 1024) || bytes.empty()) return fail(8);
    fixtures[variant] = std::vector<uint8_t>(bytes.begin(), bytes.end());
  }
  fixtures[3] = fixtures[0];
  fixtures[3].back() ^= 0xff;  // Corrupt a signed byte; verifier must refuse it.
  return true;
}

bool InitializeNativeMessagingFixture(const base::FilePath& directory,
    const base::FilePath& extension_path) {
  base::FilePath executable;
  if (!base::PathService::Get(base::FILE_EXE, &executable)) return false;
  executable = base::MakeAbsoluteFilePath(executable);
  const auto helper = executable.DirName().AppendASCII("ArxNativeMessagingFixture");
  const auto size = base::GetFileSize(helper);
  int mode = 0;
  if (executable.empty() || base::IsLink(helper) || base::DirectoryExists(helper) || !size || *size <= 0 || *size > 1048576 ||
      !base::GetPosixFilePermissions(helper, &mode) || !(mode & 0111)) return false;
  const auto hosts = directory.AppendASCII("Browser").AppendASCII("NativeMessagingHosts");
  if (!base::CreateDirectory(hosts)) return false;
  const auto id = crx_file::id_util::GenerateIdForPath(extension_path);
  if (!crx_file::id_util::IdIsValid(id)) return false;
  for (bool forbidden : {false, true}) {
    const std::string name = forbidden ? "dev.capturecontext.arx.forbidden" : "dev.capturecontext.arx.fixture";
    base::DictValue manifest;
    manifest.Set("name", name);
    manifest.Set("description", "Arx disposable native messaging fixture");
    manifest.Set("path", helper.value());
    manifest.Set("type", "stdio");
    base::ListValue origins;
    origins.Append("chrome-extension://" + (forbidden ? std::string(32, id[0] == 'b' ? 'a' : 'b') : id) + "/");
    manifest.Set("allowed_origins", std::move(origins));
    const auto json = base::WriteJson(manifest);
    if (!json || !base::WriteFile(hosts.AppendASCII(name + ".json"), *json)) return false;
  }
  return true;
}

bool InitializeExtensions(const ArxEngineCallbacks& callbacks, bool enabled,
                          const base::FilePath& fixture_directory, bool prepare_signed_fixture,
                          const std::string& webstore_fixture_origin) {
  // Startup runs before ChromeMain installs UI-thread blocking restrictions.
  // Prepare these exact small files here, never from a live UI request.
  base::FilePath fixture_path;
  std::map<uint32_t, std::vector<uint8_t>> install_fixtures;
  if (!fixture_directory.empty()) {
    const auto path = fixture_directory.AppendASCII("extension");
    std::string fixture_manifest = kFixtureManifest;
    if (!prepare_signed_fixture) {
      // Ordinary extension acceptance exercises messaging. The signed-install
      // v1 must retain its smaller permission set to test explicit escalation.
      const std::string permission = "\"declarativeNetRequest\"";
      const auto offset = fixture_manifest.find(permission);
      if (offset == std::string::npos) return false;
      fixture_manifest.replace(offset, permission.size(), permission + ", \"nativeMessaging\"");
    }
    if (!base::CreateDirectory(path) ||
        !base::WriteFile(path.AppendASCII("manifest.json"), fixture_manifest) ||
        !base::WriteFile(path.AppendASCII("worker.js"), kFixtureWorker) ||
        !base::WriteFile(path.AppendASCII("content.js"), kFixtureContent) ||
        !base::WriteFile(path.AppendASCII("rules.json"), kFixtureRules) ||
        !base::WriteFile(path.AppendASCII("native.html"),
            "<!doctype html><title>Arx native messaging loading</title><script src=native.js></script>") ||
        !base::WriteFile(path.AppendASCII("native.js"), kFixtureNative) ||
        !base::WriteFile(path.AppendASCII("popup.html"),
            "<!doctype html><title>Arx action loading</title>"
            "<style>html,body{margin:0;width:320px;height:180px}a{display:block;position:absolute;left:8px;top:40px;width:280px;height:40px}</style>"
            "<a id=outgoing target=_blank rel=opener>Open ordinary page</a>"
            "<button id=options style='position:absolute;left:8px;top:100px;width:280px;height:40px'>Open options</button>"
            "<input id=field style='position:absolute;left:8px;top:148px;width:200px;height:20px'>"
            "<script src=popup.js></script>") ||
        !base::WriteFile(path.AppendASCII("popup.js"), kFixturePopup) ||
        !base::WriteFile(path.AppendASCII("options.html"),
            "<!doctype html><title>Arx extension options loading</title><script src=options.js></script>") ||
        !base::WriteFile(path.AppendASCII("options.js"),
            "chrome.storage.local.get({count:0}).then(v=>document.title='ARX_EXTENSION_OPTIONS:'+chrome.runtime.id+':count='+v.count)")) return false;
    // UnpackedInstaller resolves symlinks before installing. Store that same
    // identity now, before UI-thread blocking restrictions, so /var aliases do
    // not break inventory marking, duplicate checks or late-cancel cleanup.
    fixture_path = base::MakeAbsoluteFilePath(path);
    if (fixture_path.empty() || (prepare_signed_fixture &&
        !PrepareInstallFixtures(fixture_directory, install_fixtures))) return false;
    if (!prepare_signed_fixture && !InitializeNativeMessagingFixture(fixture_directory, fixture_path)) {
      std::fputs("ARX_EXTENSION_FIXTURE_NATIVE_HOST_INVALID\n", stderr);
      return false;
    }
  }
  Bridge().Initialize(callbacks, enabled, fixture_path, std::move(install_fixtures),
                      webstore_fixture_origin);
  return true;
}
void ShutdownExtensions() { Bridge().Shutdown(); }
void PreparePrivateExtensions(Profile* profile) {
  // DEV-889: Chrome starts a private context's split-mode background pages when
  // its first incognito Browser window opens (ChromeProcessManagerDelegate::
  // OnBrowserCreated). Arx has no Browser, so start them here, once the
  // context exists. Spanning extensions keep running in the parent.
  if (!Bridge().enabled() || !profile || !profile->IsOffTheRecord()) return;
  auto* system = extensions::ExtensionSystem::Get(profile);
  if (!system) return;
  // Waits for the parent's extensions to load; a context released by then is skipped.
  system->ready().Post(FROM_HERE, base::BindOnce([](base::WeakPtr<Profile> profile) {
    if (!profile || !Bridge().enabled()) return;
    if (auto* manager = extensions::ProcessManager::Get(profile.get()))
      manager->MaybeCreateStartupBackgroundHosts();
  }, profile->GetWeakPtr()));
}
void AttachExtensionHelpers(content::WebContents* contents) {
  // DEV-889: private pages get the same helpers, so the extensions their
  // opener profile allows in private windows (Chrome's incognito switch), and
  // Helium's uBlock Origin component, filter them and get their tab IDs.
  // Their action, popup and right-click items follow the opener's
  // (ExtensionActionsProfileIsCurrent, DEV-956); options stay ordinary.
  if (!Bridge().enabled()) return;
  // DEV-884: the page's profile (a private page's opener) gets Arx's content
  // blocking settings before the page loads anything.
  EnsureContentBlocking(Profile::FromBrowserContext(contents->GetBrowserContext()));
  extensions::SetViewType(contents, extensions::mojom::ViewType::kTabContents);
  extensions::ChromeExtensionWebContentsObserver::CreateForWebContents(contents);
  extensions::TabHelper::CreateForWebContents(contents);
}
void InspectExtensions(Profile* profile, const std::string& key, uint64_t request) {
  Bridge().Request(profile, key, request, 0, {}, ARX_EXTENSION_INSPECT, false);
}
void ManageExtension(Profile* profile, const std::string& key, uint64_t request,
                     uint64_t revision, const std::string& id, ArxExtensionAction action) {
  Bridge().Request(profile, key, request, revision, id, action, false);
}
void LoadExtensionFixture(Profile* profile, const std::string& key, uint64_t request) {
  Bridge().Request(profile, key, request, 0, {}, ARX_EXTENSION_INSPECT, true);
}
bool ExtensionViewsAvailable() { return Bridge().enabled(); }
bool HasExtensionViewWork(const std::string& key) { return Bridge().HasViewWork(key); }
bool IsOwnedExtensionFixture(const extensions::Extension* extension) {
  return Bridge().IsOwnedFixture(extension);
}
bool IsExtensionFixtureRun() {
  return Bridge().enabled() && Bridge().IsFixtureRun();
}
bool IsEnabledExtensionPage(Profile* profile, const GURL& url) {
  if (!Bridge().enabled() || !profile || profile->IsOffTheRecord() ||
      !url.SchemeIs(extensions::kExtensionScheme) || !url.is_valid() ||
      url.has_username() || url.has_password() || url.has_port() || !crx_file::id_util::IdIsValid(url.host())) return false;
  return extensions::ExtensionRegistry::Get(profile)->enabled_extensions().Contains(std::string(url.host()));
}
bool ExtensionRunsInContext(const extensions::Extension& extension,
                            content::BrowserContext* context) {
  if (!context) return false;
  if (!context->IsOffTheRecord()) return true;
  return CanRunInPrivateWindows(extension) &&
      extensions::util::IsIncognitoEnabled(extension.id(), context);
}
void OpenExtensionView(Profile* profile, const std::string& key, uint64_t request,
    uint64_t revision, const std::string& id, ArxExtensionViewKind kind,
    uint64_t source_page, uint64_t source_generation) {
  Bridge().OpenView(profile, key, request, revision, id, kind, source_page, source_generation);
}
void CancelExtensionRequest(uint64_t request) { Bridge().Cancel(request); }
void LoadUnpackedExtension(Profile* profile, const std::string& key, uint64_t request,
                           uint64_t revision, const std::string& directory) {
  Bridge().LoadUnpacked(profile, key, request, revision, directory);
}
bool HasExtensionLoadWork(const std::string& key) { return Bridge().HasLoadWork(key); }
bool HasExtensionRequestWork(const std::string& key) { return Bridge().HasRequestWork(key); }
void ForgetExtensionProfile(const std::string& key) { Bridge().ForgetProfile(key); }
void InstallExtensionFixture(Profile* profile, const std::string& key, uint64_t request,
                             uint64_t revision, const std::string& expected_id, uint32_t variant) {
  Bridge().InstallFixture(profile, key, request, revision, expected_id, variant);
}
void InstallExtensionCRX(Profile* profile, const std::string& key, uint64_t request,
                         uint64_t revision, const std::string& expected_id,
                         const std::string& source_basename, base::span<const uint8_t> bytes) {
  Bridge().Install(profile, key, request, revision, expected_id, source_basename, bytes);
}
void InstallWebstoreCRX(Profile* profile, const std::string& key, uint64_t request,
                        uint64_t revision, const std::string& extension_id,
                        const std::string& source_name, base::span<const uint8_t> bytes,
                        base::OnceCallback<void(ArxExtensionStatus)> observer) {
  Bridge().Install(profile, key, request, revision, {}, source_name, bytes, extension_id,
                   std::move(observer));
}
void UpdateWebstoreCRX(Profile* profile, const std::string& key, uint64_t request,
                       uint64_t revision, const std::string& extension_id,
                       const std::string& source_name, base::span<const uint8_t> bytes,
                       base::OnceCallback<void(ArxExtensionStatus)> observer) {
  Bridge().Install(profile, key, request, revision, extension_id, source_name, bytes, extension_id,
                   std::move(observer));
}
void ReplyExtensionRequest(uint64_t request, const std::string& key, ArxExtensionStatus status) {
  Bridge().ReplyRequest(request, key, status);
}
}  // namespace arx
