"""A page's link for another app goes to Air Traffic Control's handler (DEV-857, ABI50).

The fixture page in Little Arx redirects itself, without a click, to a link with an
unregistered test scheme whose query carries `;`, `$(…)` and quotes. The app smoke's
`app-link` phase gives that scheme a handler whose script records `$1` to a file, confirms
Arx's prompt and requires the recorded argument to equal the link exactly. Nothing may
launch: the scheme has no app, Chrome's dialog never shows, and Open app is never chosen.
Needs an ABI50 engine.

DEV-862 adds a chosen app: `app-link-app.html` redirects the same way to a second unregistered
scheme, whose handler opens the link with a fixture applet chosen by path. The applet records
the link it receives and quits, so the recorded link proves Arx opened it with that app rather
than System default (nothing is registered for the scheme). The phase then points the handler
at an app that isn't there and requires the prompt to say so, opening nothing.

DEV-1259: a link no handler takes still gets Arx's prompt, never Chrome's "Open app?" dialog.
`app-link-open.html` redirects to `arx-smoke-app-open://`, which a second applet declares in
its `Info.plist` and Launch Services registers for the run (`lsregister -f`, undone by
`unregister_open_app`). No handler exists for it: the phase requires Arx's prompt naming the
applet, Open to hand the link to it, and nothing to be saved.
"""

import os
import subprocess
from pathlib import Path

SCHEME = "arx-smoke-app-link"
APP_SCHEME = "arx-smoke-app-pick"
APP_NAME = "Arx App Link Fixture"
OPEN_SCHEME = "arx-smoke-app-open"
OPEN_APP_NAME = "Arx App Link Open Fixture"
LSREGISTER = (
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
    "/Support/lsregister"
)
MARKERS = (
    "ARX_APP_LINK_SMOKE_SUCCESS", "ARX_APP_LINK_APP_SMOKE_SUCCESS", "ARX_APP_LINK_OPEN_SMOKE_SUCCESS",
)


def prepare(root):
    with (root / "app-link.html").open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>App link loading</title>
<p>Owned app-link redirect document.</p>
<script>
const link = '""" + SCHEME + """://callback?code=' + crypto.randomUUID()
  + '&inject=a;touch%20/tmp/arx-app-link-pwned&sub=$(id)&q=%27single%27&dq=%22double%22';
// Ready only after a frame is presented, then hand off the way a sign-in callback does:
// a script redirect with no user gesture. It replaces the page: after the load event,
// Blink counts a location change as a client redirect only when it replaces, so
// `location.href` would reach Chrome as a plain link and the prompt as no redirect.
requestAnimationFrame(() => requestAnimationFrame(() => {
  document.title = 'Arx App Link ready';
  setTimeout(() => { location.replace(link); }, 300);
}));
</script>
""")

    with (root / "app-link-app.html").open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>App link app loading</title>
<p>Owned app-link redirect document for a chosen app.</p>
<script>
const link = '""" + APP_SCHEME + """://callback?code=' + crypto.randomUUID();
requestAnimationFrame(() => requestAnimationFrame(() => {
  document.title = 'Arx App Link App ready';
  setTimeout(() => { location.href = link; }, 300);
}));
</script>
""")


    with (root / "app-link-open.html").open("x") as page:
        page.write("""<!doctype html>
<meta charset="utf-8"><title>App link open loading</title>
<p>Owned app-link redirect document for a scheme no handler takes.</p>
<script>
const link = '""" + OPEN_SCHEME + """://callback?code=' + crypto.randomUUID();
requestAnimationFrame(() => requestAnimationFrame(() => {
  document.title = 'Arx App Link Open ready';
  setTimeout(() => { location.href = link; }, 300);
}));
</script>
""")


def applet_source(record):
    """AppleScript for the fixture app: write the link it's opened with to `record`, then quit.

    No `run` handler: launched with a link, the applet waits for it. It declares no URL types,
    so only an open naming the app reaches it.
    """
    escaped = str(record).replace("\\", "\\\\").replace('"', '\\"')
    return (
        "on open location theURL\n"
        f'  do shell script "printf %s " & quoted form of theURL & " > " & quoted form of "{escaped}"\n'
        "  quit\n"
        "end open location\n"
    )


def prepare_app(root):
    """Builds the fixture applet with `osacompile`. Returns the environment the phase reads.

    `root` should be on the startup disk: macOS asks before a new applet writes to an external
    drive, and every run builds a new one.
    """
    record = root / "app-link-app-record.txt"
    source = root / "app-link-app.applescript"
    app = root / (APP_NAME + ".app")
    source.write_text(applet_source(record))
    subprocess.run(["/usr/bin/osacompile", "-o", str(app), str(source)], check=True, capture_output=True)
    return {
        "ARX_APP_LINK_FIXTURE_APP": str(app),
        "ARX_APP_LINK_FIXTURE_RECORD": str(record),
    }


def open_app_parent(work, home=None):
    """Where the DEV-1259 applet's folder goes: never the system's temporary folder.

    Launch Services marks an app in a temporary folder `launch-disabled`, so it never names
    one for a scheme. `work` serves when it's on the home volume; a checkout on an external
    drive uses the home's caches instead, since the applet writes its record beside itself
    and macOS would ask before that write.
    """
    home = Path(home) if home is not None else Path.home()
    if os.stat(work).st_dev == os.stat(home).st_dev:
        return Path(work)
    parent = home / "Library" / "Caches" / "dev.capturecontext.arx.smoke"
    parent.mkdir(parents=True, exist_ok=True)
    return parent


def prepare_open_app(root):
    """Builds the DEV-1259 applet, declaring `OPEN_SCHEME`, and registers it with Launch Services.

    `root` must be outside the system's temporary folder (see `open_app_parent`). Returns the
    environment the phase reads. Call `unregister_open_app` with it afterwards.
    """
    record = root / "app-link-open-record.txt"
    source = root / "app-link-open.applescript"
    app = root / (OPEN_APP_NAME + ".app")
    source.write_text(applet_source(record))
    subprocess.run(["/usr/bin/osacompile", "-o", str(app), str(source)], check=True, capture_output=True)
    info = app / "Contents" / "Info.plist"
    subprocess.run(
        ["/usr/bin/plutil", "-insert", "CFBundleURLTypes", "-json",
         '[{"CFBundleURLName":"' + OPEN_SCHEME + '","CFBundleURLSchemes":["' + OPEN_SCHEME + '"]}]',
         str(info)],
        check=True, capture_output=True,
    )
    subprocess.run(
        ["/usr/bin/plutil", "-replace", "CFBundleIdentifier", "-string",
         "dev.capturecontext.arx.smoke.app-link-open", str(info)],
        check=True, capture_output=True,
    )
    # The edited bundle needs a signature again before Launch Services trusts it.
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    subprocess.run([LSREGISTER, "-f", str(app)], check=True, capture_output=True)
    return {
        "ARX_APP_LINK_OPEN_FIXTURE_APP": str(app),
        "ARX_APP_LINK_OPEN_FIXTURE_RECORD": str(record),
    }


def unregister_open_app(environment):
    """Takes the DEV-1259 applet out of Launch Services, so no stale record outlives the run."""
    app = environment.get("ARX_APP_LINK_OPEN_FIXTURE_APP")
    if app:
        subprocess.run([LSREGISTER, "-u", app], check=False, capture_output=True)


def verify(stdout):
    lines = set(stdout.splitlines())
    missing = [marker for marker in MARKERS if marker not in lines]
    if missing:
        raise ValueError("App link smoke did not complete: " + ", ".join(missing))
