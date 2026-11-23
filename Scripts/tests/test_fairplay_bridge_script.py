"""The FairPlay bridge script (DEV-1144) under node, with a stand-in DOM: what the page hears."""

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from Scripts.core.paths import ROOT

SCRIPT = ROOT / "Packages/services/Sources/FairPlayBridge/Resources/FairPlayBridge.js"


@unittest.skipUnless(shutil.which("node"), "needs node")
class FairPlayBridgeScriptTests(unittest.TestCase):
    def run_scenario(self, scenario):
        with tempfile.TemporaryDirectory() as directory:
            harness = Path(directory) / "run.js"
            harness.write_text(HARNESS)
            output = subprocess.run(["node", str(harness), str(SCRIPT), scenario], check=True,
                                    capture_output=True, text=True, cwd=directory).stdout
        return json.loads(output)

    def test_an_element_playing_an_ad_goes_quiet_when_the_bridge_takes_it(self):
        # DEV-1158: the ad's own player stops, and the page hears no pause, error or emptying.
        result = self.run_scenario("ad")
        self.assertEqual(result["adHeard"], [["play", True], ["playing", True]])
        self.assertTrue(result["nativePausedAfterTakeover"])
        self.assertEqual(result["heardAtTakeover"], [])
        self.assertEqual(result["pausedReads"], True)
        self.assertEqual(result["loads"], 1)
        # The page's play reaches the helper; the element's own player stays stopped.
        self.assertEqual(result["heardOnPlay"], [["play", False]])
        self.assertEqual(result["nativePlays"], 1)
        self.assertTrue(result["nativePausedAfterPlay"])
        self.assertIn("play", result["ops"])

    def test_an_element_outside_the_document_goes_quiet_too(self):
        result = self.run_scenario("detached")
        self.assertTrue(result["nativePausedAfterTakeover"])
        self.assertEqual(result["heardAtTakeover"], [])

    def test_an_element_outside_the_document_is_quiet_before_the_page_s_capture_listeners(self):
        # The page's capture listeners on the element run before its other listeners, so the
        # bridge's must come first among them.
        result = self.run_scenario("detached-capture")
        self.assertTrue(result["nativePausedAfterTakeover"])
        self.assertEqual(result["heardAtTakeover"], [])
        self.assertEqual(result["heardOnPlay"], [["play", False]])

    def test_an_element_in_a_detached_tree_is_quiet_before_its_ancestor_s_capture_listeners(self):
        result = self.run_scenario("detached-parent")
        self.assertEqual(result["adHeard"], [["parent play", True], ["parent playing", True]])
        self.assertTrue(result["nativePausedAfterTakeover"])
        self.assertEqual(result["heardAtTakeover"], [])
        self.assertEqual(result["heardOnPlay"], [["parent play", False]])

    def test_a_source_set_before_it_joins_a_new_player_goes_to_that_player(self):
        # Spotify makes a new player for a protected track and sets its <source>'s playlist before
        # appending it: the keys went to the old player, yet the new one is the bridge's.
        result = self.run_scenario("recreated")
        self.assertEqual(result["loads"], 1)
        self.assertIn(["encrypted", False], result["heardPlayer"])
        self.assertEqual(result["heardOld"], [])
        # The new player reads the keys it adopted, as a licence request through it needs.
        self.assertTrue(result["playerHasKeys"])
        self.assertIn("play", result["ops"])
        self.assertNotIn("failed", result["ops"])

    def test_a_source_set_before_it_joins_the_keyed_player_goes_to_it(self):
        result = self.run_scenario("source")
        self.assertEqual(result["loads"], 1)
        self.assertIn(["encrypted", False], result["heardPlayer"])
        self.assertTrue(result["nativeSourceEmpty"])

    def test_a_source_put_in_a_player_starts_its_track_without_load_or_play(self):
        # A player that waits for `encrypted` before it plays: insertion alone starts the track.
        result = self.run_scenario("inserted")
        self.assertEqual(result["loads"], 1)
        self.assertIn(["encrypted", False], result["heardPlayer"])

    def test_a_source_put_in_by_replace_children_starts_its_track(self):
        result = self.run_scenario("replacedChildren")
        self.assertEqual(result["loads"], 1)
        self.assertIn(["encrypted", False], result["heardPlayer"])

    def test_a_source_put_in_by_replace_with_starts_its_track(self):
        result = self.run_scenario("replacedWith")
        self.assertEqual(result["loads"], 1)
        self.assertIn(["encrypted", False], result["heardPlayer"])

    def test_a_source_replacing_a_comment_placeholder_starts_its_track(self):
        result = self.run_scenario("placeholder")
        self.assertEqual(result["loads"], 1)
        self.assertIn(["encrypted", False], result["heardPlayer"])

    def test_a_source_put_in_by_an_unwatched_call_starts_on_the_next_task(self):
        result = self.run_scenario("unwatched")
        self.assertEqual(result["loads"], 1)
        self.assertIn(["encrypted", False], result["heardPlayer"])

    def test_a_source_put_in_later_by_an_unwatched_call_starts_too(self):
        result = self.run_scenario("later")
        self.assertEqual(result["loads"], 1)
        self.assertIn(["encrypted", False], result["heardPlayer"])

    def test_a_source_whose_src_was_removed_loads_nothing(self):
        result = self.run_scenario("removed")
        self.assertEqual(result["loads"], 0)

    def test_a_bridged_player_takes_the_next_tracks_source(self):
        result = self.run_scenario("replaced")
        self.assertEqual(result["loads"], 2)

    def test_a_clear_playlist_on_a_source_stays_chromiums(self):
        result = self.run_scenario("clear")
        self.assertEqual(result["loads"], 0)
        self.assertTrue(result["sourceKept"])
        self.assertNotIn("failed", result["ops"])

    def test_a_fairplay_playlist_without_fairplay_keys_falls_back(self):
        # Neither Arx nor Chromium can play it: the app hears the page gave up and moves the tab.
        result = self.run_scenario("unkeyed")
        self.assertEqual(result["loads"], 0)
        self.assertEqual(result["ops"].count("failed"), 1)

    def test_an_idle_element_is_taken_over_without_touching_its_player(self):
        result = self.run_scenario("idle")
        self.assertEqual(result["nativePauses"], 0)
        self.assertEqual(result["heardAtTakeover"], [])
        self.assertEqual(result["loads"], 1)

    def test_an_element_that_leaves_the_bridge_is_heard_again(self):
        result = self.run_scenario("ad")
        self.assertEqual(result["heardAfterLeaving"][0], ["emptied", False])
        self.assertIn(["loadstart", True], result["heardAfterLeaving"])
        self.assertIn("stop", result["ops"])


# A stand-in DOM: window capture listeners, then its ancestors' capture listeners from the root
# down, then the target's capture and other listeners, then its `on…` handler. The element's own player queues trusted events as Chromium's does.
HARNESS = r"""
const fs = require("fs");
const [source, scenario] = [fs.readFileSync(process.argv[2], "utf8"), process.argv[3]];

const TRUSTED = Symbol("trusted");
class Event {
  constructor(type) { this.type = type; this.target = null; this.stopped = false; this[TRUSTED] = false; }
  get isTrusted() { return this[TRUSTED]; }
  stopImmediatePropagation() { this.stopped = true; }
  stopPropagation() { this.stopped = true; }
}
class EventTarget {
  constructor() { this.listeners = []; }
  addEventListener(type, listener, options) {
    const capture = typeof options === "boolean" ? options : !!(options && options.capture);
    if (!this.listeners.some((entry) => entry.type === type && entry.listener === listener && entry.capture === capture)) {
      this.listeners.push({ type, listener, capture });
    }
  }
  removeEventListener(type, listener) { this.listeners = this.listeners.filter((entry) => entry.type !== type || entry.listener !== listener); }
  invoke(event, capture) {
    for (const entry of this.listeners.slice()) {
      if (entry.type !== event.type || entry.capture !== capture) continue;
      entry.listener.call(this, event);
      if (event.stopped) return false;
    }
    return true;
  }
  dispatchEvent(event) {
    event.target = this;
    if (this.isConnected && !win.invoke(event, true)) return true;
    const ancestors = [];
    for (let parent = this.parentElement; parent; parent = parent.parentElement) ancestors.unshift(parent);
    for (const parent of ancestors) if (!parent.invoke(event, true)) return true;
    if (!this.invoke(event, true) || !this.invoke(event, false)) return true;
    const handler = this instanceof Element ? this["on" + event.type] : null;
    if (typeof handler === "function") handler.call(this, event);
    return true;
  }
}
const win = new EventTarget();

class Node extends EventTarget {
  constructor() { super(); this.parentElement = null; this.children = []; }
  // Each insertion is its own native call, as in the DOM: wrapping one doesn't cover the others.
  adopt(child) { child.parentElement = this; this.children.push(child); return child; }
  appendChild(child) { return this.adopt(child); }
  insertBefore(child) { return this.adopt(child); }
  replaceChild(child, old) { this.children = this.children.filter((node) => node !== old); return this.adopt(child); }
}
class CharacterData extends Node {
  replaceWith(node) {
    const parent = this.parentElement;
    parent.children = parent.children.filter((child) => child !== this);
    this.parentElement = null;
    parent.adopt(node);
  }
}
class Element extends Node {
  constructor() { super(); this.attributes = new Map(); this.isConnected = false; }
  append(...nodes) { for (const node of nodes) this.adopt(node); }
  replaceChildren(...nodes) { this.children = []; for (const node of nodes) this.adopt(node); }
  replaceWith(node) {
    const parent = this.parentElement;
    parent.children = parent.children.filter((child) => child !== this);
    this.parentElement = null;
    parent.adopt(node);
  }
  setAttribute(name, value) { this.attributes.set(String(name).toLowerCase(), String(value)); if (String(name).toLowerCase() === "src" && this.sourceChanged) this.sourceChanged(String(value)); }
  removeAttribute(name) { this.attributes.delete(String(name).toLowerCase()); if (String(name).toLowerCase() === "src" && this.sourceChanged) this.sourceChanged(""); }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
}

const nativeCalls = { play: 0, pause: 0 };
class HTMLMediaElement extends Element {
  constructor() { super(); this.own = { src: "", paused: true, volume: 1, muted: false, time: 0 }; this.sourceChanged = (value) => this.loadSource(value); }
  queue(type) { setTimeout(() => { const event = new Event(type); event[TRUSTED] = true; this.dispatchEvent(event); }, 0); }
  loadSource(value) {
    if (this.own.src) { this.queue("abort"); this.queue("emptied"); }
    this.own.paused = true;
    this.own.src = value;
    if (value) this.queue("loadstart");
  }
  get src() { return this.own.src; }
  set src(value) { this.loadSource(String(value)); }
  get srcObject() { return null; }
  set srcObject(value) { this.loadSource(""); }
  get paused() { return this.own.paused; }
  get ended() { return false; }
  get error() { return null; }
  get readyState() { return this.own.src ? 4 : 0; }
  get networkState() { return this.own.src ? 1 : 0; }
  get duration() { return NaN; }
  get buffered() { return { length: 0 }; }
  get seekable() { return { length: 0 }; }
  get currentTime() { return this.own.time; }
  set currentTime(value) { this.own.time = +value; }
  get volume() { return this.own.volume; }
  set volume(value) { this.own.volume = +value; this.queue("volumechange"); }
  get muted() { return this.own.muted; }
  set muted(value) { this.own.muted = !!value; this.queue("volumechange"); }
  get mediaKeys() { return null; }
  setMediaKeys() { return Promise.resolve(); }
  play() { nativeCalls.play++; if (this.own.paused) { this.own.paused = false; this.queue("play"); this.queue("playing"); } return Promise.resolve(); }
  pause() { nativeCalls.pause++; if (!this.own.paused) { this.own.paused = true; this.queue("timeupdate"); this.queue("pause"); } }
  load() { this.loadSource(this.own.src); }
}
class HTMLSourceElement extends Element {
  get src() { return this.getAttribute("src") || ""; }
  set src(value) { this.attributes.set("src", String(value)); }
}
class MediaSession { constructor() { this.stored = null; } setActionHandler() {} get metadata() { return this.stored; } set metadata(value) { this.stored = value; } }
class Navigator {
  requestMediaKeySystemAccess() { return Promise.reject(new DOMException("Unsupported", "NotSupportedError")); }
}
const navigator = new Navigator();
navigator.mediaSession = new MediaSession();
navigator.userActivation = { hasBeenActive: true };

for (const [name, value] of Object.entries({ Event, EventTarget, Node, CharacterData, Element, HTMLMediaElement, HTMLSourceElement, Navigator, navigator })) {
  Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
}
globalThis.addEventListener = (...args) => win.addEventListener(...args);

const sent = [];
(0, eval)(source)((text) => sent.push(JSON.parse(text)));

const flush = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const PLAYLIST = "data:application/vnd.apple.mpegurl;base64," +
  btoa('#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://track"\n#EXTINF:10,\nhttps://cdn.example/1.ts\n');

async function keyed(element) {
  const access = await navigator.requestMediaKeySystemAccess("com.apple.fps.1_0", [{}]);
  const keys = await access.createMediaKeys();
  await keys.setServerCertificate(new Uint8Array([1, 2, 3]));
  await element.setMediaKeys(keys);
}

const HEARD = ["play", "playing", "pause", "timeupdate", "emptied", "abort", "error", "ended", "loadstart"];
function listened(element, heard) {
  // The page's listeners: on its parent with capture, or on the element, with capture or not.
  if (scenario === "detached-parent") {
    for (const type of HEARD) element.parentElement.addEventListener(type, (event) => heard.push(["parent " + type, event.isTrusted]), { capture: true });
    return;
  }
  const capture = scenario === "detached-capture";
  for (const type of HEARD) {
    element.addEventListener(type, (event) => heard.push([type, event.isTrusted]), { capture });
  }
  element.onpause = (event) => heard.push(["onpause", event.isTrusted]);
  win.addEventListener("pause", (event) => heard.push(["window pause", event.isTrusted]), true);
}

const SCENARIOS = {
  // The keys go to the page's old player; it plays the track in a new one, through a <source>.
  async recreated() {
    const old = new HTMLMediaElement();
    old.isConnected = true;
    await keyed(old);
    const player = new HTMLMediaElement();
    player.isConnected = true;
    const [heardOld, heardPlayer] = [[], []];
    old.addEventListener("encrypted", (event) => heardOld.push(["encrypted", event.isTrusted]));
    player.addEventListener("encrypted", (event) => heardPlayer.push(["encrypted", event.isTrusted]));
    const source = new HTMLSourceElement();
    source.src = PLAYLIST;
    player.appendChild(source);
    player.load();
    await flush(150);
    await player.play();
    await flush(10);
    return { heardOld, heardPlayer, playerHasKeys: player.mediaKeys !== null };
  },
  // The usual order: keys, then a <source> set before it's appended to the keyed player.
  async source() {
    const player = new HTMLMediaElement();
    player.isConnected = true;
    await keyed(player);
    const heardPlayer = [];
    player.addEventListener("encrypted", (event) => heardPlayer.push(["encrypted", event.isTrusted]));
    const source = new HTMLSourceElement();
    source.src = PLAYLIST;
    player.appendChild(source);
    player.load();
    await flush(150);
    return { heardPlayer, nativeSourceEmpty: source.getAttribute("src") === null && player.own.src === "" };
  },
  // A player that waits for `encrypted` once its <source> is in: no load() or play().
  async inserted() {
    const player = new HTMLMediaElement();
    player.isConnected = true;
    await keyed(player);
    const heardPlayer = [];
    player.addEventListener("encrypted", (event) => heardPlayer.push(["encrypted", event.isTrusted]));
    const source = new HTMLSourceElement();
    source.src = PLAYLIST;
    player.append(source);
    await flush(150);
    return { heardPlayer };
  },
  // A <source> put in with replaceChildren, then nothing: the player waits for `encrypted`.
  async replacedChildren() {
    const player = new HTMLMediaElement();
    player.isConnected = true;
    await keyed(player);
    const heardPlayer = [];
    player.addEventListener("encrypted", (event) => heardPlayer.push(["encrypted", event.isTrusted]));
    const source = new HTMLSourceElement();
    source.src = PLAYLIST;
    player.replaceChildren(source);
    await flush(150);
    return { heardPlayer };
  },
  // A prepared <source> replaces the player's current one through replaceWith, then nothing.
  async replacedWith() {
    const player = new HTMLMediaElement();
    player.isConnected = true;
    await keyed(player);
    const heardPlayer = [];
    player.addEventListener("encrypted", (event) => heardPlayer.push(["encrypted", event.isTrusted]));
    const current = new HTMLSourceElement();
    player.adopt(current);
    const source = new HTMLSourceElement();
    source.src = PLAYLIST;
    current.replaceWith(source);
    await flush(150);
    return { heardPlayer };
  },
  // A prepared <source> replaces a comment placeholder in the player.
  async placeholder() {
    const player = new HTMLMediaElement();
    player.isConnected = true;
    await keyed(player);
    const heardPlayer = [];
    player.addEventListener("encrypted", (event) => heardPlayer.push(["encrypted", event.isTrusted]));
    const comment = new CharacterData();
    player.adopt(comment);
    const source = new HTMLSourceElement();
    source.src = PLAYLIST;
    comment.replaceWith(source);
    await flush(150);
    return { heardPlayer };
  },
  // A prepared <source> put in by a call the bridge doesn't wrap (here the stand-in's own adopt).
  async unwatched() {
    const player = new HTMLMediaElement();
    player.isConnected = true;
    await keyed(player);
    const heardPlayer = [];
    player.addEventListener("encrypted", (event) => heardPlayer.push(["encrypted", event.isTrusted]));
    const source = new HTMLSourceElement();
    source.src = PLAYLIST;
    player.adopt(source);
    await flush(150);
    return { heardPlayer };
  },
  // A prepared <source> put in a moment later by a call the bridge doesn't wrap.
  async later() {
    const player = new HTMLMediaElement();
    player.isConnected = true;
    await keyed(player);
    const heardPlayer = [];
    player.addEventListener("encrypted", (event) => heardPlayer.push(["encrypted", event.isTrusted]));
    const source = new HTMLSourceElement();
    source.src = PLAYLIST;
    await flush(400);
    player.adopt(source);
    await flush(600);
    return { heardPlayer };
  },
  // A <source> prepared, then its src removed before it goes in.
  async removed() {
    const source = new HTMLSourceElement();
    source.src = PLAYLIST;
    source.removeAttribute("src");
    const player = new HTMLMediaElement();
    player.isConnected = true;
    await keyed(player);
    player.appendChild(source);
    player.load();
    await flush(150);
    return {};
  },
  // The next track in the same bridged player, through a new <source>.
  async replaced() {
    const player = new HTMLMediaElement();
    player.isConnected = true;
    await keyed(player);
    for (let index = 0; index < 2; index++) {
      const source = new HTMLSourceElement();
      source.src = PLAYLIST;
      player.appendChild(source);
      player.load();
      await flush(150);
    }
    return {};
  },
  // A clear HLS playlist (no FairPlay key) on a <source>: Chromium's, untouched.
  async clear() {
    const player = new HTMLMediaElement();
    player.isConnected = true;
    await keyed(player);
    const clear = "data:application/vnd.apple.mpegurl;base64," + btoa("#EXTM3U\n#EXTINF:10,\nhttps://cdn.example/1.ts\n");
    const source = new HTMLSourceElement();
    source.src = clear;
    player.appendChild(source);
    player.load();
    await flush(150);
    return { sourceKept: source.getAttribute("src") === clear };
  },
  // A FairPlay playlist from a page that never asked for FairPlay keys.
  async unkeyed() {
    const player = new HTMLMediaElement();
    player.isConnected = true;
    player.src = PLAYLIST;
    await flush(150);
    return {};
  },
};

(async () => {
  if (SCENARIOS[scenario]) {
    const result = await SCENARIOS[scenario]();
    result.loads = sent.filter((message) => message.op === "load").length;
    result.ops = sent.map((message) => message.op);
    process.stdout.write(JSON.stringify(result));
    process.exit(0);
  }
  const result = {};
  const element = new HTMLMediaElement();
  element.isConnected = !scenario.startsWith("detached");
  if (scenario === "detached-parent") element.parentElement = new Element();
  const heard = [];
  listened(element, heard);
  if (scenario !== "idle") {
    // An ordinary source plays, such as an ad.
    element.src = "https://ads.example/ad.mp4";
    await element.play();
    await flush(10);
    result.adHeard = heard.splice(0).filter(([type]) => !type.endsWith("loadstart"));
  }
  await keyed(element);
  element.src = PLAYLIST;
  await flush(150);
  result.nativePausedAfterTakeover = element.own.paused;
  result.nativePauses = nativeCalls.pause;
  result.heardAtTakeover = heard.splice(0);
  result.pausedReads = element.paused;
  result.loads = sent.filter((message) => message.op === "load").length;

  await element.play();
  await flush(10);
  result.heardOnPlay = heard.splice(0);
  result.nativePlays = nativeCalls.play;
  result.nativePausedAfterPlay = element.own.paused;

  element.src = "https://ads.example/next.mp4";
  await flush(10);
  result.heardAfterLeaving = heard.splice(0);
  result.ops = sent.map((message) => message.op);
  process.stdout.write(JSON.stringify(result));
  process.exit(0);
})().catch((error) => { console.error(error); process.exit(1); });
"""
