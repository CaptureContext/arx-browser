"""The page that takes ⌘K and ⌘Z for the site shortcuts smoke (DEV-1264, DEV-1073), and ⌘F and ⌃1
for Conflict resolution's Delayed and its keys without ⌘ (DEV-1332)."""

MARKERS = ("ARX_SITE_SHORTCUTS_SMOKE_SUCCESS",)


def prepare(root):
    # Exclusive creation: the runner prepares each fixture once in its own disposable root.
    with (root / "site-shortcuts.html").open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8">
<title>Site shortcuts fixture loading</title>
<p>Owned page for the keys a site may take before Arx.</p>
<script>
const phase = new URLSearchParams(location.search).get('phase');
let k = 0, z = 0;
const show = () => { document.title = 'Arx Site Shortcuts ' + phase + ':k' + k + ':z' + z; };
if (['take', 'leave'].includes(phase)) {
  // Announce readiness only after a frame is presented, so native keys route.
  requestAnimationFrame(() => requestAnimationFrame(show));
  addEventListener('keydown', event => {
    if (phase !== 'take' || !event.metaKey || event.shiftKey) return;
    if (event.key === 'k') { event.preventDefault(); k += 1; show(); }
    if (event.key === 'z') { event.preventDefault(); z += 1; show(); }
  });
}
let f = 0, c = 0;
const count = () => { document.title = 'Arx Site Shortcuts ' + phase + ':f' + f + ':c' + c; };
if (phase === 'keys') {
  requestAnimationFrame(() => requestAnimationFrame(count));
  addEventListener('keydown', event => {
    // DEV-1332: ⌘F for Delayed, ⌃1 for a key without ⌘.
    if (event.metaKey && !event.shiftKey && event.key === 'f') { event.preventDefault(); f += 1; count(); }
    if (event.ctrlKey && !event.metaKey && event.key === '1') { event.preventDefault(); c += 1; count(); }
  });
}
</script>
""")


def verify(stdout):
    lines = set(stdout.splitlines())
    missing = [marker for marker in MARKERS if marker not in lines]
    if missing:
        raise ValueError("Site shortcuts smoke did not complete: " + ", ".join(missing))
