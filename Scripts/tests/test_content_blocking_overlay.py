"""Content blocking (DEV-884): Arx's script in uBlock, its settings and list registry."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from Scripts.engine import content_blocking_overlay
from Scripts.engine.config import PACKAGE


def prepare(root):
    for relative, old, _ in content_blocking_overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


class ContentBlockingOverlayTests(unittest.TestCase):
    def test_applies_once_and_adds_the_settings_script(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            content_blocking_overlay.apply(root)
            first = snapshot(root)
            content_blocking_overlay.apply(root)
            self.assertEqual(first, snapshot(root))

            background = (root / content_blocking_overlay.BACKGROUND).read_text()
            self.assertLess(background.index("js/start.js"), background.index("js/arx.js"))
            self.assertEqual((root / content_blocking_overlay.SCRIPT).read_text(),
                             content_blocking_overlay.ARX_SCRIPT)

            # An incremental build lists the new file (generate_file_list's inputs).
            self.assertIn('"js/arx.js",', (root / content_blocking_overlay.BUILD).read_text())

    def test_ublock_starts_from_its_bundled_registry(self):
        # A bootstrap location makes uBlock fetch its registry on every start
        # (Helium keys the cached copy by it), which held back its first-run
        # restart until mid-run; nothing may set one again.
        relatives = {relative for relative, _, _ in content_blocking_overlay.patches()}
        self.assertEqual(relatives, {content_blocking_overlay.BACKGROUND, content_blocking_overlay.BUILD})
        self.assertNotIn("assetsBootstrapLocation", content_blocking_overlay.ARX_SCRIPT)
        for name in ["content_blocking_bridge.h", "content_blocking_bridge.mm", "extensions_bridge.mm"]:
            self.assertNotIn("UBlockAssetsLocation", (PACKAGE / "Native" / name).read_text(), name)

    def test_changed_anchor_stops_the_build(self):
        for index in range(len(list(content_blocking_overlay.patches()))):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                relative, old, _ = list(content_blocking_overlay.patches())[index]
                path = root / relative
                path.write_text(path.read_text().replace(old, "changed upstream\n", 1))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    content_blocking_overlay.apply(root)

    def test_native_and_script_agree_on_the_storage_key(self):
        native = (PACKAGE / "Native/content_blocking_bridge.mm").read_text()
        self.assertIn('constexpr char kStorageKey[] = "arxContentBlocking";', native)
        self.assertIn("const SETTINGS = 'arxContentBlocking';", content_blocking_overlay.ARX_SCRIPT)
        self.assertIn('"cookieBanners"', native)
        self.assertIn('"trustedSites"', native)
        # Exact origins keep their scope, IPv6 brackets included; policy rules come first.
        self.assertIn("character == '[' || character == ']'", native)
        self.assertIn("patterns.insert(entry.primary_pattern.ToString())", native)
        # A wildcard ALLOW survives a same-source ALLOW winning at its representative
        # URL; a managed rule or default outranking it doesn't.
        self.assertIn("info.primary_pattern == entry->primary_pattern ||", native)
        self.assertIn("info.source == content_settings::GetSettingSourceFromProviderType(entry->source)", native)
        self.assertIn("!info.primary_pattern.MatchesAllHosts()", native)

    def test_native_and_script_agree_on_the_hide_element_keys(self):
        native = (PACKAGE / "Native/content_blocking_bridge.mm").read_text()
        for key, name in [("arxElementPicker", "PICKER"), ("arxShowHiddenElement", "SHOW"),
                          ("arxHiddenElements", "HIDDEN"), ("arxElementPickerStatus", "PICKER_STATUS"),
                          ("arxFixtureFilters", "FIXTURE_FILTERS"), ("arxHideElement", "HIDE")]:
            self.assertIn(f'"{key}"', native)
            self.assertIn(f"const {name} = '{key}';", content_blocking_overlay.ARX_SCRIPT)
        self.assertIn('request.Set("tabId", tab.id());', native)
        self.assertIn('request.Set("filter", line);', native)
        self.assertIn('request.Set("filters", std::move(lines));', native)
        # Only the extensions smoke's fixture run takes filters.
        self.assertIn("!arx::IsExtensionFixtureRun()", native)
        # Arx's own picker saves a line only for the page's own site, and only a plain selector.
        self.assertIn("std::string_view(line).substr(0, separator) != url.host()", native)
        self.assertIn("!arx::IsPlainSelector(std::string_view(line).substr(separator + 2))", native)
        for operation in ('"+js("', '":style("', '":remove("', '"#@#"'):
            self.assertIn(operation, native)

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_hidden_elements_are_listed_by_site(self):
        result = self.run_script("hide")
        # Only lines for one named site: several sites or exclusions stay in the dashboard.
        self.assertEqual(result["listed"], {
            "example.com": ["example.com##.ad", "example.com##div[data-x=\"1\"]"],
            # A site named like an object's own property is a site like any other.
            "constructor": ["constructor##.banner"],
            # An internationalized site under its ASCII name, the line as the picker wrote it.
            "xn--bcher-kva.example": ["bücher.example##.ad"],
        })

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_the_picker_opens_only_in_the_instance_with_the_tab(self):
        result = self.run_script("hide")
        self.assertEqual(result["picked"], [[5, 0]])
        self.assertEqual(result["mouse"], False)

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_the_picker_reports_what_became_of_each_ask(self):
        result = self.run_script("hide")
        # Ids and error messages only, never a page's address.
        self.assertEqual(result["pickerStatuses"], [
            {"request": 1, "tabId": 5, "outcome": "opened", "probe": "ok"},
            {"request": 2, "tabId": 9, "outcome": "no-tab", "tabs": [5]},
            {"request": 3, "tabId": 7, "outcome": "opened", "probe": "Cannot access contents of the page."},
        ])
        self.assertEqual(result["probes"], [[5, "true"], [7, "true"]])

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_showing_an_element_takes_its_line_out_and_reloads(self):
        result = self.run_script("hide")
        self.assertNotIn("example.com##.ad", result["saved"])
        self.assertIn("example.com##div[data-x=\"1\"]", result["saved"])
        self.assertEqual(result["loads"], 1)
        self.assertEqual(result["after"]["example.com"], ["example.com##div[data-x=\"1\"]"])
        # A filter that isn't there saves nothing, but still reloads.
        self.assertEqual(result["savesForMissing"], 0)
        self.assertEqual(result["loadsForMissing"], 1)
        # The list changes only once the filters have reloaded.
        self.assertEqual(result["listedBeforeLoad"]["example.com"],
                         ["example.com##.ad", "example.com##div[data-x=\"1\"]"])
        # A reload already running when Show comes may have read the old filters: it's
        # waited for before Show saves, and a fresh one follows before the list changes.
        self.assertEqual(result["inFlight"], ["stale load done", "saved", "fresh load", "listed"])

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_the_smokes_filters_are_added_once_and_reload(self):
        fixture = self.run_script("hide")["fixture"]
        self.assertEqual(fixture["lines"], ["127.0.0.1##.arx-hide-target", "127.0.0.1##+js(noop)"])
        self.assertEqual(fixture["duplicates"], 1)
        # A second ask with lines already there saves nothing, but still reloads.
        self.assertEqual(fixture["saves"], 1)
        self.assertEqual(fixture["loads"], 2)
        self.assertTrue(fixture["unchangedByRepeat"])
        self.assertEqual(fixture["listed"], ["127.0.0.1##.arx-hide-target"])

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_the_own_pickers_line_is_added_once_and_reloads(self):
        picked = self.run_script("hide")["ownPicker"]
        self.assertEqual(picked["last"], "news.example##aside.promo")
        # A repeat saves nothing but still reloads; an ask without a line does nothing.
        self.assertEqual(picked["saves"], 1)
        self.assertEqual(picked["loads"], 2)
        self.assertTrue(picked["unchangedByRepeat"])
        self.assertEqual(picked["listed"], ["news.example##aside.promo"])

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_script_applies_settings_to_ublock(self):
        result = self.run_script("single")
        calls, whitelist = result["calls"], result["whitelist"]
        self.assertEqual(calls[0], ["select", {"toSelect": ["fanboy-cookiemonster", "ublock-cookies-easylist"], "merge": True}])
        self.assertEqual(calls[1], ["load"])
        # The exact origin stays exact, a wildcard rule's hostname stays a hostname,
        # invalid entries are ignored and the person's own directive is kept.
        self.assertEqual(whitelist[0], ["dashboard.example", ORIGIN, "shop.example", "[::1]"])
        # A site Arx no longer lists is trusted no more; the cookie lists aren't touched again.
        self.assertEqual(whitelist[1], ["dashboard.example", "shop.example"])
        self.assertEqual(sum(1 for call in calls if call[0] == "load"), 2)
        # Turning cookie banners off keeps every other list.
        self.assertIn(["select", {"toSelect": ["ublock-filters", "easylist"]}], calls)
        self.assertEqual(whitelist[2], ["dashboard.example"])
        self.assertEqual(result["applied"], {"cookieBanners": False, "trustedSites": []})
        self.assertGreaterEqual(result["changed"], 3)

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_each_split_instance_applies_a_change_once_for_itself(self):
        # Two instances share storage; the second becomes ready after the first
        # stored the new marker, and must still update its own lists.
        result = self.run_script("split")
        self.assertEqual(result["loads"], [1, 1])

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_a_directive_the_dashboard_already_had_stays(self):
        result = self.run_script("owned")
        self.assertEqual(result["whitelist"], [["dashboard.example"], ["dashboard.example"]])
        self.assertEqual(result["applied"], {"cookieBanners": False, "trustedSites": []})

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_a_late_instance_still_removes_what_another_one_added(self):
        result = self.run_script("split-owned")
        self.assertEqual(result["whitelists"], [["dashboard.example"], ["dashboard.example"]])

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_first_run_clears_cookie_lists_helium_selected_when_the_setting_is_off(self):
        result = self.run_script("upgrade")
        self.assertEqual(result["calls"], [["select", {"toSelect": ["ublock-filters", "easylist"]}], ["load"]])

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_registry_takes_upstream_as_its_source_once_ublock_is_ready(self):
        result = self.run_script("registry")
        # Nothing before uBlock is ready, so its startup never waits on it.
        self.assertEqual(result["before"], [])
        self.assertEqual(result["after"], [["metadata"], ["register", "assets.json", {
            "contentURL": ["https://ublockorigin.github.io/uAssetsCDN/ublock/assets.json",
                           "assets/assets.json"]}]])

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_a_registry_with_a_remote_source_is_left_alone(self):
        result = self.run_script("registry-remote")
        self.assertEqual(result["after"], [["metadata"]])

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_cookie_lists_stay_selected_when_upstream_registry_replaces_heliums(self):
        result = self.run_script("migration")
        self.assertEqual(result["calls"], [
            ["select", {"toSelect": ["fanboy-cookiemonster", "ublock-cookies-easylist"], "merge": True}],
            ["load"]])

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_a_queued_cookie_opt_out_wins_over_the_registry_migration(self):
        result = self.run_script("migration-opt-out")
        self.assertNotIn("fanboy-cookiemonster", result["selected"])
        self.assertNotIn(["select", {"toSelect": ["fanboy-cookiemonster", "ublock-cookies-easylist"], "merge": True}],
                         result["calls"])

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_phishing_list_is_selected_once(self):
        # DEV-923: selected the first time, then left to the dashboard: turned off
        # there, it stays off through later settings changes and a restart.
        result = self.run_script("phishing")
        self.assertEqual(result["calls"], [["select", {"toSelect": ["curben-phishing"], "merge": True}], ["load"]])
        self.assertEqual(result["applied"], {"cookieBanners": False, "trustedSites": [], "phishingList": True})
        self.assertEqual(result["later"], [])

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_a_fresh_profile_starts_with_arx_lists_and_never_loads_them_again(self):
        # DEV-682: the first page's settings find the lists already as Arx wants them.
        result = self.run_script("first-run")
        self.assertEqual(result["selected"], ["user-filters", "ublock-filters", "easylist", "curben-phishing"])
        self.assertEqual(result["calls"], [])
        self.assertEqual(result["applied"], {"cookieBanners": False, "trustedSites": [], "phishingList": True})

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_a_stored_cookie_setting_decides_the_first_selection(self):
        result = self.run_script("first-run-cookies")
        self.assertEqual(result["selected"], ["user-filters", "ublock-filters", "easylist", "fanboy-cookiemonster",
                                              "ublock-cookies-easylist", "curben-phishing"])
        self.assertEqual(result["calls"], [])

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_a_stored_selection_is_left_as_it_is(self):
        result = self.run_script("first-run-stored")
        self.assertEqual(result["selected"], ["ublock-filters", "adguard-cookies"])

    def run_script(self, scenario):
        import json
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "broadcast.js").write_text(
                "export function filteringBehaviorChanged() { globalThis.changed = (globalThis.changed || 0) + 1; }\n")
            (root / "assets.js").write_text(ASSETS)
            (root / "arx.js").write_text(content_blocking_overlay.ARX_SCRIPT)
            # Split instances each have their own globals; give each copy its own uBlock.
            for name in ["first", "second"]:
                (root / f"arx-{name}.js").write_text(
                    content_blocking_overlay.ARX_SCRIPT.replace("self.µBlock", f"globalThis.{name}UBlock"))
            (root / "run.mjs").write_text(HARNESS)
            output = subprocess.run(["node", str(root / "run.mjs"), scenario], check=True,
                                    capture_output=True, text=True, cwd=root).stdout
        return json.loads(output)


ORIGIN = "/^https:\\/\\/news\\.example\\//"

# uBlock's assets module: the list registry, with a remote source for itself or not.
ASSETS = r"""
globalThis.registry = globalThis.registry || [];
export default {
  async metadata() {
    globalThis.registry.push(['metadata']);
    return { 'assets.json': { content: 'internal', hasRemoteURL: globalThis.registryIsRemote === true } };
  },
  async registerAssetSource(key, details) { globalThis.registry.push(['register', key, details]); },
  addObserver(observer) { (globalThis.observers = globalThis.observers || []).push(observer); },
};
"""

HARNESS = r"""
const scenario = process.argv[2];
globalThis.self = globalThis;
const store = { };
const listeners = [];
const storage = {
  local: {
    get: async key => ({ [key]: store[key] === undefined ? undefined : structuredClone(store[key]) }),
    set: async values => {
      for (const [key, value] of Object.entries(values)) {
        const old = store[key];
        store[key] = structuredClone(value);
        for (const listener of listeners) listener({ [key]: { oldValue: old, newValue: value } }, 'local');
      }
    },
  },
  onChanged: { addListener: listener => listeners.push(listener) },
};
const tabs = new Set([5]);
// Tab 7 is one no extension script may run in.
const probes = [];
globalThis.chrome = {
  storage,
  tabs: {
    get: (id, callback) => setImmediate(() => callback(tabs.has(id) ? { id } : undefined)),
    query: (_, callback) => setImmediate(() => callback([...tabs].map(id => ({ id, url: 'https://secret.example/' })))),
    executeScript: (id, details, callback) => setImmediate(() => {
      probes.push([id, details.code]);
      chrome.runtime.lastError = id === 7 ? { message: 'Cannot access contents of the page.' } : undefined;
      callback();
      chrome.runtime.lastError = undefined;
    }),
  },
  runtime: { lastError: undefined },
  extension: { inIncognitoContext: false },
};
// The picker's diagnostics; stdout is the scenario's result.
console.info = () => {};
globalThis.setTimeout = fn => setImmediate(fn);
const settle = async () => { for (let i = 0; i < 40; i++) await new Promise(r => setImmediate(r)); };

const uBlock = (ready) => {
  const calls = [];
  let lines = ['dashboard.example'];
  return {
    calls,
    lines: () => lines,
    µb: {
      isReadyPromise: ready,
      selectedFilterLists: ['ublock-filters', 'fanboy-cookiemonster', 'easylist'],
      applyFilterListSelection(details) { calls.push(['select', details]); },
      loadFilterLists: async () => { calls.push(['load']); },
      netWhitelist: null,
      stringFromWhitelist() { return lines.join('\n'); },
      whitelistFromString(text) { lines = text.split('\n').filter(Boolean); return lines; },
      saveWhitelist() {},
    },
  };
};

if (scenario === 'phishing') {
  const instance = uBlock(Promise.resolve());
  instance.µb.selectedFilterLists = ['ublock-filters', 'easylist'];
  instance.µb.applyFilterListSelection = details => {
    instance.calls.push(['select', details]);
    instance.µb.selectedFilterLists = details.merge
      ? Array.from(new Set(instance.µb.selectedFilterLists.concat(details.toSelect)))
      : details.toSelect;
  };
  self.µBlock = instance.µb;
  await import('./arx.js');
  await settle();
  await storage.local.set({ arxContentBlocking: { cookieBanners: false, trustedSites: [], phishingList: true } });
  await settle();
  const calls = instance.calls.slice();
  // The person turns it off in the dashboard; Arx's settings change again.
  instance.µb.selectedFilterLists = ['ublock-filters', 'easylist'];
  instance.calls.length = 0;
  await storage.local.set({ arxContentBlocking: { cookieBanners: false, trustedSites: ['shop.example'], phishingList: true } });
  await settle();
  // A restart: a new instance starts from the stored marker.
  const restarted = uBlock(Promise.resolve());
  restarted.µb.selectedFilterLists = ['ublock-filters', 'easylist'];
  globalThis.secondUBlock = restarted.µb;
  await import('./arx-second.js');
  await settle();
  console.log(JSON.stringify({ calls, applied: { ...store.arxContentBlockingApplied, trustedSites: [] },
    later: instance.calls.concat(restarted.calls).filter(call => call[0] === 'select') }));
} else if (scenario.startsWith('first-run')) {
  // uBlock's own first start: no stored selection, so it picks its registry's defaults
  // (Helium's: the cookie notice lists on, the phishing list off). It's ready once its lists load.
  let ready;
  const instance = uBlock(new Promise(resolve => { ready = resolve; }));
  instance.µb.selectedFilterLists = [];
  instance.µb.applyFilterListSelection = details => { instance.calls.push(['select', details]); };
  instance.µb.autoSelectRegionalFilterLists = function(lists) {
    return ['user-filters', ...Object.keys(lists).filter(key => lists[key].off !== true)];
  };
  instance.µb.loadSelectedFilterLists = async function() {
    const bin = await storage.local.get('selectedFilterLists');
    if (Array.isArray(bin.selectedFilterLists)) { this.selectedFilterLists = bin.selectedFilterLists; return; }
    this.selectedFilterLists = this.autoSelectRegionalFilterLists({
      'ublock-filters': {}, 'adguard-cookies': {}, 'easylist': {}, 'fanboy-cookiemonster': {},
      'ublock-cookies-easylist': {}, 'curben-phishing': { off: true },
    });
    await storage.local.set({ selectedFilterLists: this.selectedFilterLists });
  };
  if (scenario === 'first-run-cookies') {
    store.arxContentBlocking = { cookieBanners: true, trustedSites: [], phishingList: true };
  } else if (scenario === 'first-run-stored') {
    store.selectedFilterLists = ['ublock-filters', 'adguard-cookies'];
  }
  self.µBlock = instance.µb;
  await import('./arx.js');
  // start.js reads the selection after arx.js has run.
  await instance.µb.loadSelectedFilterLists();
  ready();
  await settle();
  // The profile's first page: the browser writes Arx's settings.
  await storage.local.set({ arxContentBlocking: { cookieBanners: scenario === 'first-run-cookies',
    trustedSites: [], phishingList: true } });
  await settle();
  console.log(JSON.stringify({ selected: instance.µb.selectedFilterLists, calls: instance.calls,
    applied: store.arxContentBlockingApplied }));
} else if (scenario === 'single') {
  const instance = uBlock(Promise.resolve());
  self.µBlock = instance.µb;
  await import('./arx.js');
  await settle();
  const whitelist = [];
  await storage.local.set({ arxContentBlocking: { cookieBanners: true,
    trustedSites: ['/^https:\\/\\/news\\.example\\//', 'bad host', '/.*/', 'shop.example', '[::1]'] } });
  await settle(); whitelist.push(instance.lines());
  await storage.local.set({ arxContentBlocking: { cookieBanners: true, trustedSites: ['shop.example'] } });
  await settle(); whitelist.push(instance.lines());
  await storage.local.set({ arxContentBlocking: { cookieBanners: false, trustedSites: [] } });
  await settle(); whitelist.push(instance.lines());
  console.log(JSON.stringify({ calls: instance.calls, whitelist,
    applied: store.arxContentBlockingApplied, changed: globalThis.changed || 0 }));
} else if (scenario === 'owned') {
  const instance = uBlock(Promise.resolve());
  self.µBlock = instance.µb;
  await import('./arx.js');
  await settle();
  const whitelist = [];
  await storage.local.set({ arxContentBlocking: { cookieBanners: false, trustedSites: ['dashboard.example'] } });
  await settle(); whitelist.push(instance.lines());
  await storage.local.set({ arxContentBlocking: { cookieBanners: false, trustedSites: [] } });
  await settle(); whitelist.push(instance.lines());
  console.log(JSON.stringify({ whitelist, applied: store.arxContentBlockingApplied }));
} else if (scenario === 'split-owned') {
  // Instance two starts (and snapshots the marker) before instance one adds a
  // site, but its whitelist loads from storage after that, so it finds the site.
  const first = uBlock(Promise.resolve());
  let release;
  const second = uBlock(new Promise(resolve => { release = resolve; }));
  globalThis.firstUBlock = first.µb;
  await import('./arx-first.js');
  globalThis.secondUBlock = second.µb;
  await import('./arx-second.js');
  await settle();
  await storage.local.set({ arxContentBlocking: { cookieBanners: false, trustedSites: ['news.example'] } });
  await settle();
  second.µb.whitelistFromString(first.lines().join('\n'));
  release();
  await settle();
  await storage.local.set({ arxContentBlocking: { cookieBanners: false, trustedSites: [] } });
  await settle();
  console.log(JSON.stringify({ whitelists: [first.lines(), second.lines()] }));
} else if (scenario === 'registry' || scenario === 'registry-remote') {
  globalThis.registryIsRemote = scenario === 'registry-remote';
  let release;
  const instance = uBlock(new Promise(resolve => { release = resolve; }));
  self.µBlock = instance.µb;
  await import('./arx.js');
  await settle();
  const before = (globalThis.registry || []).slice();
  release();
  await settle();
  console.log(JSON.stringify({ before, after: globalThis.registry || [] }));
} else if (scenario === 'migration') {
  // uBlock replaces Helium's registry with upstream's. Its own observer, added
  // after arx.js's, drops the cookie lists upstream has off by default.
  const instance = uBlock(Promise.resolve());
  instance.µb.selectedFilterLists = ['ublock-filters', 'fanboy-cookiemonster', 'easylist', 'ublock-cookies-easylist'];
  self.µBlock = instance.µb;
  await import('./arx.js');
  await settle();
  globalThis.observers.push(topic => {
    if (topic !== 'assets.json-updated') return;
    instance.µb.selectedFilterLists = ['ublock-filters', 'easylist'];
  });
  for (const observer of globalThis.observers) observer('assets.json-updated', {});
  await settle();
  console.log(JSON.stringify({ calls: instance.calls }));
} else if (scenario === 'migration-opt-out') {
  // A cookie banner opt-out is queued when the registry changes: it wins.
  const instance = uBlock(Promise.resolve());
  instance.µb.selectedFilterLists = ['ublock-filters', 'fanboy-cookiemonster', 'easylist', 'ublock-cookies-easylist'];
  self.µBlock = instance.µb;
  store.arxContentBlockingApplied = { cookieBanners: true, trustedSites: [] };
  store.arxContentBlocking = { cookieBanners: true, trustedSites: [] };
  await import('./arx.js');
  await settle();
  instance.µb.applyFilterListSelection = details => {
    instance.calls.push(['select', details]);
    instance.µb.selectedFilterLists = details.merge
      ? [...new Set([...instance.µb.selectedFilterLists, ...details.toSelect])] : details.toSelect;
  };
  globalThis.observers.push(topic => {
    if (topic !== 'assets.json-updated') return;
    instance.µb.selectedFilterLists = ['ublock-filters', 'easylist'];
  });
  storage.local.set({ arxContentBlocking: { cookieBanners: false, trustedSites: [] } });
  for (const observer of globalThis.observers) observer('assets.json-updated', {});
  await settle();
  console.log(JSON.stringify({ calls: instance.calls, selected: instance.µb.selectedFilterLists }));
} else if (scenario === 'hide') {
  // DEV-1019: My filters, as the picker and the dashboard write them.
  const instance = uBlock(Promise.resolve());
  let content = [
    'example.com##.ad', '! a comment', 'news.example,shop.example##.banner',
    '~other.example##.x', '*##.everywhere', 'example.*##.entity', 'example.com##+js(noop)',
    'example.com#@#.allowed', '||ads.example^', 'example.com##div[data-x="1"]', 'example.com##.ad',
    'example.com,~news.example.com##.excluded', 'constructor##.banner', 'bücher.example##.ad',
  ].join('\n');
  const picked = [];
  let saves = 0;
  // uBlock's own reload, which the scenario can hold to stand for one already running.
  let loadImpl = async () => { instance.calls.push(['load']); };
  instance.µb.loadFilterLists = (...args) => loadImpl(...args);
  instance.µb.loadUserFilters = async () => ({ content });
  let onSave = () => {};
  instance.µb.saveUserFilters = async text => { saves += 1; content = text; onSave(); };
  instance.µb.epickerArgs = { mouse: true };
  instance.µb.elementPickerExec = async (tabId, frameId) => { picked.push([tabId, frameId]); };
  self.µBlock = instance.µb;
  await import('./arx.js');
  await settle();
  const listed = structuredClone(store.arxHiddenElements);
  await storage.local.set({ arxElementPicker: { tabId: 5, request: 1 } });
  await settle();
  const pickerStatuses = [structuredClone(store.arxElementPickerStatus)];
  await storage.local.set({ arxElementPicker: { tabId: 9, request: 2 } });
  await settle();
  pickerStatuses.push(structuredClone(store.arxElementPickerStatus));
  tabs.add(7);
  await storage.local.set({ arxElementPicker: { tabId: 7, request: 3 } });
  await settle();
  pickerStatuses.push(structuredClone(store.arxElementPickerStatus));
  tabs.delete(7);
  picked.splice(1);
  const mouse = instance.µb.epickerArgs.mouse;
  let listedBeforeLoad;
  loadImpl = async () => {
    listedBeforeLoad ??= structuredClone(store.arxHiddenElements);
    instance.calls.push(['load']);
  };
  await storage.local.set({ arxShowHiddenElement: { filter: 'example.com##.ad', request: 3 } });
  await settle();
  const saved = content;
  const loads = instance.calls.filter(call => call[0] === 'load').length;
  const after = structuredClone(store.arxHiddenElements);
  const savesBefore = saves;
  await storage.local.set({ arxShowHiddenElement: { filter: 'missing.example##.gone', request: 4 } });
  await settle();
  const savesForMissing = saves - savesBefore;
  const loadsForMissing = instance.calls.filter(call => call[0] === 'load').length - loads;

  // The dashboard adds a line, which the list shows, then starts a reload that's still
  // running when Show saves.
  await self.µBlock.saveUserFilters(content + '\nexample.com##.late');
  await settle();
  const inFlight = [];
  onSave = () => inFlight.push('saved');
  let finishStale;
  const stale = new Promise(resolve => { finishStale = resolve; });
  loadImpl = () => stale.then(() => { inFlight.push('stale load done'); });
  const dashboard = self.µBlock.loadFilterLists();
  loadImpl = async () => { inFlight.push('fresh load'); };
  await storage.local.set({ arxShowHiddenElement: { filter: 'example.com##.late', request: 5 } });
  await settle();
  const before = JSON.stringify(store.arxHiddenElements);
  finishStale();
  await dashboard;
  await settle();
  if (JSON.stringify(store.arxHiddenElements) !== before) inFlight.push('listed');

  // The extensions smoke's filters go after My filters' own, once each, and reload them.
  onSave = () => {};
  loadImpl = async () => { instance.calls.push(['load']); };
  const savesBeforeFixture = saves;
  const loadsBeforeFixture = instance.calls.filter(call => call[0] === 'load').length;
  await storage.local.set({ arxFixtureFilters: { request: 6, filters: [
    '127.0.0.1##.arx-hide-target', ' 127.0.0.1##+js(noop) ', 'example.com##div[data-x="1"]', 7, '',
  ] } });
  await settle();
  const fixtureContent = content;
  await storage.local.set({ arxFixtureFilters: { request: 7, filters: ['127.0.0.1##.arx-hide-target'] } });
  await settle();
  const fixture = {
    lines: fixtureContent.split('\n').slice(-2),
    duplicates: fixtureContent.split('\n').filter(line => line === 'example.com##div[data-x="1"]').length,
    saves: saves - savesBeforeFixture,
    loads: instance.calls.filter(call => call[0] === 'load').length - loadsBeforeFixture,
    unchangedByRepeat: content === fixtureContent,
    listed: store.arxHiddenElements['127.0.0.1'],
  };

  // Arx's own picker's line (DEV-1201) goes in once, and the filters reload.
  const savesBeforePick = saves;
  const loadsBeforePick = instance.calls.filter(call => call[0] === 'load').length;
  await storage.local.set({ arxHideElement: { request: 8, filter: ' news.example##aside.promo ' } });
  await settle();
  const pickedContent = content;
  await storage.local.set({ arxHideElement: { request: 9, filter: 'news.example##aside.promo' } });
  await settle();
  await storage.local.set({ arxHideElement: { request: 10, filter: 7 } });
  await settle();
  const ownPicker = {
    last: pickedContent.split('\n').slice(-1)[0],
    saves: saves - savesBeforePick,
    loads: instance.calls.filter(call => call[0] === 'load').length - loadsBeforePick,
    unchangedByRepeat: content === pickedContent,
    listed: store.arxHiddenElements['news.example'],
  };
  console.log(JSON.stringify({ listed, picked, mouse, saved, loads, after, listedBeforeLoad, inFlight,
    savesForMissing, loadsForMissing, pickerStatuses, probes, fixture, ownPicker }));
} else if (scenario === 'upgrade') {
  const instance = uBlock(Promise.resolve());
  instance.µb.selectedFilterLists = ['ublock-filters', 'adguard-cookies', 'easylist', 'ublock-cookies-easylist'];
  self.µBlock = instance.µb;
  store.arxContentBlocking = { cookieBanners: false, trustedSites: [] };
  await import('./arx.js');
  await settle();
  console.log(JSON.stringify({ calls: instance.calls }));
} else {
  const first = uBlock(Promise.resolve());
  let release;
  const second = uBlock(new Promise(resolve => { release = resolve; }));
  globalThis.firstUBlock = first.µb;
  await import('./arx-first.js');
  globalThis.secondUBlock = second.µb;
  await import('./arx-second.js');
  await settle();
  // Both instances are running; the first applies the change and stores the
  // marker before the second is ready.
  await storage.local.set({ arxContentBlocking: { cookieBanners: true, trustedSites: [] } });
  await settle();
  release();
  await settle();
  const loads = [first, second].map(instance => instance.calls.filter(call => call[0] === 'load').length);
  console.log(JSON.stringify({ loads }));
}
"""

if __name__ == "__main__":
    unittest.main()
