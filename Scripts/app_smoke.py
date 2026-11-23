"""Exercise the real Arx application against a local page and disposable profile."""

import functools
import hashlib
import http.server
import os
import signal
import subprocess
import tempfile
import threading
from pathlib import Path

from . import build_app
from .core import (
    app_link_smoke, bang_smoke, member_sign_in_smoke, capture_fixture, capture_smoke, developer_fixture, download_fixture, download_smoke,
    history_smoke, hover_preview_smoke, inspection_fixture, little_peek_smoke, loopback_server, site_shortcuts_smoke, media_fixture, media_smoke, page_consent_fixture,
    reference_click_fixture, reference_form_fixture, reference_scroll_fixture, reference_keypress_fixture,
    site_icon_smoke, smoke, translation_smoke, wait_fixture, external_consent_smoke, webkit_fallback_smoke,
    webkit_swipe_smoke,
)
from .core.process_smoke import ProcessProbe
from .engine.config import WORK


def prepare_automation_fixture(root):
    """Mark this fresh, owner-only profile as eligible for the native MCP fixture."""
    (root / "profile").mkdir(mode=0o700)
    descriptor = os.open(root / ".arx-mcp-smoke", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as marker:
        marker.write("Arx MCP disposable fixture v1\n")
    for suffix in ("start", "next", "private", "excluded", "revoked"):
        (root / f"mcp-{suffix}.html").write_text(
            f"<!doctype html><title>Arx MCP {suffix}</title><p>Controlled MCP fixture.</p>"
        )


def prepare_page_menus(root):
    """PageMenusSmoke (DEV-815, DEV-819): a page with a link to right-click."""
    (root / "page-menus.html").write_text(
        "<!doctype html><title>Arx page menus</title><style>body{margin:0}"
        "a{position:absolute;left:40px;top:160px;width:400px;height:120px;display:block;font:40px system-ui}</style>"
        # Arx's link menu takes only links on their scheme's default port, so the link
        # names port 80, where nothing listens: the menu needs the address, not the page.
        "<a href=\"http://127.0.0.1/page-menus-target.html\">Link target</a>"
    )


def page_menus_environment():
    """The bytes Save Page As must write for the loading PDF."""
    return {"ARX_SAVE_PAGE_SMOKE_PDF_SHA256": hashlib.sha256(inspection_fixture.pdf_document()).hexdigest()}


# Printed by the app (AppFeature's smokes) on stdout; a test checks each is still printed somewhere.
STDOUT_MARKERS = (
    "ARX_APP_SMOKE_SUCCESS", "ARX_APP_REOPEN_SMOKE_SUCCESS",
    "ARX_PROFILE_ISOLATION_SMOKE_SUCCESS", "ARX_CACHE_RELOAD_SMOKE_SUCCESS",
    "ARX_HISTORY_SMOKE_SUCCESS", "ARX_PROFILE_HISTORY_SMOKE_SUCCESS",
    "ARX_TAB_MOVE_SMOKE_SUCCESS", "ARX_SHARED_FAVORITE_SMOKE_SUCCESS", "ARX_INDEPENDENT_WINDOW_SMOKE_SUCCESS", "ARX_MCP_NATIVE_SMOKE_SUCCESS", "ARX_DOWNLOAD_SMOKE_SUCCESS",
    "ARX_MCP_ORGANIZATION_NATIVE_SMOKE_SUCCESS", "ARX_MCP_HOST_NATIVE_SMOKE_SUCCESS",
    "ARX_MCP_CAPTURE_NATIVE_SMOKE_SUCCESS",
    "ARX_APP_DOCUMENT_CAPTURE_SMOKE_SUCCESS", "ARX_MCP_DOCUMENT_CAPTURE_NATIVE_SMOKE_SUCCESS",
    "ARX_MCP_INSPECTION_NATIVE_SMOKE_SUCCESS",
    "ARX_MCP_CLICK_NATIVE_SMOKE_SUCCESS",
    "ARX_MCP_FORM_NATIVE_SMOKE_SUCCESS",
    "ARX_MCP_KEYPRESS_NATIVE_SMOKE_SUCCESS",
    "ARX_MCP_SCROLL_NATIVE_SMOKE_SUCCESS",
    "ARX_MCP_WAIT_NATIVE_SMOKE_SUCCESS",
    "ARX_MCP_DOWNLOAD_NATIVE_SMOKE_SUCCESS",
    "ARX_MCP_SETTINGS_NATIVE_SMOKE_SUCCESS",
    "ARX_MCP_DEVELOPER_NATIVE_SMOKE_SUCCESS", "ARX_MCP_PASSWORD_SIGN_IN_PHASE_NO_SAVED_PASSWORD",
    "ARX_ARCHIVE_SELECTED_SMOKE_SUCCESS", "ARX_ARCHIVE_CROSS_PROFILE_SMOKE_SUCCESS",
    "ARX_PRIVATE_DOWNLOAD_REOPEN_SMOKE_SUCCESS",
    "ARX_SPLIT_SMOKE_SUCCESS", "ARX_PAGE_DROP_SPLIT_SMOKE_SUCCESS", "ARX_PAGE_DROP_TARGETS_SMOKE_SUCCESS", "ARX_TAB_TEAR_OFF_SMOKE_SUCCESS",
    "ARX_PEEK_SMOKE_SUCCESS",
    "ARX_PRIVATE_PROFILE_SMOKE_SUCCESS", "ARX_SHORTCUTS_SMOKE_SUCCESS",
    "ARX_LITTLE_PROMOTION_SMOKE_SUCCESS", "ARX_RENDERER_RECOVERY_SMOKE_SUCCESS",
    "ARX_ROUTING_PROFILE_PICKER_SMOKE_SUCCESS",
    "ARX_PAGE_MENUS_SMOKE_LINK_ITEMS", "ARX_PAGE_MENUS_SMOKE_LINK_NEW_WINDOW",
    "ARX_PAGE_MENUS_SMOKE_SAVE_LOADING_PDF",
    # DEV-987: a local file opened with Arx lands in Little Arx, never a Chromium window.
    "ARX_LOCAL_FILE_SMOKE_SUCCESS",
)
STDERR_MARKERS = (
    "ARX_BOOTSTRAP_ENTRY ", "ARX_BOOTSTRAP_REGISTERED", "ARX_BOOTSTRAP_FRAMEWORK_VERIFIED",
)


def verify_result(result, log):
    missing = [marker for marker in STDOUT_MARKERS if marker not in result.stdout]
    missing += [marker for marker in STDERR_MARKERS if marker not in result.stderr]
    if result.returncode or missing:
        details = f" (exit {result.returncode})" if result.returncode else ""
        details += f"; missing {', '.join(missing)}" if missing else ""
        raise ValueError(f"Arx smoke failed{details}; inspect {log}")
    media_smoke.verify(result.stdout)
    site_icon_smoke.verify(result.stdout)
    little_peek_smoke.verify(result.stdout)
    site_shortcuts_smoke.verify(result.stdout)
    app_link_smoke.verify(result.stdout)
    member_sign_in_smoke.verify(result.stdout)
    bang_smoke.verify(result.stdout)
    hover_preview_smoke.verify(result.stdout)
    translation_smoke.verify(result.stdout)


def terminate_smoke_renderers(process, request, stopped, errors):
    """Crash only renderer children of this runner's disposable Arx process."""
    try:
        while process.poll() is None and not stopped.wait(0.05):
            if not request.exists():
                continue
            listing = subprocess.run(
                ["pgrep", "-P", str(process.pid)], capture_output=True, text=True, check=False
            )
            for candidate in listing.stdout.split():
                details = subprocess.run(
                    ["ps", "-p", candidate, "-o", "ppid=,args="],
                    capture_output=True, text=True, check=False,
                ).stdout.strip().split(maxsplit=1)
                if (len(details) == 2 and details[0] == str(process.pid)
                        and "--type=renderer" in details[1]):
                    try:
                        os.kill(int(candidate), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            return
    except Exception as error:
        errors.append(str(error))


def main():
    with smoke.log("app-smoke") as log:
        run(log)


# How long the Arx process may run. With a real display the window phases take longer than
# headless: Space transitions for PiP over another app's full-screen window (DEV-962), page full
# screen in and out (DEV-949), Page PiP. Runs that reached the media phases used nearly all of
# the old 180 s before the later phases could run (DEV-965).
SMOKE_TIMEOUT_SECONDS = 420


def run(log, external_consent=False):
    if os.environ.get("CONFIGURATION", "Debug") != "Debug":
        raise ValueError("app-smoke uses the Debug development configuration")
    app = build_app.main(log="app-smoke-build.log", signed=True, require_engine=True)
    WORK.mkdir(parents=True, exist_ok=True)
    # A worktree may link .build/engine to a shared tree; fixtures want the canonical root.
    # The app-link applet lives on the startup disk: built inside a checkout on an external drive,
    # each run's new applet would need macOS's removable-volume permission to write its record.
    with (
        tempfile.TemporaryDirectory(prefix="app-smoke-", dir=WORK.resolve()) as directory,
        tempfile.TemporaryDirectory(prefix="arx-app-link-") as app_link_directory,
        # DEV-1259: Launch Services ignores an app in the temporary folder for its schemes.
        tempfile.TemporaryDirectory(
            prefix="arx-app-link-open-", dir=app_link_smoke.open_app_parent(WORK.resolve())
        ) as app_link_open_directory,
    ):
        root = Path(directory)
        prepare_automation_fixture(root)
        downloads_environment = download_smoke.prepare(root, root / "profile")
        media_environment = media_smoke.prepare(root) | media_smoke.build_full_screen_host(root)
        site_icon_environment = site_icon_smoke.prepare(root)
        little_peek_smoke.prepare(root)
        site_shortcuts_smoke.prepare(root)  # DEV-1264, DEV-1073
        app_link_smoke.prepare(root)
        member_sign_in_smoke.prepare(root)
        app_link_environment = app_link_smoke.prepare_app(Path(app_link_directory))
        # DEV-1259: an applet Launch Services knows for a scheme no handler takes.
        app_link_environment |= app_link_smoke.prepare_open_app(Path(app_link_open_directory))
        # DEV-877: overnight only, since it starts WebKit's processes.
        webkit_environment = webkit_fallback_smoke.prepare(root) if webkit_fallback_smoke.enabled() else {}
        # DEV-1203: overnight only, like the fallback phase: Arx's swipe on a WebKit page.
        webkit_swipe_environment = webkit_swipe_smoke.prepare(root) if webkit_swipe_smoke.enabled() else {}
        prepare_page_menus(root)
        page_consent_fixture.prepare(root)
        (root / "index.html").write_text(
            "<!doctype html><title>Arx app smoke</title>"
            "<style>body{font:32px system-ui;background:#edf5ff;padding:64px}</style>"
            "<h1>Arx Chromium integration</h1><p>This page is rendered by Helium.</p>"
        )
        hover_preview_smoke.prepare(root)
        translation_smoke.prepare(root)
        (root / "identity.html").write_text(
            "<!doctype html><script>"
            "const identity = new URLSearchParams(location.search).get('set');"
            "if (identity) { localStorage.setItem('identity', identity); document.cookie = 'identity=' + identity + '; path=/'; }"
            "const cookie = document.cookie.split('; ').find(x => x.startsWith('identity='));"
            "document.title = (localStorage.getItem('identity') || 'empty') + '|' + (cookie ? cookie.split('=')[1] : 'empty');"
            "</script>"
        )
        external_handler = None
        class FixtureHandler(http.server.SimpleHTTPRequestHandler):
            cache_requests = 0

            def do_POST(self):
                if member_sign_in_smoke.serve_post(self):
                    return
                self.send_error(404)

            def do_GET(self):
                if page_consent_fixture.serve(self):
                    return
                if bang_smoke.serve(self):
                    return
                if download_fixture.serve(self):
                    return
                if developer_fixture.serve(self):
                    return
                if reference_scroll_fixture.serve(self):
                    return
                if reference_keypress_fixture.serve(self):
                    return
                if reference_form_fixture.serve(self):
                    return
                if reference_click_fixture.serve(self):
                    return
                if wait_fixture.serve(self):
                    return
                if inspection_fixture.serve(self):
                    return
                if capture_fixture.serve(self):
                    return
                if media_fixture.serve(self):
                    return
                if site_icon_smoke.serve(self):
                    return
                if self.path != "/cache.html":
                    return super().do_GET()
                type(self).cache_requests += 1
                body = f"<!doctype html><title>Cache {type(self).cache_requests}</title>".encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "max-age=3600")
                self.end_headers()
                self.wfile.write(body)

        handler = functools.partial(FixtureHandler, directory=directory)
        # On ::1 too: phases open fixture pages on `localhost` (DEV-1000).
        loopback = loopback_server.LoopbackServer(handler)
        server = loopback.server
        server.site_icon_requests = []
        wait_fixture.prepare(server)
        loopback.start()
        icon_origin, icon_thread, icon_environment = site_icon_smoke.start_icon_origin()
        site_icon_environment.update(icon_environment)
        try:
            if external_consent:
                external_handler = external_consent_smoke.prepare(root, app)
            crash_request = root / "crash-renderer.request"
            env = dict(os.environ, ARX_ENGINE_PROFILE=str(root / "profile"),
                       ARX_MCP_SMOKE_ROOT=str(root),
                       ARX_ENGINE_SMOKE_CRASH_REQUEST=str(crash_request),
                       ARX_ENGINE_URL=f"http://127.0.0.1:{server.server_port}/index.html",
                       ARX_ENGINE_SMOKE_TITLE="Arx app smoke")
            env.update(downloads_environment)
            env.update(media_environment)
            env.update(site_icon_environment)
            env.update(app_link_environment)
            env.update(webkit_environment)
            env.update(webkit_swipe_environment)
            env.update(capture_smoke.environment())
            env.update(developer_fixture.environment())
            env.update(page_menus_environment())
            if external_handler:
                env.update(external_handler.environment)
            stopped = threading.Event()
            errors = []
            process_probe = ProcessProbe(app)
            arguments = [str(app / "Contents/MacOS/Arx")]
            if external_handler:
                arguments += ["--arx-external-consent-smoke-root", str(root)]
            with subprocess.Popen(
                arguments,
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            ) as process:
                crash_thread = threading.Thread(
                    target=terminate_smoke_renderers,
                    args=(process, crash_request, stopped, errors),
                    daemon=True,
                )
                crash_thread.start()
                probe_thread = threading.Thread(target=process_probe.monitor, args=(process, stopped), daemon=True)
                probe_thread.start()
                try:
                    stdout, stderr = process.communicate(timeout=SMOKE_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired as error:
                    process.kill()
                    stdout, stderr = process.communicate()
                    smoke.append(log, stdout, stderr)
                    raise ValueError(f"Arx smoke timed out; inspect {log}") from error
                finally:
                    stopped.set()
                    crash_thread.join()
                    probe_thread.join()
                result = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
            smoke.append(log, result.stdout, result.stderr)
            if errors:
                raise ValueError(f"Renderer crash injection failed: {errors}")
            verify_result(result, log)
            if webkit_environment:
                webkit_fallback_smoke.verify(result.stdout)
            if webkit_swipe_environment:
                webkit_swipe_smoke.verify(result.stdout)
            if external_handler:
                external_consent_smoke.verify(root, result.stdout, result.stderr)
                env.pop("ARX_EXTERNAL_CONSENT_FIXTURE_ROOT", None)
            download_smoke.verify(root / "profile", downloads_environment)
            capture_smoke.verify(result.stdout)
            if not server.site_icon_requests or not all(authorized for _, authorized in server.site_icon_requests):
                raise ValueError("Site icons were not fetched through authenticated browser profiles")
            site_icon_smoke.verify_fetch(icon_origin.site_icon_fetch_requests)
            history_smoke.verify(root / "profile", env["ARX_ENGINE_URL"])
            process_evidence = process_probe.verify()
            smoke.append(log, process_evidence + "\n", "")
            site_icon_smoke.restart(app, env, server, log, icon_origin)
            download_smoke.restart(app, env, server, log)
            print(f"Arx loaded the fixture, verified window lifecycle, split panes, page drops, Peek and profile isolation, promoted Little Arx, recovered a terminated renderer, and shut down. Log: {log}")
        finally:
            app_link_smoke.unregister_open_app(app_link_environment)
            try:
                if external_handler:
                    external_handler.cleanup()
            finally:
                site_icon_smoke.stop_icon_origin(icon_origin, icon_thread)
                wait_fixture.release(server)
                loopback.stop()
