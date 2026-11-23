"""A page that asks for protected media is offered WebKit (DEV-877).

The app smoke's overnight `webkit-fallback` phase. Set `ARX_SMOKE_OVERNIGHT=1` for `make
app-smoke` to run it: it moves a page to WebKit, which starts WebKit's own processes.

`protected-media.html` asks for Widevine with `navigator.requestMediaKeySystemAccess` once it
has drawn, then creates its keys. Arx has no Widevine module. Its engine answers Widevine as
Chrome does (DEV-1144), so access resolves and `createMediaKeys` rejects with
NotSupportedError; the page's title says which happened. It asks from its `<video>`'s
`encrypted` handler, as a streaming player may (DEV-1211): `encrypted-init.webm`, a WebM
initialization segment for one AES-CTR encrypted VP8 track, appended through MediaSource, fires
`encrypted` first, so the engine hears of media that wants keys before the page's first key
system question, which must still be answered (the title settles).
Chromium reports media that can't play (the failed keys or, with `ARX_WIDEVINE_ANSWER=off`,
the refused access) and Arx's fallback prompt must appear on the page's window. The phase
requires the answered title unless that feature flag is off. The phase accepts Open in WebKit
and requires the site's list entry, the page in WebKit at the same address with the sidebar's engine mark,
then moves it back. Loopback http counts as a secure origin, as Chromium and WebKit treat it,
so the page can ask and the list can name it.

The app opens the page on whichever loopback host (`localhost` or `127.0.0.1`) its tab isn't
showing: a frame asks for key systems once, and a same-site navigation can keep an earlier
page's frame, which then never asks. The fixture listens on `127.0.0.1` and `::1` at one port
(`loopback_server`), so `localhost` reaches it whichever address the browser tries.

Before that, `create-keys-only.html` on `[::1]`, a third loopback site nobody listed, creates
keys (or, with the answer off, is refused access) and gives them to no media element, as a bot
check may. No prompt may come for 5 seconds (DEV-1211, `ARX_KEYS_ONLY_SMOKE quiet`). Then
`framed-player.html`, on the other loopback host and unlisted too, makes its keys while its
same-origin iframe `framed-video.html` meets encrypted media: media in a same-origin frame of
the page counts, so the prompt must come (`ARX_FRAMED_PLAYER_SMOKE offered`); the phase answers
Stay on Page.

Then (DEV-1205), with the Widevine answer on, two pages must behave as in Chrome:

- `drm-probe.html` makes the calls Fingerprint's bot detection makes (resend.com): a
  `MediaCapabilities.decodingInfo` query for Widevine, then `requestMediaKeySystemAccess` for
  Widevine with and without a persistent licence, PlayReady, Clear Key, Primetime and FairPlay.
  Its title must read Chrome's answers (`PROBE_ANSWER`), and no prompt may come for longer than
  the engine waits for a grant after a refusal.
- `refused-protected-media.html` asks only for PlayReady, which is refused, and nothing is
  granted. The prompt must come; the phase answers Stay on Page.

Then (DEV-1000) the WebKit page opens `create-keys-only.html` at the listed site and goes back
to Chromium, where Arx keeps it. Its keys fail with no media wanting them; on a site the person
listed that still asks (DEV-1211), and a streaming site's video falls back to WebKit with a
prompt, never silently (DEV-1188): the phase requires the prompt
(`ARX_WEBKIT_FALLBACK_KEPT_SMOKE offered`), answers Stay on Page and requires the page to stay
in Chromium. If it moves, the failure lists the page's
events, engine changes, protected media requests and `FairPlay` log while the phase watched.

Last, the Chromium page goes to `redirect-to-protected-media.html` on the other
loopback host, which replaces itself by script with the listed page on the host its `to`
parameter names: no link click Arx could take. The page must move to WebKit on its own, with no
prompt.
"""

import os

PAGE = "protected-media.html"
REDIRECT = "redirect-to-protected-media.html"
PROBE = "drm-probe.html"
REFUSED_ONLY = "refused-protected-media.html"
# DEV-1211: a page that creates keys and gives them to no media element, as a bot check may,
# and the encrypted media a player's <video> meets.
KEYS_ONLY = "create-keys-only.html"
# A player that keeps its video in a same-origin iframe and makes its keys in the parent.
FRAMED_PLAYER = "framed-player.html"
FRAMED_VIDEO = "framed-video.html"
ENCRYPTED_INIT = "encrypted-init.webm"
MARKER = "ARX_WEBKIT_FALLBACK_SMOKE_SUCCESS"
# The page kept in Chromium at the listed site was offered WebKit when its keys failed (DEV-1188).
KEPT_MARKER = "ARX_WEBKIT_FALLBACK_KEPT_SMOKE offered"
# The keys-only page on a site nobody listed got no prompt (DEV-1211).
KEYS_ONLY_MARKER = "ARX_KEYS_ONLY_SMOKE quiet"
# The framed player, keys in the parent and video in the iframe, got the prompt (DEV-1211).
FRAMED_MARKER = "ARX_FRAMED_PLAYER_SMOKE offered"
# The page's title once Widevine is answered without a CDM (DEV-1144), and with the answer off.
ANSWERED = "Protected media keys refused: NotSupportedError"
REFUSED = "Protected media refused"
# Chrome on a Mac (Widevine 4.10.3112.0: no persistent licences) answers the probe so (DEV-1205).
PROBE_ANSWER = "DRM probe: decodingInfo=true wv=true wvp=false pr=false ck=true pt=false fp=false"
REFUSED_ONLY_TITLE = "Protected media refused: NotSupportedError"
# The keys-only page's title with the Widevine answer on, and off.
KEYS_ONLY_ANSWERED = "Keys only: keys refused: NotSupportedError"
KEYS_ONLY_REFUSED = "Keys only: access refused"
# The framed player's title with the Widevine answer on, and off.
FRAMED_ANSWERED = "Framed player keys refused: NotSupportedError"
FRAMED_REFUSED = "Framed player refused"
# The Widevine-encrypted key ID the init segment names; any 16 bytes do.
KEY_ID = bytes(range(16))


def _ebml(element_id, payload):
    """One EBML element: its ID's bytes, a minimal size, then its payload."""
    size = len(payload)
    for length in range(1, 9):
        if size < (1 << (7 * length)) - 1:
            break
    encoded = (size | (1 << (7 * length))).to_bytes(length, "big")
    return element_id.to_bytes((element_id.bit_length() + 7) // 8, "big") + encoded + payload


def _uint(element_id, value):
    return _ebml(element_id, value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big"))


def encrypted_init_segment():
    """A WebM initialization segment for one VP8 track encrypted with AES-CTR (WebM's
    ContentEncryption). Appended to a MediaSource, it makes the media element fire `encrypted`
    with the key ID, as a player's <video> does when it meets protected media (DEV-1211)."""
    header = _ebml(0x1A45DFA3, b"".join([
        _uint(0x4286, 1), _uint(0x42F7, 1), _uint(0x42F2, 4), _uint(0x42F3, 8),
        _ebml(0x4282, b"webm"), _uint(0x4287, 4), _uint(0x4285, 2),
    ]))
    info = _ebml(0x1549A966, _uint(0x2AD7B1, 1_000_000))
    encryption = _ebml(0x5035, b"".join([
        _uint(0x47E1, 5),                      # ContentEncAlgo: AES
        _ebml(0x47E2, KEY_ID),                 # ContentEncKeyID
        _ebml(0x47E7, _uint(0x47E8, 1)),       # ContentEncAESSettings: AES-CTR
    ]))
    encoding = _ebml(0x6240, b"".join([
        _uint(0x5031, 0), _uint(0x5032, 1), _uint(0x5033, 1), encryption,
    ]))
    track = _ebml(0xAE, b"".join([
        _uint(0xD7, 1), _uint(0x73C5, 1), _uint(0x83, 1), _ebml(0x86, b"V_VP8"),
        _ebml(0xE0, _uint(0xB0, 16) + _uint(0xBA, 16)),
        _ebml(0x6D80, encoding),
    ]))
    tracks = _ebml(0x1654AE6B, track)
    # A Segment of unknown size, as a live or MediaSource stream starts.
    segment = bytes.fromhex("18538067") + bytes.fromhex("01FFFFFFFFFFFFFF") + info + tracks
    return header + segment


def enabled(environment=os.environ):
    return environment.get("ARX_SMOKE_OVERNIGHT") == "1"


def prepare(root):
    with (root / PAGE).open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>Protected media loading</title>
<p>Owned protected media request document.</p>
<script>
const configuration = [{
  initDataTypes: ['cenc'],
  videoCapabilities: [{contentType: 'video/mp4; codecs="avc1.42E01E"'}],
}];
// DEV-1211: once a frame is presented, the player's <video> meets encrypted media, as a
// streaming site's does, so failed keys are a page that can't play, not a bot check's. It asks
// for keys from its `encrypted` handler, before any other EME call: the media report reaches
// the browser before the page's first key system question, which must still be answered.
let asked = false;
requestAnimationFrame(() => requestAnimationFrame(() => {
  const video = document.createElement('video');
  document.body.append(video);
  const source = new MediaSource();
  video.src = URL.createObjectURL(source);
  video.addEventListener('encrypted', () => {
    document.body.dataset.encrypted = 'true';
    if (asked) return;
    asked = true;
    navigator.requestMediaKeySystemAccess('com.widevine.alpha', configuration)
      .then(access => access.createMediaKeys().then(
        () => { document.title = 'Protected media keys created'; },
        error => { document.title = 'Protected media keys refused: ' + error.name; }))
      .catch(() => { document.title = 'Protected media refused'; });
  });
  source.addEventListener('sourceopen', async () => {
    const buffer = source.addSourceBuffer('video/webm; codecs="vp8"');
    buffer.appendBuffer(await (await fetch('""" + ENCRYPTED_INIT + """')).arrayBuffer());
  });
}));
</script>
""")
    (root / ENCRYPTED_INIT).write_bytes(encrypted_init_segment())
    with (root / FRAMED_PLAYER).open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>Framed player loading</title>
<p>Owned player document: its keys here, its video in a same-origin frame.</p>
<iframe src='""" + FRAMED_VIDEO + """' width="64" height="64"></iframe>
<script>
requestAnimationFrame(() => requestAnimationFrame(() => {
  navigator.requestMediaKeySystemAccess('com.widevine.alpha', [{
    initDataTypes: ['cenc'],
    videoCapabilities: [{contentType: 'video/mp4; codecs="avc1.42E01E"'}],
  }]).then(access => access.createMediaKeys().then(
      () => { document.title = 'Framed player keys created'; },
      error => { document.title = 'Framed player keys refused: ' + error.name; }),
    () => { document.title = 'Framed player refused'; });
}));
</script>
""")
    with (root / FRAMED_VIDEO).open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>Framed video</title>
<script>
// The framed player's <video> meets encrypted media; its keys are the parent's to make.
const video = document.createElement('video');
document.documentElement.append(video);
const source = new MediaSource();
video.src = URL.createObjectURL(source);
source.addEventListener('sourceopen', async () => {
  const buffer = source.addSourceBuffer('video/webm; codecs="vp8"');
  buffer.appendBuffer(await (await fetch('""" + ENCRYPTED_INIT + """')).arrayBuffer());
});
</script>
""")
    with (root / KEYS_ONLY).open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>Keys only loading</title>
<p>Owned document that creates media keys and gives them to no media element.</p>
<script>
requestAnimationFrame(() => requestAnimationFrame(() => {
  navigator.requestMediaKeySystemAccess('com.widevine.alpha', [{
    initDataTypes: ['cenc'],
    videoCapabilities: [{contentType: 'video/mp4; codecs="avc1.42E01E"'}],
  }]).then(access => access.createMediaKeys().then(
      () => { document.title = 'Keys only: keys created'; },
      error => { document.title = 'Keys only: keys refused: ' + error.name; }),
    () => { document.title = 'Keys only: access refused'; });
}));
</script>
""")
    with (root / REDIRECT).open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>Redirecting to protected media</title>
<p>Owned redirect document.</p>
<script>
const target = new URL('""" + PAGE + """', location.href);
target.hostname = new URLSearchParams(location.search).get('to') || '127.0.0.1';
target.search = '';
location.replace(target.href);
</script>
""")
    with (root / PROBE).open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>DRM probe loading</title>
<p>Owned DRM capability probe document, as bot detection asks.</p>
<script>
// Fingerprint's agent (jsl/4.1.6), decoded: its decodingInfo query, then its key system checks.
const audio = {contentType: 'audio/mp4;codecs="mp4a.40.2"'};
const base = () => ({initDataTypes: ['cenc'], audioCapabilities: [{...audio}]});
const widevine = persistent => {
  const configuration = base();
  configuration.audioCapabilities[0].robustness = 'SW_SECURE_CRYPTO';
  if (persistent) configuration.sessionTypes = ['persistent-license'];
  return configuration;
};
const access = (keySystem, configuration) =>
  navigator.requestMediaKeySystemAccess(keySystem, [configuration]).then(() => true, () => false);
const any = async keySystems => {
  for (const keySystem of keySystems) if (await access(keySystem, base())) return true;
  return false;
};
requestAnimationFrame(() => requestAnimationFrame(async () => {
  let decodingInfo = false;
  try {
    const result = await navigator.mediaCapabilities.decodingInfo({
      type: 'media-source',
      audio: {contentType: 'audio/mp4; codecs="mp4a.40.2"'},
      video: {contentType: 'video/mp4; codecs="avc1.42E01E"', bitrate: 10000, framerate: 30,
              height: 480, width: 640},
      keySystemConfiguration: {keySystem: 'com.widevine.alpha',
                               video: {robustness: 'SW_SECURE_CRYPTO'}},
    });
    decodingInfo = Object.prototype.hasOwnProperty.call(result, 'keySystemAccess')
      && !!result.keySystemAccess && !('brave' in navigator);
  } catch (error) {}
  const [wv, wvp, pr, ck, pt, fp] = await Promise.all([
    decodingInfo ? access('com.widevine.alpha', widevine(false)) : false,
    decodingInfo ? access('com.widevine.alpha', widevine(true)) : false,
    any(['com.microsoft.playready', 'com.youtube.playready']),
    any(['webkit-org.w3.clearkey', 'org.w3.clearkey']),
    any(['com.adobe.primetime', 'com.adobe.access']),
    any(['com.apple.fairplay']),
  ]);
  document.title = `DRM probe: decodingInfo=${decodingInfo} wv=${wv} wvp=${wvp} pr=${pr} ` +
    `ck=${ck} pt=${pt} fp=${fp}`;
}));
</script>
""")
    with (root / REFUSED_ONLY).open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>Refused protected media loading</title>
<p>Owned document whose only protected media request is refused.</p>
<script>
requestAnimationFrame(() => requestAnimationFrame(() => {
  navigator.requestMediaKeySystemAccess('com.microsoft.playready', [{
    initDataTypes: ['cenc'],
    videoCapabilities: [{contentType: 'video/mp4; codecs="avc1.42E01E"'}],
  }]).then(
    () => { document.title = 'Protected media granted'; },
    error => { document.title = 'Protected media refused: ' + error.name; });
}));
</script>
""")
    return {"ARX_WEBKIT_FALLBACK_SMOKE": "1"}


def verify(stdout):
    lines = stdout.splitlines()
    for marker in (KEYS_ONLY_MARKER, FRAMED_MARKER, KEPT_MARKER, MARKER):
        if marker not in lines:
            raise ValueError("WebKit fallback smoke did not complete: " + marker)
