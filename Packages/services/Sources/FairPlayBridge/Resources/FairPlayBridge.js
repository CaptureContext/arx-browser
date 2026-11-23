// Arx's FairPlay bridge (DEV-1144). Runs in the main world of a FairPlay site's top-level page at
// document start, through the engine's page media bridge, which calls this function with `send`
// and keeps the function it returns for the app's messages.
//
// The page is offered FairPlay (`com.apple.fps.1_0`) while Widevine and PlayReady are refused, so
// a player that prefers them falls back to FairPlay as it does in Safari. When the page hands its
// media element an HLS playlist with an `skd://` key as a `data:` URL, the element is taken over:
// the playlist and the page's certificate go to the app, Arx's FairPlay helper plays the stream,
// its key requests come back as the page's `license-request` messages, and the page's own code
// exchanges them with its licence server. The element reports the helper's state, and the page's
// controls, media session and media keys drive it. Chromium never sees the protected media.
(function (send) {
  "use strict";

  const KEY_SYSTEM = "com.apple.fps.1_0";
  const OTHER_PROTECTED_SYSTEMS = /^com\.(?:widevine|microsoft\.playready)(?:\.|$)/;
  const PLAYLIST_URL = /^data:application\/(?:vnd\.apple\.mpegurl|x-mpegurl)((?:;[^,]*)?),/i;
  const PLAYLIST_PART = 30000;
  // FairPlayLimits: the most parts, and the longest part, the app takes.
  const MAX_PARTS = 40;
  const MAX_PART_CHARACTERS = 50000;
  const ENCRYPTED_DELAY_MS = 100;
  const SEEK_GIVE_UP_MS = 2000;
  const TICK_MS = 250;
  const READY_GIVE_UP_MS = 45000;
  const PENDING_CHECK_MS = 250;

  const { apply } = Reflect;
  const { defineProperty, getOwnPropertyDescriptor } = Object;
  const Media = HTMLMediaElement.prototype;
  const nativePause = Media.pause;
  const listen = EventTarget.prototype.addEventListener;
  const stopEvent = Event.prototype.stopImmediatePropagation;
  const clock = performance;
  const clockNow = clock.now;
  const now = () => apply(clockNow, clock, []);
  const encoder = new TextEncoder();

  const post = (message) => {
    try {
      send(JSON.stringify(message));
    } catch (error) {}
  };
  // A step of the page's playback, for the app's diagnostics log (FairPlayTrace): only these
  // names cross, each at most a few times a page.
  const traced = new Map();
  const trace = (step) => {
    const count = traced.get(step) || 0;
    if (count >= 8) return;
    traced.set(step, count + 1);
    post({ op: "trace", trace: step });
  };
  trace("installed");
  const guard = (body) =>
    function (...args) {
      try {
        return apply(body, this, args);
      } catch (error) {
        return undefined;
      }
    };
  // A replacement that reads as the original: its name, length and source text stay native.
  const native = (original, body) => new Proxy(original, { apply: (target, self, args) => body(target, self, args) });
  const fire = (element, type) => element.dispatchEvent(new Event(type));

  const bytesOf = (value) =>
    value instanceof ArrayBuffer
      ? new Uint8Array(value)
      : ArrayBuffer.isView(value)
        ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
        : new Uint8Array(0);
  const toBase64 = (bytes) => {
    let text = "";
    for (let index = 0; index < bytes.length; index += 0x8000) text += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
    return btoa(text);
  };
  const fromBase64 = (text) => {
    const binary = atob(text);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
    return bytes;
  };

  // MARK: - Media session

  const session = navigator.mediaSession;
  const actions = new Map();
  const SessionProto = session && Object.getPrototypeOf(session);
  if (SessionProto && typeof SessionProto.setActionHandler === "function") {
    SessionProto.setActionHandler = native(SessionProto.setActionHandler, (target, self, args) => {
      if (typeof args[1] === "function") actions.set(String(args[0]), args[1]);
      else actions.delete(String(args[0]));
      return apply(target, self, args);
    });
  }
  const artworkOf = (metadata) => {
    let best = "";
    let bestSize = -1;
    for (const image of (metadata && metadata.artwork) || []) {
      const source = image && String(image.src || "");
      if (!/^https:\/\//i.test(source)) continue;
      const size = Math.max(0, ...String(image.sizes || "").split(/\s+/).map((entry) => parseInt(entry, 10) || 0));
      if (size > bestSize) {
        best = source;
        bestSize = size;
      }
    }
    return best;
  };

  // MARK: - Keys

  let certificate = "";
  let generation = 0;
  let media = null;
  let pendingSession = null;
  let pendingRequest = null;
  // The FairPlay keys the page made last: an element given a FairPlay playlist without them, such
  // as a player the page made anew for the track, is taken over with these.
  let pageKeys = null;
  let gaveUp = false;
  let ticker = 0;
  const tracks = new WeakMap();
  const quieted = new WeakSet();
  const ownKeys = new WeakSet();
  const keysOf = new WeakMap();
  const everKeyed = new WeakSet();
  // A `<source>` given a FairPlay playlist before it's in a media element: the element it's put in
  // takes it over once the page loads or plays that element.
  const pendingSources = new WeakMap();
  const sessionGeneration = new WeakMap();
  // Each track generation's key session, so an element that takes the helper back gets its own.
  const sessionOfGeneration = new Map();

  // A key session's events reach its `on…` handler attribute too, as a real MediaKeySession's do.
  const emit = (target, event) => {
    target.dispatchEvent(event);
    const handler = target["on" + event.type];
    if (typeof handler === "function") handler.call(target, event);
  };

  const deliverRequest = () => {
    if (!pendingSession || !pendingRequest || sessionGeneration.get(pendingSession) !== pendingRequest.generation) return;
    const target = pendingSession;
    const { message } = pendingRequest;
    pendingRequest = null;
    let event;
    try {
      event = new MediaKeyMessageEvent("message", { messageType: "license-request", message });
    } catch (error) {
      event = new Event("message");
      event.messageType = "license-request";
      event.message = message;
    }
    emit(target, event);
  };

  const createSession = () => {
    const keySession = new EventTarget();
    keySession.onmessage = null;
    keySession.onkeystatuseschange = null;
    keySession.sessionId = "arx-" + Math.random().toString(36).slice(2);
    keySession.expiration = NaN;
    keySession.keyStatuses = new Map();
    let close;
    keySession.closed = new Promise((resolve) => (close = resolve));
    keySession.generateRequest = () => {
      trace("key-session");
      sessionGeneration.set(keySession, generation);
      sessionOfGeneration.set(generation, keySession);
      pendingSession = keySession;
      deliverRequest();
      return Promise.resolve();
    };
    keySession.update = (response) => {
      post({ op: "license", generation: sessionGeneration.get(keySession), ckc: toBase64(bytesOf(response)) });
      keySession.keyStatuses = new Map([[new Uint8Array(16).buffer, "usable"]]);
      emit(keySession, new Event("keystatuseschange"));
      return Promise.resolve();
    };
    keySession.load = () => Promise.resolve(false);
    keySession.close = () => {
      close();
      return Promise.resolve();
    };
    keySession.remove = () => Promise.resolve();
    return keySession;
  };

  const createKeys = () => {
    const keys = {
      setServerCertificate(server) {
        const bytes = bytesOf(server);
        if (bytes.length) certificate = toBase64(bytes);
        trace("certificate");
        return Promise.resolve(true);
      },
      createSession,
      getStatusForPolicy: () => Promise.resolve("usable"),
    };
    ownKeys.add(keys);
    pageKeys = keys;
    trace("keys-created");
    return keys;
  };

  const requestAccess = Navigator.prototype.requestMediaKeySystemAccess;
  if (typeof requestAccess === "function") {
    defineProperty(Navigator.prototype, "requestMediaKeySystemAccess", {
      ...getOwnPropertyDescriptor(Navigator.prototype, "requestMediaKeySystemAccess"),
      value: native(requestAccess, (target, self, args) => {
        const keySystem = String(args[0]);
        if (keySystem === KEY_SYSTEM) {
          trace("access-fairplay");
          const configuration = (args[1] && args[1][0]) || {};
          return Promise.resolve({ keySystem: KEY_SYSTEM, getConfiguration: () => configuration, createMediaKeys: () => Promise.resolve(createKeys()) });
        }
        // Refused as a browser without them refuses, so the player moves on to FairPlay.
        if (OTHER_PROTECTED_SYSTEMS.test(keySystem)) {
          trace("access-refused");
          return Promise.reject(new DOMException("Unsupported keySystem or supportedConfigurations.", "NotSupportedError"));
        }
        trace("access-other");
        return apply(target, self, args);
      }),
    });
  }

  const mediaKeys = getOwnPropertyDescriptor(Media, "mediaKeys");
  if (mediaKeys && mediaKeys.get) {
    defineProperty(Media, "mediaKeys", {
      ...mediaKeys,
      get: native(mediaKeys.get, (target, self, args) => (keysOf.has(self) ? keysOf.get(self) : apply(target, self, args))),
    });
  }
  if (typeof Media.setMediaKeys === "function") {
    Media.setMediaKeys = native(Media.setMediaKeys, (target, self, args) => {
      if (ownKeys.has(args[0])) {
        trace("keys-attached");
        keysOf.set(self, args[0]);
        everKeyed.add(self);
        return Promise.resolve();
      }
      keysOf.delete(self);
      return apply(target, self, args);
    });
  }

  // MARK: - The element's own player

  // A taken-over element's own player stays stopped, and none of its events reach the page, which
  // hears the helper's alone, as the element's state reports (DEV-1158). `quiet` is the first
  // capture listener on every target the page listens on for a media event: the window, the
  // element itself and, for an element outside the document, its ancestors. Media events don't
  // bubble, and at the element capture listeners run before the others, so it runs before any of
  // the page's.
  const MEDIA_EVENTS = [
    "abort", "canplay", "canplaythrough", "durationchange", "emptied", "encrypted", "ended", "error",
    "loadeddata", "loadedmetadata", "loadstart", "pause", "play", "playing", "progress", "ratechange",
    "resize", "seeked", "seeking", "stalled", "suspend", "timeupdate", "volumechange", "waiting",
    "waitingforkey",
  ];
  const mediaEvents = new Set(MEDIA_EVENTS);
  const quiet = (event) => {
    if (event.isTrusted && tracks.has(event.target)) apply(stopEvent, event, []);
  };
  const quietElement = (target) => {
    if (quieted.has(target)) return;
    quieted.add(target);
    for (const type of MEDIA_EVENTS) apply(listen, target, [type, quiet, true]);
  };
  EventTarget.prototype.addEventListener = native(listen, (target, self, args) => {
    if (typeof args[0] === "string" && mediaEvents.has(args[0]) && self !== null && typeof self === "object" && !quieted.has(self)) {
      try {
        quietElement(self);
      } catch (error) {}
    }
    return apply(target, self, args);
  });
  for (const type of MEDIA_EVENTS) addEventListener(type, quiet, true);

  // MARK: - The element

  const positionOf = (track) =>
    track.paused || !track.playing ? track.time : Math.min(Number.isNaN(track.duration) ? Infinity : track.duration, track.time + (now() - track.stamp) / 1000);
  const rangesOf = (track) => ({ length: track.ready ? 1 : 0, start: () => 0, end: () => (Number.isNaN(track.duration) ? 0 : track.duration) });
  const drives = (track) => !track.detached && !track.failed;

  const stopTicking = () => {
    if (ticker) clearInterval(ticker);
    ticker = 0;
  };
  const startTicking = () => {
    if (ticker) return;
    ticker = setInterval(
      guard(() => {
        const track = media && tracks.get(media);
        if (track && !track.paused) fire(media, "timeupdate");
        else stopTicking();
      }),
      TICK_MS
    );
  };

  const finishSeek = (track, element) => {
    track.seeking = 0;
    fire(element, "seeked");
    fire(element, "timeupdate");
  };
  const seek = (track, element, value) => {
    const time = +value;
    if (!isFinite(time) || time < 0) return;
    track.time = time;
    track.stamp = now();
    track.ended = false;
    if (!drives(track)) {
      fire(element, "seeking");
      finishSeek(track, element);
      return;
    }
    const sequence = ++track.seeks;
    track.seeking = sequence;
    post({ op: "seek", time, sequence });
    fire(element, "seeking");
    setTimeout(
      guard(() => {
        if (track.seeking === sequence) finishSeek(track, element);
      }),
      SEEK_GIVE_UP_MS
    );
  };

  const natives = {};
  const override = (name, read, write) => {
    const descriptor = getOwnPropertyDescriptor(Media, name);
    if (!descriptor || !descriptor.get) return;
    natives[name] = descriptor;
    defineProperty(Media, name, {
      ...descriptor,
      get: native(descriptor.get, (target, self, args) => {
        const track = tracks.get(self);
        return track ? read(track) : apply(target, self, args);
      }),
      set: descriptor.set
        ? native(descriptor.set, (target, self, args) => {
            const track = tracks.get(self);
            if (track && write) write(track, self, args[0]);
            else apply(target, self, args);
          })
        : undefined,
    });
  };
  override("readyState", (track) => track.ready);
  override("networkState", (track) => (track.ready ? 1 : 2));
  override("duration", (track) => track.duration);
  override("paused", (track) => track.paused);
  override("ended", (track) => track.ended);
  override("error", (track) => track.error);
  override("buffered", rangesOf);
  override("seekable", rangesOf);
  override("currentTime", positionOf, seek);
  override("volume", (track) => track.volume, (track, element, value) => {
    track.volume = Math.min(Math.max(+value || 0, 0), 1);
    if (drives(track)) post({ op: "volume", volume: track.volume });
    fire(element, "volumechange");
  });
  override("muted", (track) => track.muted, (track, element, value) => {
    track.muted = !!value;
    if (drives(track)) post({ op: "muted", muted: track.muted });
    fire(element, "volumechange");
  });
  const nativeValue = (element, name, fallback) => {
    try {
      return apply(natives[name].get, element, []);
    } catch (error) {
      return fallback;
    }
  };

  // Audible playback needs the person's gesture, as Chromium's autoplay policy asks.
  const mayStart = () => !navigator.userActivation || navigator.userActivation.hasBeenActive;

  Media.play = native(Media.play, (target, self, args) => {
    // A next track's `<source>` waiting in this player comes first, even one that holds a track.
    guard(takePending)(self);
    const track = tracks.get(self);
    if (!track) {
      if (everKeyed.has(self)) trace("play-unbridged");
      return apply(target, self, args);
    }
    if (track.failed) return Promise.reject(new DOMException("The element has no supported sources.", "NotSupportedError"));
    if (track.paused && !mayStart()) return Promise.reject(new DOMException("play() failed because the user didn't interact with the document first.", "NotAllowedError"));
    if (track.detached) {
      attach(self, track);
      if (track.time > 0 || track.seeks) post({ op: "seek", time: track.time, sequence: ++track.seeks });
    }
    if (track.paused) {
      if (track.ended) seek(track, self, 0);
      track.paused = false;
      track.ended = false;
      track.stamp = now();
      post({ op: "play" });
      fire(self, "play");
      startTicking();
    }
    return Promise.resolve();
  });
  Media.pause = native(Media.pause, (target, self, args) => {
    const track = tracks.get(self);
    if (!track) return apply(target, self, args);
    if (track.paused) return;
    track.time = positionOf(track);
    track.paused = true;
    track.playing = false;
    post({ op: "pause" });
    fire(self, "pause");
  });
  Media.load = native(Media.load, (target, self, args) =>
    guard(takePending)(self) || tracks.has(self) ? undefined : apply(target, self, args)
  );

  const sendMetadata = () => {
    if (!media) return;
    const metadata = session && session.metadata;
    post({
      op: "metadata",
      title: (metadata && metadata.title) || "",
      artist: (metadata && metadata.artist) || "",
      album: (metadata && metadata.album) || "",
      artwork: artworkOf(metadata) || "",
    });
  };
  const metadataDescriptor = SessionProto && getOwnPropertyDescriptor(SessionProto, "metadata");
  if (metadataDescriptor && metadataDescriptor.set) {
    defineProperty(SessionProto, "metadata", {
      ...metadataDescriptor,
      set: native(metadataDescriptor.set, (target, self, args) => {
        apply(target, self, args);
        guard(sendMetadata)();
      }),
    });
  }

  // MARK: - Taking the element over

  // As Safari's prefixed EME reports a FairPlay key. Spotify requests the licence for an HLS track
  // only after an `encrypted` event its own Safari polyfill marks `fromPolyfill`.
  const encryptedEvent = (key) => {
    const event = new Event("encrypted");
    event.initDataType = "cbcs";
    event.initData = encoder.encode(key);
    event.fromPolyfill = true;
    return event;
  };

  // The page has a FairPlay track Arx can't play in Chromium, and Chromium can't play it either: the
  // app falls back to WebKit rather than leave the page silent. Once a page.
  const giveUp = () => {
    if (gaveUp) return;
    gaveUp = true;
    post({ op: "failed" });
  };

  // Whether `value` is an HLS `data:` playlist with an `skd://` key: FairPlay, which only the
  // helper can play.
  const isFairPlayPlaylist = (value) => {
    const url = String(value);
    const head = url.match(PLAYLIST_URL);
    if (!head) return false;
    try {
      const playlist = /;base64/i.test(head[1]) ? atob(url.slice(head[0].length)) : decodeURIComponent(url.slice(head[0].length));
      return /^#EXTM3U/.test(playlist) && /URI="skd:\/\//.test(playlist);
    } catch (error) {
      return false;
    }
  };

  // A FairPlay playlist set on an element that has FairPlay keys, or in a page that made them: the
  // element is the bridge's.
  const bridge = (element, value) => {
    if (!element) return false;
    const url = String(value);
    const head = url.match(PLAYLIST_URL);
    const keyed = everKeyed.has(element);
    if (!head) {
      if (keyed && url) trace(/^blob:/i.test(url) ? "source-media-source" : "source-other");
      return false;
    }
    let playlist;
    try {
      playlist = /;base64/i.test(head[1]) ? atob(url.slice(head[0].length)) : decodeURIComponent(url.slice(head[0].length));
    } catch (error) {
      trace("playlist-unreadable");
      return false;
    }
    const key = (playlist.match(/URI="(skd:\/\/[^"]+)"/) || [])[1];
    if (!/^#EXTM3U/.test(playlist)) {
      trace("playlist-unreadable");
      return false;
    }
    // Not FairPlay: Chromium's to play.
    if (!key) {
      trace("playlist-no-key");
      return false;
    }
    if (!keyed && !pageKeys) {
      trace("playlist-not-keyed");
      giveUp();
      return false;
    }
    if (!certificate) {
      trace("playlist-no-certificate");
      giveUp();
      return false;
    }
    if (!keyed) {
      trace("keys-adopted");
      everKeyed.add(element);
      // As if the page had given the element its keys: `mediaKeys` reads them.
      if (!keysOf.has(element)) keysOf.set(element, pageKeys);
    }
    const previous = tracks.get(element);
    if (previous) sessionOfGeneration.delete(previous.generation);
    if (media && media !== element) release(media);
    const track = {
      generation: 0,
      playlist,
      certificate,
      loaded: false,
      detached: false,
      ready: 0,
      time: 0,
      stamp: now(),
      duration: NaN,
      paused: true,
      playing: false,
      ended: false,
      error: null,
      failed: false,
      seeks: 0,
      seeking: 0,
      volume: previous ? previous.volume : nativeValue(element, "volume", 1),
      muted: previous ? previous.muted : nativeValue(element, "muted", false),
    };
    tracks.set(element, track);
    quietElement(element);
    // An ordinary source the element played, such as an ad, stops rather than going on under the
    // helper's track; its `timeupdate` and `pause` stay quiet, so the page hears no pause.
    if (!nativeValue(element, "paused", true)) {
      try {
        apply(nativePause, element, []);
      } catch (error) {}
    }
    stopTicking();
    attach(element, track);
    const attached = track.generation;
    setTimeout(
      // Only while the element still drives the helper with this track: a displaced one's key
      // session would take the next element's generation.
      guard(() => {
        if (tracks.get(element) === track && media === element && track.generation === attached) {
          trace("encrypted");
          element.dispatchEvent(encryptedEvent(key));
        }
      }),
      ENCRYPTED_DELAY_MS
    );
    return true;
  };

  const ElementProto = Element.prototype;
  const parentMedia = (source) => (source.parentElement instanceof HTMLMediaElement ? source.parentElement : null);
  const sourceSource = getOwnPropertyDescriptor(HTMLSourceElement.prototype, "src");
  // A `<source>`'s new source. In a media element, that element takes it as its own `src`. Outside
  // one, a FairPlay playlist waits for the element it's put in: Spotify sets it before appending
  // the `<source>` to a player it may have just made (DEV-1144). Any other source is Chromium's.
  const setSource = (source, value) => {
    const parent = parentMedia(source);
    pendingSources.delete(source);
    if (parent) {
      if (guard(bridge)(parent, value)) return true;
      guard(unbridge)(parent);
      return false;
    }
    if (!isFairPlayPlaylist(value)) return false;
    pendingSources.set(source, String(value));
    trace("playlist-deferred");
    // Whatever call puts it in a media element, the element takes it within a moment: checked on
    // the next task, then every PENDING_CHECK_MS while it waits, for as long as a track may take
    // to become ready.
    const waiting = String(value);
    const started = now();
    const check = guard(() => {
      if (pendingSources.get(source) !== waiting) return;
      const player = parentMedia(source);
      if (player) {
        takePending(player);
        return;
      }
      if (now() - started < READY_GIVE_UP_MS) setTimeout(check, PENDING_CHECK_MS);
    });
    setTimeout(check, 0);
    return true;
  };
  // The FairPlay playlist a `<source>` in `element` waits with, taken over as the `<source>` goes
  // in or the page loads or plays the element. One the bridge declines gets its `src` after all.
  const takePending = (element) => {
    for (const child of Array.from(element.children || [])) {
      const value = pendingSources.get(child);
      if (value === undefined) continue;
      pendingSources.delete(child);
      if (bridge(element, value)) return true;
      apply(sourceSource.set, child, [value]);
      return false;
    }
    return false;
  };
  // A `<source>` inserted into a media element: its waiting playlist starts there, as an inserted
  // `<source>` starts a media element's own loading. Every DOM call that inserts a node is
  // covered: into the element itself (appendChild, insertBefore, replaceChild, append, prepend,
  // replaceChildren) or beside a child of it (before, after, replaceWith, insertAdjacentElement).
  // The parent is read before the call too: replaceWith detaches the node it's called on.
  const inserting = (original) =>
    native(original, (target, self, args) => {
      const before = self && self.parentElement;
      const result = apply(target, self, args);
      const players = new Set([self, before, self && self.parentElement]);
      for (const node of args) if (node && typeof node === "object") players.add(node.parentElement);
      for (const player of players) if (player instanceof HTMLMediaElement) guard(takePending)(player);
      return result;
    });
  if (typeof Node === "function") {
    for (const name of ["appendChild", "insertBefore", "replaceChild"]) {
      if (typeof Node.prototype[name] === "function") Node.prototype[name] = inserting(Node.prototype[name]);
    }
  }
  for (const name of ["append", "prepend", "replaceChildren", "before", "after", "replaceWith", "insertAdjacentElement"]) {
    if (typeof ElementProto[name] === "function") ElementProto[name] = inserting(ElementProto[name]);
  }
  // A text or comment placeholder in the element replaced by, or beside, the `<source>`.
  if (typeof CharacterData === "function") {
    for (const name of ["before", "after", "replaceWith"]) {
      if (typeof CharacterData.prototype[name] === "function") CharacterData.prototype[name] = inserting(CharacterData.prototype[name]);
    }
  }
  defineProperty(HTMLSourceElement.prototype, "src", {
    ...sourceSource,
    set: native(sourceSource.set, (target, self, args) => {
      if (guard(setSource)(self, args[0])) return;
      apply(target, self, args);
    }),
  });
  const mediaSource = getOwnPropertyDescriptor(Media, "src");
  defineProperty(Media, "src", {
    ...mediaSource,
    set: native(mediaSource.set, (target, self, args) => {
      if (guard(bridge)(self, args[0])) return;
      guard(unbridge)(self);
      apply(target, self, args);
    }),
  });
  const sourceObject = getOwnPropertyDescriptor(Media, "srcObject");
  if (sourceObject && sourceObject.set) {
    defineProperty(Media, "srcObject", {
      ...sourceObject,
      set: native(sourceObject.set, (target, self, args) => {
        guard(unbridge)(self);
        apply(target, self, args);
      }),
    });
  }
  const isSource = (name) => typeof name === "string" && name.toLowerCase() === "src";
  defineProperty(Media, "setAttribute", {
    ...getOwnPropertyDescriptor(ElementProto, "setAttribute"),
    value: native(ElementProto.setAttribute, (target, self, args) => {
      if (isSource(args[0])) {
        if (guard(bridge)(self, args[1])) return;
        guard(unbridge)(self);
      }
      return apply(target, self, args);
    }),
  });
  // A `<source>`'s `src` set as an attribute goes the same way as its property.
  defineProperty(HTMLSourceElement.prototype, "setAttribute", {
    ...getOwnPropertyDescriptor(ElementProto, "setAttribute"),
    value: native(ElementProto.setAttribute, (target, self, args) => {
      if (isSource(args[0]) && guard(setSource)(self, args[1])) return;
      return apply(target, self, args);
    }),
  });
  // A `<source>` whose `src` goes before it's in a media element has no playlist to wait with.
  defineProperty(HTMLSourceElement.prototype, "removeAttribute", {
    ...getOwnPropertyDescriptor(ElementProto, "removeAttribute"),
    value: native(ElementProto.removeAttribute, (target, self, args) => {
      if (isSource(args[0])) pendingSources.delete(self);
      return apply(target, self, args);
    }),
  });
  defineProperty(Media, "removeAttribute", {
    ...getOwnPropertyDescriptor(ElementProto, "removeAttribute"),
    value: native(ElementProto.removeAttribute, (target, self, args) => {
      if (isSource(args[0])) guard(unbridge)(self);
      return apply(target, self, args);
    }),
  });

  function attach(element, track) {
    // One element drives the helper: the one it drove until now pauses, whichever path attaches.
    if (media && media !== element) release(media);
    const previous = track.generation;
    track.generation = ++generation;
    track.detached = false;
    track.loaded = false;
    const session = previous ? sessionOfGeneration.get(previous) : null;
    sessionOfGeneration.delete(previous);
    if (session && sessionGeneration.get(session) === previous) {
      sessionGeneration.set(session, track.generation);
      sessionOfGeneration.set(track.generation, session);
      pendingSession = session;
    }
    media = element;
    pendingRequest = null;
    // At most MAX_PARTS parts, each within what the app takes; a longer playlist fails at once,
    // so the app falls back.
    const size = Math.max(PLAYLIST_PART, Math.ceil(track.playlist.length / MAX_PARTS));
    const parts = Math.max(1, Math.ceil(track.playlist.length / size));
    if (size > MAX_PART_CHARACTERS) {
      fail(element, track, true);
      return;
    }
    trace("playlist-taken");
    for (let part = 0; part < parts; part++) {
      post({
        op: "load",
        generation: track.generation,
        part,
        parts,
        playlist: track.playlist.slice(part * size, (part + 1) * size),
        certificate: part === 0 ? track.certificate : undefined,
        volume: track.volume,
        muted: track.muted,
      });
    }
    sendMetadata();
    const attached = track.generation;
    setTimeout(
      guard(() => {
        if (tracks.get(element) === track && track.generation === attached && !track.loaded && !track.detached) {
          trace("ready-timeout");
          fail(element, track, true);
        }
      }),
      READY_GIVE_UP_MS
    );
  }

  // Another tab took the player, or the page is going: the element pauses where it is.
  function release(element) {
    const track = tracks.get(element);
    if (!track) return;
    track.detached = true;
    if (track.paused) return;
    track.time = positionOf(track);
    track.paused = true;
    track.playing = false;
    stopTicking();
    fire(element, "pause");
  }

  function unbridge(element) {
    if (!element || !tracks.has(element)) return;
    sessionOfGeneration.delete(tracks.get(element).generation);
    tracks.delete(element);
    if (media === element) {
      media = null;
      pendingRequest = null;
      stopTicking();
      post({ op: "stop" });
    }
    fire(element, "emptied");
  }

  // The element errors as a player that can't decode does. A failure the page found itself (no
  // ready in time) tells the app, which falls back; one the app reported needs no answer.
  function fail(element, track, foundByPage) {
    if (track.failed) return;
    if (foundByPage && media === element && drives(track)) post({ op: "failed" });
    pendingRequest = null;
    track.failed = true;
    track.playing = false;
    track.paused = true;
    stopTicking();
    track.error = { code: 3, message: "Protected playback failed", MEDIA_ERR_ABORTED: 1, MEDIA_ERR_NETWORK: 2, MEDIA_ERR_DECODE: 3, MEDIA_ERR_SRC_NOT_SUPPORTED: 4 };
    fire(element, "error");
  }

  // MARK: - The app's events

  const remote = (command, time) => {
    const track = media && tracks.get(media);
    const action = command === "toggle" ? (track && !track.paused ? "pause" : "play") : command;
    const handler = actions.get(action);
    if (handler) return handler(action === "seekto" ? { action, seekTime: time } : { action });
    if (!media) return;
    if (action === "play") media.play();
    else if (action === "pause") media.pause();
    else if (action === "seekto" && isFinite(time)) media.currentTime = time;
  };

  const receive = (message) => {
    const event = JSON.parse(message);
    if (event.event === "remote") return remote(event.command, event.time);
    const element = media;
    const track = element && tracks.get(element);
    if (!track || event.generation !== track.generation || track.failed) return;
    switch (event.event) {
      case "request":
        pendingRequest = { generation: event.generation, message: fromBase64(event.spc).buffer };
        deliverRequest();
        break;
      case "ready":
        track.loaded = true;
        track.duration = event.duration;
        track.ready = 4;
        for (const type of ["loadedmetadata", "durationchange", "loadeddata", "canplay", "canplaythrough"]) fire(element, type);
        break;
      case "position": {
        if (event.sequence < track.seeks) return;
        track.time = event.time;
        track.stamp = now();
        if (track.seeking) finishSeek(track, element);
        const wasPlaying = track.playing;
        track.playing = !!event.playing && !track.paused;
        if (track.playing && !wasPlaying) fire(element, "playing");
        else if (wasPlaying && !track.playing && !track.paused) fire(element, "waiting");
        break;
      }
      case "ended":
        if (!Number.isNaN(track.duration)) track.time = track.duration;
        track.playing = false;
        track.paused = true;
        track.ended = true;
        stopTicking();
        fire(element, "timeupdate");
        fire(element, "pause");
        fire(element, "ended");
        break;
      case "failed":
        fail(element, track, false);
        break;
      case "stolen":
        release(element);
        break;
    }
  };

  addEventListener(
    "pagehide",
    guard((event) => {
      if (!event.isTrusted || !media) return;
      post({ op: "stop" });
      release(media);
    })
  );

  return guard(receive);
});
