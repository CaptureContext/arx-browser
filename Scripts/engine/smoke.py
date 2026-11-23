"""Load a local fixture through real Chromium with a disposable profile."""

import functools
import http.server
import os
import secrets
import subprocess
import tempfile
import threading
from pathlib import Path
from urllib.parse import urlsplit

from ..core import back_forward_cache_fixture, background_visibility_fixture, media_fixture, cross_site_link_fixture, focused_link_fixture, password_fixture, gesture_fixture, document_capture_fixture, link_context_fixture, inspection_fixture, reference_click_fixture, reference_form_fixture, reference_scroll_fixture, reference_keypress_fixture, smoke
from . import host
from .config import WORK


def main():
    with smoke.log("engine-smoke") as log:
        run(log)


def keeps_content_blocking(*, extensions=False, extension_install=False, site_settings=False):
    """Whether a smoke runs with Arx's content blocking, Helium's uBlock Origin (DEV-884).

    Only the smokes that test it keep it: the extension smokes, where uBlock is one
    of the profile's extensions, and site settings, whose Ads step is uBlock's
    per-site switch. On a fresh profile uBlock reloads itself once after its first
    run and then selects and updates lists from the network, so the others would
    race it: reference-keypress-smoke lost a report request to that reload.
    """
    return extensions or extension_install or site_settings


def run(log, *, passwords=False, extension_install=False, extensions=False, authorized_close=False, hang=False, inspection=False, reference_click=False, reference_form=False, reference_scroll=False, link_context=False, document_capture=False, gestures=False, reference_keypress=False, focused_link=False, site_settings=False, browsing_data=False, cross_site_link=False, background_visibility=False, back_forward_cache=False):
    if sum((passwords, extension_install, extensions, authorized_close, hang, inspection, reference_click, reference_form, reference_scroll, link_context, document_capture, gestures, reference_keypress, focused_link, site_settings, browsing_data, cross_site_link, background_visibility, back_forward_cache)) > 1:
        raise ValueError("Choose one isolated native fixture")
    host.main(native_messaging_fixture=extensions)
    with tempfile.TemporaryDirectory(prefix="smoke-", dir=WORK.resolve()) as directory:
        root = Path(directory)
        root.chmod(0o700)
        (root / ".arx-engine-smoke").write_text("Arx disposable engine smoke\n")
        (root / "index.html").write_text("<!doctype html><title>Arx engine smoke</title><h1>Arx Chromium bridge</h1>")
        handler_class = (HangHandler if hang else BackForwardCacheHandler if back_forward_cache else BackgroundVisibilityHandler if background_visibility else CrossSiteLinkHandler if cross_site_link else FocusedLinkHandler if focused_link else PasswordHandler if passwords else ExtensionInstallHandler if extension_install else ReferenceKeypressHandler if reference_keypress else GestureHandler if gestures else DocumentCaptureHandler if document_capture else LinkContextHandler if link_context else ReferenceScrollHandler if reference_scroll else ReferenceFormHandler if reference_form else ReferenceClickHandler if reference_click else
                         InspectionHandler if inspection else BrowsingDataHandler if browsing_data else ExtensionsHandler if extensions else http.server.SimpleHTTPRequestHandler)
        handler = functools.partial(handler_class, directory=directory)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            probe = "arxprobe" + secrets.token_hex(12)
            password_fixture.reset(probe)
            env = dict(os.environ, ARX_ENGINE_PROFILE=str(root / "profile"),
                       ARX_ENGINE_URL=f"http://127.0.0.1:{server.server_port}/index.html",
                       ARX_ENGINE_SMOKE_TITLE="Arx engine smoke",
                       ARX_ENGINE_CONTENT_BLOCKING="1" if keeps_content_blocking(
                           extensions=extensions, extension_install=extension_install,
                           site_settings=site_settings) else "0")
            try:
                arguments = [str(host.APP / "Contents/MacOS/ChromiumHost"),
                             "--disposable-smoke-root", str(root)]
                if passwords:
                    env["ARX_PASSWORD_PROBE"] = probe
                    arguments.append("--password-fixture")
                if extension_install:
                    arguments.append("--extension-install-fixture")
                if extensions:
                    arguments.append("--extension-fixture")
                if authorized_close:
                    arguments.append("--close-fixture")
                if hang:
                    arguments.append("--hang-fixture")
                if inspection:
                    arguments.append("--inspection-fixture")
                if reference_click:
                    arguments.append("--reference-click-fixture")
                if reference_keypress:
                    arguments.append("--reference-keypress-fixture")
                if reference_form:
                    arguments.append("--reference-form-fixture")
                if reference_scroll:
                    arguments.append("--reference-scroll-fixture")
                if link_context:
                    arguments.append("--link-context-fixture")
                if focused_link:
                    arguments.append("--focused-link-fixture")
                if cross_site_link:
                    arguments.append("--cross-site-link-fixture")
                if back_forward_cache:
                    back_forward_cache_fixture.reset()
                    arguments.append("--back-forward-cache-fixture")
                if site_settings:
                    arguments.append("--site-settings-fixture")
                if browsing_data:
                    arguments.append("--browsing-data-fixture")
                if document_capture:
                    arguments.append("--document-capture-fixture")
                if gestures:
                    arguments.append("--gesture-fixture")
                if background_visibility:
                    arguments.append("--background-visibility-fixture")
                result = subprocess.run(arguments, env=env, capture_output=True,
                                        text=True, timeout=240 if passwords else 180 if extension_install or extensions or authorized_close or hang or inspection or reference_click or reference_form or reference_scroll or link_context or document_capture or gestures or reference_keypress or focused_link or site_settings or browsing_data or cross_site_link or background_visibility or back_forward_cache else 60)
            except subprocess.TimeoutExpired as error:
                smoke.append(log, error.stdout, error.stderr)
                if back_forward_cache:
                    smoke.append(log, back_forward_cache_fixture.request_log())
                raise ValueError(f"Chromium smoke timed out; inspect {log}") from error
            smoke.append(log, result.stdout, result.stderr)
            if back_forward_cache:
                smoke.append(log, back_forward_cache_fixture.request_log())
            success = "ARX_EXTENSION_SMOKE_SUCCESS" if extensions else "ARX_ENGINE_SMOKE_SUCCESS"
            markers = ["ARX_EXTENSION_FIXTURE_OWNED_STORAGE", "ARX_EXTENSION_SMOKE_WORKER_DNR",
                       "ARX_EXTENSION_SMOKE_DISABLE_ENABLE_STALE", "ARX_EXTENSION_SMOKE_PROFILE_ISOLATION",
                       "ARX_EXTENSION_SMOKE_OPTIONS_IDENTITY", "ARX_EXTENSION_SMOKE_OPTIONS_STALE",
                       "ARX_EXTENSION_SMOKE_ACTION_IDENTITY", "ARX_EXTENSION_SMOKE_ACTION_STALE", "ARX_EXTENSION_SMOKE_POPUP_LINK", "ARX_EXTENSION_SMOKE_RUNTIME_OPTIONS",
                       "ARX_EXTENSION_SMOKE_APP_ACTION", "ARX_EXTENSION_SMOKE_BUTTON_INVISIBLE",
                       # DEV-1316: the action popup in a window of its own.
                       "ARX_EXTENSION_SMOKE_POPUP_WINDOW",
                       "ARX_EXTENSION_SMOKE_SHORTCUT_SCOPE", "ARX_EXTENSION_SMOKE_SHORTCUT_REPLAY",
                       # DEV-974: a shortcut pressed before the renderer reports focus.
                       "ARX_EXTENSION_SMOKE_SHORTCUT_WITHOUT_FOCUS_WAIT",
                       "ARX_EXTENSION_SMOKE_TABS_SCOPE", "ARX_EXTENSION_SMOKE_WINDOW_SCOPE",
                       "ARX_EXTENSION_SMOKE_NATIVE_MESSAGING_SCOPE", "ARX_EXTENSION_SMOKE_NATIVE_MESSAGING_LIFECYCLE",
                       "ARX_EXTENSION_SMOKE_PRIVATE_ACTION", "ARX_EXTENSION_SMOKE_PRIVATE_MENU", "ARX_EXTENSION_SMOKE_PRIVATE_GATE",
                       "ARX_EXTENSION_SMOKE_PERMISSION_GUARD", "ARX_EXTENSION_SMOKE_REMOVE_ISOLATION", "ARX_EXTENSION_SMOKE_ELEMENT_PICKER",
                       "ARX_EXTENSION_SMOKE_SITE_HIDING", "ARX_EXTENSION_SMOKE_SCRIPTLET",
                       "ARX_EXTENSION_SMOKE_OWN_ELEMENT_PICKER", "ARX_EXTENSION_SMOKE_HIDE_ELEMENT_MODE",
                       "ARX_EXTENSION_SMOKE_PRIVATE_DENIED", "ARX_EXTENSION_SMOKE_VERIFIED"] if extensions else ["ARX_ENGINE_SMOKE_FIND_VERIFIED"]
            if passwords:
                success = "ARX_PASSWORD_SMOKE_SUCCESS"
                markers = PASSWORD_MARKERS
                leaks = password_leaks(probe, root, log, result.stdout, result.stderr)
                if leaks:
                    raise ValueError("The probe password leaked into " + ", ".join(leaks) + f"; inspect {log}")
            if extension_install:
                success = "ARX_EXTENSION_INSTALL_SMOKE_SUCCESS"
                markers = EXTENSION_INSTALL_MARKERS
            if hang:
                success = "ARX_HANG_SMOKE_SUCCESS"
                markers = ["ARX_HANG_SMOKE_REPORTED", "ARX_HANG_SMOKE_WAIT_ASKS_AGAIN", "ARX_HANG_SMOKE_TIMEOUT_LETS_GO", "ARX_HANG_SMOKE_ENDED",
                           "ARX_HANG_SMOKE_RELOADED", "ARX_HANG_SMOKE_VERIFIED"]
            if authorized_close:
                success = "ARX_CLOSE_SMOKE_SUCCESS"
                markers = ["ARX_CLOSE_SMOKE_CANCEL_OTHER_PAGE", "ARX_CLOSE_SMOKE_NAVIGATION_STALE",
                           "ARX_CLOSE_SMOKE_RELOAD_STALE", "ARX_CLOSE_SMOKE_CONSUMED_ONCE",
                           "ARX_CLOSE_SMOKE_VERIFIED"]
            if inspection:
                success = "ARX_INSPECTION_SMOKE_SUCCESS"
                markers = INSPECTION_MARKERS
            if reference_click:
                success = "ARX_REFERENCE_CLICK_SMOKE_SUCCESS"
                markers = REFERENCE_CLICK_MARKERS
            if reference_keypress:
                success = "ARX_REFERENCE_KEYPRESS_SMOKE_SUCCESS"
                markers = REFERENCE_KEYPRESS_MARKERS
            if reference_form:
                success = "ARX_REFERENCE_FORM_SMOKE_SUCCESS"
                markers = REFERENCE_FORM_MARKERS
            if reference_scroll:
                success = "ARX_REFERENCE_SCROLL_SMOKE_SUCCESS"
                markers = REFERENCE_SCROLL_MARKERS
            if link_context:
                success = "ARX_LINK_CONTEXT_SMOKE_SUCCESS"
                markers = LINK_CONTEXT_MARKERS
            if focused_link:
                success = "ARX_FOCUSED_LINK_SMOKE_SUCCESS"
                markers = FOCUSED_LINK_MARKERS
            if cross_site_link:
                success = "ARX_CROSS_SITE_LINK_SMOKE_SUCCESS"
                markers = CROSS_SITE_LINK_MARKERS
            if back_forward_cache:
                success = "ARX_BACK_FORWARD_CACHE_SMOKE_SUCCESS"
                markers = BACK_FORWARD_CACHE_MARKERS
            if site_settings:
                success = "ARX_SITE_SETTINGS_SMOKE_SUCCESS"
                markers = SITE_SETTINGS_MARKERS
            if browsing_data:
                success = "ARX_BROWSING_DATA_SMOKE_SUCCESS"
                markers = BROWSING_DATA_MARKERS
            if document_capture:
                success = "ARX_DOCUMENT_CAPTURE_SMOKE_SUCCESS"
                markers = DOCUMENT_CAPTURE_MARKERS
            if gestures:
                success = "ARX_GESTURE_SMOKE_SUCCESS"
                markers = GESTURE_MARKERS
            if background_visibility:
                success = "ARX_BACKGROUND_VISIBILITY_SMOKE_SUCCESS"
                markers = BACKGROUND_VISIBILITY_MARKERS
            if (result.returncode or success not in result.stdout.splitlines()
                    or "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN" not in result.stderr.splitlines()):
                failure = failure_line(result.stderr, BACK_FORWARD_CACHE_FAILED) if back_forward_cache else None
                raise ValueError(f"Chromium smoke failed{f': {failure}' if failure else ''}; inspect {log}")
            if any(marker not in result.stderr.splitlines() for marker in markers):
                raise ValueError(f"Chromium smoke failed; missing native fixture evidence; inspect {log}")
            if (extension_install or extensions or document_capture or gestures) and (root / "profile").exists():
                raise ValueError(f"Native fixture used caller-supplied storage; inspect {log}")
            print(f"Chromium loaded the disposable mock-Keychain fixture and shut down; this does not validate production Keychain persistence/security. Log: {log}")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


class ExtensionsHandler(http.server.SimpleHTTPRequestHandler):
    """Serves the extensions smoke's uBlock fixtures (DEV-1019) from memory: on the blocking
    page a site filter hides the first element and a scriptlet takes the second's class away;
    on the picker page (DEV-1201), which allows no scripts or styles, Arx's own element picker
    picks the aside.

    The host accepts a smoke root holding only `index.html` and its marker.
    """
    BLOCKING = (b"<!doctype html><title>Arx blocking fixture</title>"
                b"<div id=arx-hidden class=arx-hide-target>hidden by a site filter</div>"
                b"<div id=arx-scriptlet class=arx-scriptlet-probe>changed by a scriptlet</div>")
    PICKER = (b"<!doctype html><title>Arx picker fixture</title>"
              b"<main><p>Stays on the page</p>"
              b"<aside class=arx-pick-target><h2>Picked by the element picker</h2></aside>"
              b"<div class=arx-mode-undo>Hidden, then shown again</div>"
              b"<footer class=arx-mode-target>Hidden in Hide Element's mode</footer></main>")
    PICKER_POLICY = "default-src 'none'; script-src 'none'; style-src 'none'"

    def do_GET(self):
        path = urlsplit(self.path).path
        if path in ("/blocking.html", "/picker.html"):
            body = self.BLOCKING if path == "/blocking.html" else self.PICKER
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            if path == "/picker.html":
                self.send_header("Content-Security-Policy", self.PICKER_POLICY)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()


INSPECTION_MARKERS = [
    "ARX_INSPECTION_SMOKE_SEMANTICS_PRIVACY", "ARX_INSPECTION_SMOKE_LIMIT_SCOPE",
    "ARX_INSPECTION_SMOKE_DOM_INVALIDATION", "ARX_INSPECTION_SMOKE_NAVIGATION_RELOAD_HISTORY",
    "ARX_INSPECTION_SMOKE_CANCEL_CLOSE", "ARX_INSPECTION_SMOKE_PRIVATE_UNSUPPORTED",
    "ARX_INSPECTION_SMOKE_EXPIRED", "ARX_INSPECTION_SMOKE_WINDOWS", "ARX_INSPECTION_SMOKE_FRAMES",
    "ARX_INSPECTION_SMOKE_FORM_VALUES", "ARX_INSPECTION_SMOKE_OFFSCREEN", "ARX_INSPECTION_SMOKE_PDF", "ARX_INSPECTION_SMOKE_PDF_LOADING", "ARX_INSPECTION_SMOKE_SAVE_PAGE", "ARX_INSPECTION_SMOKE_VIEW_SOURCE", "ARX_INSPECTION_SMOKE_OPEN_FILE",
    "ARX_INSPECTION_SMOKE_POINTER_HOVER", "ARX_INSPECTION_SMOKE_POINTER_CLICK", "ARX_INSPECTION_SMOKE_POINTER_DRAG",
    "ARX_INSPECTION_SMOKE_KEYBOARD_TYPE", "ARX_INSPECTION_SMOKE_KEYBOARD_REDIRECT", "ARX_INSPECTION_SMOKE_KEYBOARD_KEYS",
    "ARX_INSPECTION_SMOKE_FORM_STATE_CHECKED", "ARX_INSPECTION_SMOKE_FORM_STATE_SELECT",
    "ARX_INSPECTION_SMOKE_UPLOAD",
    "ARX_INSPECTION_SMOKE_DIALOGS_JAVASCRIPT", "ARX_INSPECTION_SMOKE_DIALOGS_BEFORE_UNLOAD",
    "ARX_INSPECTION_SMOKE_DIALOGS_PERMISSION",
    "ARX_INSPECTION_SMOKE_VERIFIED",
]


class BrowsingDataHandler(http.server.SimpleHTTPRequestHandler):
    """Serves the file a private page downloads (DEV-729) from memory.

    The host accepts a smoke root holding only `index.html` and its marker.
    """
    PRIVATE_DOWNLOAD = b"Arx private download fixture\n" * 64

    def do_GET(self):
        if urlsplit(self.path).path == "/arx-private-download.bin":
            # Octet-stream never renders, so the private page downloads it.
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(self.PRIVATE_DOWNLOAD)))
            self.end_headers()
            self.wfile.write(self.PRIVATE_DOWNLOAD)
            return
        super().do_GET()

    def log_message(self, *_):
        pass


class HangHandler(http.server.SimpleHTTPRequestHandler):
    """Serves DEV-1009's page from memory: with ?loop, a key makes it loop forever.

    The host accepts a smoke root holding only `index.html` and its marker.
    """
    PAGE = (b"<!doctype html><title>Arx hang</title><input autofocus><script>"
            b"if (new URLSearchParams(location.search).has('loop'))"
            b" addEventListener('keydown', () => { while (true) {} });</script>")

    def do_GET(self):
        if urlsplit(self.path).path == "/hang.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(self.PAGE)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(self.PAGE)
            return
        super().do_GET()

    def log_message(self, *_):
        pass


class InspectionHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if inspection_fixture.serve(self):
            return
        if urlsplit(self.path).path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def log_message(self, *_):
        pass


REFERENCE_CLICK_MARKERS = [
    "ARX_REFERENCE_CLICK_SMOKE_DISPATCH_REPLAY", "ARX_REFERENCE_CLICK_SMOKE_STALE_SCOPE",
    "ARX_REFERENCE_CLICK_SMOKE_PRIVATE_HIDDEN", "ARX_REFERENCE_CLICK_SMOKE_TIMEOUT_CANCEL",
    "ARX_REFERENCE_CLICK_SMOKE_NAVIGATION", "ARX_REFERENCE_CLICK_SMOKE_VERIFIED",
]


class ReferenceClickHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if reference_click_fixture.serve(self):
            return
        if urlsplit(self.path).path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def log_message(self, *_):
        pass


REFERENCE_FORM_MARKERS = [
    "ARX_REFERENCE_FORM_SMOKE_DISPATCH_REPLAY", "ARX_REFERENCE_FORM_SMOKE_UNCHANGED_OPTIONS",
    "ARX_REFERENCE_FORM_SMOKE_PROPERTY_STALE", "ARX_REFERENCE_FORM_SMOKE_PRIVACY_LIMITS",
    "ARX_REFERENCE_FORM_SMOKE_TIMEOUT_CANCEL_NAVIGATION", "ARX_REFERENCE_FORM_SMOKE_VERIFIED",
]


class ReferenceFormHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if reference_form_fixture.serve(self):
            return
        if urlsplit(self.path).path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def log_message(self, *_):
        pass


REFERENCE_SCROLL_MARKERS = [
    "ARX_REFERENCE_SCROLL_SMOKE_NESTED_REPLAY_CLAMP", "ARX_REFERENCE_SCROLL_SMOKE_AXES_CONTAINERS",
    "ARX_REFERENCE_SCROLL_SMOKE_PRIVACY_LIFETIME", "ARX_REFERENCE_SCROLL_SMOKE_NAVIGATION",
    "ARX_REFERENCE_SCROLL_SMOKE_VERIFIED",
]


class ReferenceScrollHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if reference_scroll_fixture.serve(self):
            return
        if urlsplit(self.path).path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def log_message(self, *_):
        pass


LINK_CONTEXT_MARKERS = [
    "ARX_LINK_CONTEXT_SMOKE_SOURCE_AND_ROOT_COORDINATES",
    "ARX_LINK_CONTEXT_SMOKE_SOURCE_FRAME_STALE",
    "ARX_LINK_CONTEXT_SMOKE_REPLACEMENT_NAVIGATION_STALE",
    "ARX_LINK_CONTEXT_SMOKE_PRIVATE_CLOSE",
    # DEV-851: Download Linked File sends its page as the referrer.
    "ARX_LINK_CONTEXT_SMOKE_DOWNLOAD_REFERRER",
    # DEV-853: every link gets the menu, as in Chromium.
    "ARX_LINK_CONTEXT_SMOKE_NONDEFAULT_PORT", "ARX_LINK_CONTEXT_SMOKE_MAILTO",
    # ABI48 (DEV-814, DEV-818) context menus.
    "ARX_LINK_CONTEXT_SMOKE_MENU_TEXT_FIELD", "ARX_LINK_CONTEXT_SMOKE_MENU_PASSWORD",
    "ARX_LINK_CONTEXT_SMOKE_MENU_SELECTION", "ARX_LINK_CONTEXT_SMOKE_MENU_IMAGE",
    "ARX_LINK_CONTEXT_SMOKE_MENU_VIDEO", "ARX_LINK_CONTEXT_SMOKE_MENU_HOST_ITEMS",
    "ARX_LINK_CONTEXT_SMOKE_MENU_PAGE_SHARE", "ARX_LINK_CONTEXT_SMOKE_VERIFIED",
]


class LinkContextHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if link_context_fixture.serve(self):
            return
        if urlsplit(self.path).path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def log_message(self, *_):
        pass


CROSS_SITE_LINK_MARKERS = [
    "ARX_CROSS_SITE_LINK_SMOKE_SAME_SITE", "ARX_CROSS_SITE_LINK_SMOKE_DECLINED",
    "ARX_CROSS_SITE_LINK_SMOKE_TAKEN", "ARX_CROSS_SITE_LINK_SMOKE_REDIRECT",
    "ARX_CROSS_SITE_LINK_SMOKE_FORM_POST", "ARX_CROSS_SITE_LINK_SMOKE_SCRIPTED",
    "ARX_CROSS_SITE_LINK_SMOKE_PRIVATE", "ARX_CROSS_SITE_LINK_SMOKE_VERIFIED",
]


class CrossSiteLinkHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if cross_site_link_fixture.serve(self):
            return
        if urlsplit(self.path).path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def do_POST(self):
        if not cross_site_link_fixture.serve(self):
            self.send_error(404)

    def log_message(self, *_):
        pass


BACK_FORWARD_CACHE_FAILED = "ARX_BACK_FORWARD_CACHE_SMOKE_FAILED"


def failure_line(stderr, prefix):
    """The host's own failure line, which names the phase and, for a timed-out wait, what it last saw."""
    return next((line for line in stderr.splitlines() if line.startswith(prefix + " ")), None)


BACK_FORWARD_CACHE_MARKERS = [
    "ARX_BACK_FORWARD_CACHE_SMOKE_FIRST_LOAD", "ARX_BACK_FORWARD_CACHE_SMOKE_LEAVE",
    "ARX_BACK_FORWARD_CACHE_SMOKE_RESTORED", "ARX_BACK_FORWARD_CACHE_SMOKE_SNAPSHOT",
    "ARX_BACK_FORWARD_CACHE_SMOKE_TITLE_HISTORY", "ARX_BACK_FORWARD_CACHE_SMOKE_ICON",
    "ARX_BACK_FORWARD_CACHE_SMOKE_FORWARD", "ARX_BACK_FORWARD_CACHE_SMOKE_MEDIA",
    "ARX_BACK_FORWARD_CACHE_SMOKE_MEDIA_SESSION", "ARX_BACK_FORWARD_CACHE_SMOKE_VERIFIED",
]


class BackForwardCacheHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if back_forward_cache_fixture.serve(self):
            return
        if urlsplit(self.path).path == back_forward_cache_fixture.VIDEO and media_fixture.serve(self):
            return
        if urlsplit(self.path).path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def log_request(self, code="-", size="-"):
        # Every answer, its status and any byte range, for the smoke's log.
        back_forward_cache_fixture.record(self.command, self.path, getattr(code, "value", code),
                                          self.headers.get("Range"))

    def log_message(self, *_):
        pass


FOCUSED_LINK_MARKERS = [
    "ARX_FOCUSED_LINK_SMOKE_MAIN_FRAME", "ARX_FOCUSED_LINK_SMOKE_SAME_ORIGIN_FRAME",
    "ARX_FOCUSED_LINK_SMOKE_CROSS_ORIGIN_FRAME", "ARX_FOCUSED_LINK_SMOKE_NOT_LINKS",
    "ARX_FOCUSED_LINK_SMOKE_STALE", "ARX_FOCUSED_LINK_SMOKE_PRIVATE_HIDDEN",
    "ARX_FOCUSED_LINK_SMOKE_VERIFIED",
]

SITE_SETTINGS_MARKERS = [
    "ARX_SITE_SETTINGS_SMOKE_LIST", "ARX_SITE_SETTINGS_SMOKE_PERMISSION", "ARX_SITE_SETTINGS_SMOKE_INVALID",
    "ARX_SITE_SETTINGS_SMOKE_DEFAULT", "ARX_SITE_SETTINGS_SMOKE_CHANGED", "ARX_SITE_SETTINGS_SMOKE_ZOOM",
    "ARX_SITE_SETTINGS_SMOKE_ISOLATION", "ARX_SITE_SETTINGS_SMOKE_PRIVATE",
    # DEV-963: site permission prompts handed to the app.
    "ARX_SITE_SETTINGS_SMOKE_HOSTED_PROMPTS",
    "ARX_SITE_SETTINGS_SMOKE_VERIFIED",
]

BROWSING_DATA_MARKERS = [
    "ARX_BROWSING_DATA_SMOKE_COUNT", "ARX_BROWSING_DATA_SMOKE_SITE", "ARX_BROWSING_DATA_SMOKE_INVALID",
    "ARX_BROWSING_DATA_SMOKE_CLEAR",
    "ARX_BROWSING_DATA_SMOKE_DOWNLOADS", "ARX_BROWSING_DATA_SMOKE_ISOLATION", "ARX_BROWSING_DATA_SMOKE_PRIVATE",
    "ARX_BROWSING_DATA_SMOKE_PRIVATE_OPENER",
    "ARX_BROWSING_DATA_SMOKE_VERIFIED",
]


class FocusedLinkHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if focused_link_fixture.serve(self):
            return
        if urlsplit(self.path).path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def log_message(self, *_):
        pass


DOCUMENT_CAPTURE_MARKERS = [
    "ARX_DOCUMENT_CAPTURE_FIXTURE_OWNED_STORAGE",
    "ARX_DOCUMENT_CAPTURE_RASTER_ALLOCATOR_VERIFIED",
    "ARX_DOCUMENT_CAPTURE_SMOKE_PIXELS_AND_STATE",
    "ARX_DOCUMENT_CAPTURE_SMOKE_CANCEL_BUSY",
    "ARX_DOCUMENT_CAPTURE_SMOKE_NAVIGATION_INVALIDATED",
    "ARX_DOCUMENT_CAPTURE_SMOKE_FRAME_CHANGED",
    "ARX_DOCUMENT_CAPTURE_SMOKE_RECORDING_LIMIT_AND_REPAINT",
    *["ARX_DOCUMENT_CAPTURE_SMOKE_VARIANT_" + mode for mode in
      ["horizontal", "fixed", "sticky", "canvas", "animation", "frame", "lazy", "loading", "zoom"]],
    "ARX_DOCUMENT_CAPTURE_SMOKE_VARIANTS_VERIFIED",
    "ARX_DOCUMENT_CAPTURE_SMOKE_LIMIT_REJECTED",
    "ARX_DOCUMENT_CAPTURE_SMOKE_VERIFIED",
]


class DocumentCaptureHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if document_capture_fixture.serve(self):
            return
        if urlsplit(self.path).path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def log_message(self, *_):
        pass


GESTURE_MARKERS = ["ARX_GESTURE_FIXTURE_OWNED_STORAGE", "ARX_GESTURE_SMOKE_VERIFIED"] + [
    "ARX_GESTURE_FIXTURE_" + name for name in [
        "BACK_ONE", "FORWARD_ONE", "CANCEL", "PARTIAL", "INVERTED", "BOUNDARY",
        "CSS_CONTAIN", "CONTENT_SCROLL", "SCRUBBER_DIRECT", "REVERSE", "ESCAPE",
        "HISTORY_CHANGED", "NAVIGATION_INVALIDATED", "DETACH", "RETREAT",
        "UNFOCUSED_SCROLL_BACK",
    ]
]


# DEV-936. SHOWN_MS is reported beside FIRST_SHOW but isn't a fixed marker.
BACKGROUND_VISIBILITY_MARKERS = [
    "ARX_BACKGROUND_VISIBILITY_SMOKE_STARTS_HIDDEN", "ARX_BACKGROUND_VISIBILITY_SMOKE_THROTTLED",
    "ARX_BACKGROUND_VISIBILITY_SMOKE_FROZEN", "ARX_BACKGROUND_VISIBILITY_SMOKE_FIRST_SHOW",
    "ARX_BACKGROUND_VISIBILITY_SMOKE_VERIFIED",
]


class BackgroundVisibilityHandler(http.server.SimpleHTTPRequestHandler):
    """Serves the visibility pages and their beacons from memory, and only the initial index."""
    def do_GET(self):
        if background_visibility_fixture.serve(self):
            return
        if urlsplit(self.path).path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def do_POST(self):
        if not background_visibility_fixture.serve(self):
            self.send_error(404)

    def log_message(self, *_):
        pass


class GestureHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if gesture_fixture.serve(self):
            return
        if urlsplit(self.path).path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def log_message(self, *_):
        pass


REFERENCE_KEYPRESS_MARKERS = [
    "ARX_REFERENCE_KEYPRESS_SMOKE_EDITING_REPLAY", "ARX_REFERENCE_KEYPRESS_SMOKE_HOSTILE_DEFAULTS",
    "ARX_REFERENCE_KEYPRESS_SMOKE_SUPPRESSION_SUBMISSION", "ARX_REFERENCE_KEYPRESS_SMOKE_CANCEL_FOCUS",
    "ARX_REFERENCE_KEYPRESS_SMOKE_VERIFIED",
]


class ReferenceKeypressHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if reference_keypress_fixture.serve(self):
            return
        if urlsplit(self.path).path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def log_message(self, *_):
        pass


EXTENSION_INSTALL_MARKERS = [
    "ARX_EXTENSION_INSTALL_FIXTURE_OWNED_STORAGE",
    "ARX_EXTENSION_INSTALL_SMOKE_VERIFIED_DECLINED",
    "ARX_EXTENSION_INSTALL_SMOKE_CRX_WORKER_DNR",
    "ARX_EXTENSION_INSTALL_SMOKE_ESCALATION_DECLINED",
    "ARX_EXTENSION_INSTALL_SMOKE_UPDATE_STORAGE_PRESERVED",
    "ARX_EXTENSION_INSTALL_SMOKE_SIGNATURE_ID_GUARDS",
    "ARX_EXTENSION_INSTALL_SMOKE_CANCEL_DRAINED",
    "ARX_EXTENSION_INSTALL_SMOKE_PROFILE_ISOLATION",
    "ARX_EXTENSION_INSTALL_SMOKE_PRIVATE_DENIED",
    "ARX_EXTENSION_INSTALL_SMOKE_VERIFIED",
]


class ExtensionInstallHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def log_message(self, *_):
        pass


PASSWORD_MARKERS = [
    "ARX_PASSWORD_SMOKE_SAVE_FILL", "ARX_PASSWORD_SMOKE_TWO_FACTOR", "ARX_PASSWORD_SMOKE_FRAME",
    "ARX_PASSWORD_SMOKE_FILL_REFUSED", "ARX_PASSWORD_SMOKE_FILL_SIGNED_IN", "ARX_PASSWORD_SMOKE_FILL_KEYBOARD",
    "ARX_PASSWORD_SMOKE_FILL_ESCAPE", "ARX_PASSWORD_SMOKE_FILL_PRIVATE",
    "ARX_PASSWORD_SMOKE_FRAME_SWAP", "ARX_PASSWORD_SMOKE_ORIGIN_SWAP", "ARX_PASSWORD_SMOKE_NEVER",
    "ARX_PASSWORD_SMOKE_PROFILE_ISOLATION", "ARX_PASSWORD_SMOKE_PRIVATE", "ARX_PASSWORD_SMOKE_REJECTED",
    "ARX_PASSWORD_SMOKE_SETTINGS_LIST", "ARX_PASSWORD_SMOKE_SETTINGS_EDIT", "ARX_PASSWORD_SMOKE_SETTINGS_ADD",
    "ARX_PASSWORD_SMOKE_SETTINGS_REMOVE", "ARX_PASSWORD_SMOKE_SETTINGS_REVEAL_GATE",
    "ARX_PASSWORD_SMOKE_CSV_CHROME", "ARX_PASSWORD_SMOKE_CSV_APPLE", "ARX_PASSWORD_SMOKE_CSV_FORMAT",
    "ARX_PASSWORD_SMOKE_SETTINGS_ISOLATION",
    "ARX_PASSWORD_SMOKE_IMPORT_RECORDS", "ARX_PASSWORD_SMOKE_IMPORT_COOKIES", "ARX_PASSWORD_SMOKE_IMPORT_UNDO",
    "ARX_PASSWORD_SMOKE_VERIFIED",
]


def password_leaks(probe, root, log, stdout, stderr):
    """Where the probe password appears in plain text: replies, logs, errors or the profile on disk."""
    leaks = []
    if probe in stdout:
        leaks.append("stdout")
    if probe in stderr:
        leaks.append("stderr")
    if Path(log).exists() and probe.encode() in Path(log).read_bytes():
        leaks.append("the smoke log")
    needle = probe.encode()
    for path in Path(root).rglob("*"):
        if path.is_file() and not path.is_symlink():
            try:
                if needle in path.read_bytes():
                    leaks.append(str(path.relative_to(root)))
            except OSError:
                continue
    return leaks


class PasswordHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if password_fixture.serve(self):
            return
        if urlsplit(self.path).path == "/index.html":
            super().do_GET()
            return
        self.send_error(404)

    def do_POST(self):
        if password_fixture.serve(self):
            return
        self.send_error(404)

    def log_message(self, *_):
        pass
