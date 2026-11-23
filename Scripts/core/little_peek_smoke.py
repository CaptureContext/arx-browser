"""Disposable documents and exact acceptance markers for Little Arx Peek handoff."""

MARKERS = (
    "ARX_LITTLE_PEEK_DISMISS_SMOKE_SUCCESS",
    "ARX_LITTLE_PEEK_PROMOTION_SMOKE_SUCCESS",
    "ARX_PEEK_ESCAPE_MAIN_SUCCESS",
    "ARX_PEEK_ESCAPE_LITTLE_SUCCESS",
    "ARX_PEEK_POPUP_MAIN_SUCCESS",
    "ARX_SHIFT_CLICK_PEEK_SUCCESS",
    "ARX_KEYBOARD_LINK_PEEK_SUCCESS",
    "ARX_FOCUSED_LINK_COMMAND_PEEK_SUCCESS",
    "ARX_PEEK_POPUP_LITTLE_SUCCESS",
    "ARX_PRIVATE_POPUP_SUCCESS",
    "ARX_PAGE_CONSENT_MAIN_SUCCESS",
    "ARX_PAGE_CONSENT_LITTLE_SUCCESS",
    "ARX_PAGE_CONSENT_PRIVATE_SUCCESS",
    "ARX_LITTLE_POPUP_SMOKE_SUCCESS",
    "ARX_WINDOW_POPUP_SMOKE_SUCCESS",
    "ARX_FAVORITE_NEW_TAB_SMOKE_SUCCESS",
)


def prepare(root):
    # The app runner creates this root and profile before preparing any fixture.
    # Exclusive creation prevents overwriting an already prepared fixture page.
    with (root / "little-peek.html").open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8">
<title>Little Peek fixture loading</title>
<p>Controlled Little Arx Peek document.</p>
<script>
const phase = new URLSearchParams(location.search).get('phase');
if (['dismiss', 'promote-start', 'promote-next'].includes(phase)) {
  document.title = 'Arx Little Peek ' + phase + ':' + crypto.randomUUID();
}
</script>
""")

    with (root / "peek-escape.html").open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8">
<title>Peek Escape fixture loading</title>
<p>Owned native Escape acceptance document.</p>
<script>
const phase = new URLSearchParams(location.search).get('phase');
if (['consumed', 'navigate', 'unconsumed', 'arrived'].includes(phase)) {
  // Announce readiness only after a frame is presented, so native keys route.
  requestAnimationFrame(() => requestAnimationFrame(() => { document.title = 'Arx Peek Escape ' + phase + ':0'; }));
  addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    if (phase === 'consumed') {
      event.preventDefault();
      document.title = 'Arx Peek Escape consumed:1';
    } else if (phase === 'navigate') {
      location.assign('peek-escape.html?phase=arrived');
    }
  });
}
</script>
""")


    with (root / "peek-popup.html").open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>Popup fixture loading</title>
<style>button {position:fixed;left:16px;top:16px;width:200px;height:44px}</style>
<button id="open">Open owned popup</button>
<script>
const phase = new URLSearchParams(location.search).get('phase');
if (['allowed', 'blocked', 'private'].includes(phase)) {
  sessionStorage.setItem('arx-popup-proof', phase);
  document.cookie = 'arx-popup-profile=' + phase + '; SameSite=Strict; path=/';
  // Announce readiness only after a frame is presented, so native clicks hit-test.
  requestAnimationFrame(() => requestAnimationFrame(() => { document.title = 'Arx Popup ' + phase; }));
  const target = 'peek-popup-child.html?phase=' + phase;
  document.getElementById('open').onclick = () => window.open(target, '_blank', 'popup,width=480,height=400');
  if (phase === 'blocked') setTimeout(() => window.open(target, '_blank', 'popup,width=480,height=400'), 100);
}
</script>
""")
    # DEV-855: a sign-in popup from Little Arx. The popup messages its opener, which answers
    # through the popup's window proxy; the popup then closes itself, as an OAuth popup does.
    with (root / "little-popup.html").open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>Little popup loading</title>
<style>button {position:fixed;left:16px;top:16px;width:200px;height:44px}</style>
<button id="open">Sign in</button>
<script>
addEventListener('message', event => {
  if (event.origin !== location.origin || event.data !== 'arx-little-popup-hello') return;
  event.source.postMessage('arx-little-popup-ack', location.origin);
  document.title = 'Arx Little Popup received';
});
document.getElementById('open').onclick = () =>
  window.open('little-popup-child.html', 'arx-sign-in', 'popup,width=480,height=600');
// Announce readiness only after a frame is presented, so native clicks hit-test.
requestAnimationFrame(() => requestAnimationFrame(() => { document.title = 'Arx Little Popup ready'; }));
</script>
""")
    with (root / "little-popup-child.html").open("x") as page:
        page.write("""<!doctype html><meta charset="utf-8"><title>Little popup child loading</title>
<script>
addEventListener('message', event => {
  if (event.origin !== location.origin || event.data !== 'arx-little-popup-ack') return;
  document.title = 'Arx Little Popup child acked';
  setTimeout(() => window.close(), 1500);
});
if (window.opener) window.opener.postMessage('arx-little-popup-hello', location.origin);
else document.title = 'Arx Little Popup lost opener';
</script>
""")
    # DEV-1312: a page's new tab from a Favorite, as Gmail's account switch opens one: a plain
    # target="_blank" link. It says rel="opener", since Chromium otherwise drops the opener,
    # so the smoke sees that Peek shows the engine's own page: the opener still answers.
    with (root / "favorite-new-tab.html").open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>Favorite new tab loading</title>
<a id="open" href="favorite-new-tab-child.html" target="_blank" rel="opener" style="position:fixed;left:16px;top:16px;width:200px;height:44px;display:block">Other account</a>
<script>
addEventListener('message', event => {
  if (event.origin !== location.origin || event.data !== 'arx-favorite-new-tab-hello') return;
  event.source.postMessage('arx-favorite-new-tab-ack', location.origin);
  document.title = 'Arx Favorite new tab received';
});
requestAnimationFrame(() => requestAnimationFrame(() => { document.title = 'Arx Favorite new tab ready'; }));
</script>
""")
    with (root / "favorite-new-tab-child.html").open("x") as page:
        page.write("""<!doctype html><meta charset="utf-8"><title>Favorite new tab child loading</title>
<script>
addEventListener('message', event => {
  if (event.origin !== location.origin || event.data !== 'arx-favorite-new-tab-ack') return;
  document.title = 'Arx Favorite new tab child acked';
});
if (window.opener) window.opener.postMessage('arx-favorite-new-tab-hello', location.origin);
else document.title = 'Arx Favorite new tab lost opener';
</script>
""")
    with (root / "shift-link.html").open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>Shift link loading</title>
<a href="shift-target.html" style="position:fixed;left:0;top:0;width:400px;height:200px;display:block">Target</a>
<script>
// The title also counts the trusted mouse-downs the page saw, and those with Shift, so the app
// smoke tells a click Chromium never delivered from one the page saw (ShiftClickCheck.PageSaw).
const seen = { down: 0, shift: 0 };
const report = () => {
  document.title = 'Arx Shift link' + (seen.down ? ` \u00b7 down=${seen.down} shift=${seen.shift}` : '');
};
addEventListener('mousedown', event => {
  if (!event.isTrusted) return;
  seen.down++;
  if (event.shiftKey) seen.shift++;
  report();
}, true);
requestAnimationFrame(() => requestAnimationFrame(report));
</script>
""")
    # Each phase focuses the element just before its target, so one real Tab reaches it.
    # The title reports the focused element (inside the same-origin frame too) and how
    # many Return keydowns the page saw, without relying on focus events.
    with (root / "keyboard-link.html").open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>Keyboard link loading</title>
<button id="start">Start</button>
<a id="link" href="keyboard-target.html?from=main">Main target</a>
<input id="field" type="text" aria-label="Field">
<iframe id="frame" src="keyboard-frame.html" width="300" height="80"></iframe>
<button id="after">After</button>
<script>
const phase = new URLSearchParams(location.search).get('phase');
const before = {link: 'start', field: 'link', frame: 'field', button: 'frame-link'}[phase];
let returns = 0;
addEventListener('keydown', event => { if (event.key === 'Enter') returns += 1; }, true);
function focused() {
  const element = document.activeElement;
  if (element && element.id === 'frame') {
    const inner = element.contentDocument && element.contentDocument.activeElement;
    return 'frame-' + (inner && inner.id ? inner.id : 'none');
  }
  return element && element.id ? element.id : 'none';
}
const frame = document.getElementById('frame');
frame.addEventListener('load', () => {
  frame.contentWindow.addEventListener('keydown', event => { if (event.key === 'Enter') returns += 1; }, true);
  if (!before) return;
  if (before === 'frame-link') frame.contentDocument.getElementById('link').focus();
  else document.getElementById(before).focus();
  setInterval(() => { document.title = 'Arx Keyboard ' + phase + ' focus:' + focused() + ' returns:' + returns; }, 50);
});
</script>
""")
    with (root / "keyboard-frame.html").open("x") as page:
        page.write("""<!doctype html><meta charset="utf-8"><title>Keyboard frame</title>
<a id="link" href="keyboard-target.html?from=frame">Frame target</a>
""")
    with (root / "keyboard-target.html").open("x") as page:
        page.write("""<!doctype html><meta charset="utf-8"><title>Keyboard target loading</title>
<script>document.title = 'Arx Keyboard target ' + new URLSearchParams(location.search).get('from');</script>
""")
    with (root / "shift-target.html").open("x") as page:
        page.write('<!doctype html><meta charset="utf-8"><title>Arx Shift target</title>')
    with (root / "peek-popup-child.html").open("x") as page:
        page.write("""<!doctype html><meta charset="utf-8"><title>Popup child loading</title>
<script>
const phase = new URLSearchParams(location.search).get('phase');
const proof = window.opener && window.opener.sessionStorage.getItem('arx-popup-proof');
const sameProfile = document.cookie.split('; ').includes('arx-popup-profile=' + phase);
document.title = sameProfile && (phase === 'blocked' || proof === phase)
  ? 'Arx Popup child ' + phase : 'Arx Popup lost source';
</script>
""")


def verify(stdout):
    lines = set(stdout.splitlines())
    missing = [marker for marker in MARKERS if marker not in lines]
    if missing:
        raise ValueError("Little Peek smoke did not complete: " + ", ".join(missing))
