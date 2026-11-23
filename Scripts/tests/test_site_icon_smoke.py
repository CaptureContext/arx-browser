import http.server
import tempfile
import re
import subprocess
import stat
import threading
import unittest
import urllib.error
import urllib.request
import zlib
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from Scripts.core import site_icon_smoke


class SiteIconSmokeTests(unittest.TestCase):
    def test_preparation_requires_new_private_marker_and_profile(self):
        with tempfile.TemporaryDirectory(prefix="app-smoke-") as directory:
            root = Path(directory)
            (root / "profile").mkdir(mode=0o700)
            environment = site_icon_smoke.prepare(root)
            self.assertEqual(environment, {"ARX_SITE_ICONS_SMOKE_ROOT": str(root)})
            manifest = root / site_icon_smoke.MANIFEST
            self.assertEqual(manifest.read_bytes(), b"")
            self.assertEqual(stat.S_IMODE(manifest.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                site_icon_smoke.prepare(root)

    def test_all_phase_markers_are_required_as_complete_lines(self):
        site_icon_smoke.verify("\n".join(site_icon_smoke.MARKERS))
        with self.assertRaises(ValueError):
            site_icon_smoke.verify("\n".join(site_icon_smoke.MARKERS[:-1]))
        with self.assertRaises(ValueError):
            site_icon_smoke.verify(" ".join(site_icon_smoke.MARKERS))

    def test_png_is_exact_32_pixel_opaque_color(self):
        for color in site_icon_smoke.COLORS.values():
            data = site_icon_smoke.png(color)
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(data[16:24], (32).to_bytes(4, "big") * 2)
            start = data.index(b"IDAT")
            length = int.from_bytes(data[start - 4:start], "big")
            pixels = zlib.decompress(data[start + 4:start + 4 + length])
            self.assertEqual(pixels, (b"\0" + bytes((*color, 255)) * 32) * 32)

    def test_native_icon_url_requires_its_profile_cookie(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                site_icon_smoke.serve(self)

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.site_icon_requests = []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_port}"
            with self.assertRaises(urllib.error.HTTPError) as failure:
                urllib.request.urlopen(base + "/site-icons/red.png", timeout=2)
            self.assertEqual(failure.exception.code, 403)
            request = urllib.request.Request(base + "/site-icons/red.png", headers={"Cookie": "arx_site_icon=red"})
            with urllib.request.urlopen(request, timeout=2) as response:
                self.assertEqual(response.read(), site_icon_smoke.png((255, 0, 0)))
            request = urllib.request.Request(base + "/site-icons/page.html", headers={"Cookie": "arx_site_icon=green"})
            with urllib.request.urlopen(request, timeout=2) as response:
                self.assertIn(b'/site-icons/green.png', response.read())
            self.assertEqual(server.site_icon_requests, [("red", False), ("red", True)])
            # The scripted page declares its first icon and swaps in the second
            # from script; neither needs the profile cookie.
            with urllib.request.urlopen(base + "/site-icons/scripted.html", timeout=2) as response:
                page = response.read()
            self.assertIn(b"/site-icons/scripted-first.png", page)
            self.assertIn(b"/site-icons/scripted-second.png", page)
            for name, color in site_icon_smoke.SCRIPTED.items():
                with urllib.request.urlopen(base + f"/site-icons/scripted-{name}.png", timeout=2) as response:
                    self.assertEqual(response.read(), site_icon_smoke.png(color))
            server.site_icon_restart_forbidden = True
            server.site_icon_restart_requests = []
            with self.assertRaises(urllib.error.HTTPError) as failure:
                urllib.request.urlopen(base + "/site-icons/page.html", timeout=2)
            self.assertEqual(failure.exception.code, 410)
            self.assertEqual(server.site_icon_restart_requests, ["/site-icons/page.html"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_icon_origin_declares_on_one_host_and_falls_back_on_another(self):
        server, thread, environment = site_icon_smoke.start_icon_origin()
        try:
            port = server.server_port
            declared, bare = site_icon_smoke.DECLARED_HOST, site_icon_smoke.BARE_HOST
            self.assertEqual(environment, {"ARX_SITE_ICONS_ORIGIN_PORT": str(port)})

            def get(host, path, cookie=False):
                headers = {"Host": f"{host}:{port}"}
                if cookie:
                    headers["Cookie"] = "a=b"
                request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers=headers)
                with urllib.request.urlopen(request, timeout=2) as response:
                    return response.read()

            page = get(declared, "/")
            self.assertIn(b'sizes="32x32" href="declared.png"', page)
            self.assertLess(page.index(b"declared.png"), page.index(b"<body>"))
            self.assertEqual(get(declared, "/declared.png"), site_icon_smoke.png(site_icon_smoke.DECLARED))
            self.assertNotIn(b"<link", get(bare, "/"))
            self.assertEqual(get(bare, "/favicon.ico", cookie=True), site_icon_smoke.png(site_icon_smoke.FALLBACK))
            for host, path in ((declared, "/favicon.ico"), (bare, "/declared.png"), (declared, "/saved")):
                with self.subTest(host=host, path=path), self.assertRaises(urllib.error.HTTPError) as failure:
                    get(host, path)
                self.assertEqual(failure.exception.code, 404)
            self.assertEqual(server.site_icon_fetch_requests[:4], [
                (declared, "/", False), (declared, "/declared.png", False),
                (bare, "/", False), (bare, "/favicon.ico", True),
            ])

            # DEV-1108: the redirecting site's root sends a visitor to another
            # host's sign-in page, which declares its own icon; the site's own
            # /favicon.ico is another.
            redirecting = site_icon_smoke.REDIRECTING_HOST
            request = urllib.request.Request(f"http://127.0.0.1:{port}/", headers={"Host": f"{redirecting}:{port}"})
            opener = urllib.request.build_opener(type("NoRedirect", (urllib.request.HTTPRedirectHandler,), {
                "redirect_request": lambda *_: None,
            }))
            with self.assertRaises(urllib.error.HTTPError) as redirect:
                opener.open(request, timeout=2)
            self.assertEqual(redirect.exception.code, 302)
            self.assertEqual(redirect.exception.headers["Location"], f"http://{site_icon_smoke.SIGN_IN_HOST}:{port}/sign-in")
            self.assertIn(b'href="/sign-in.png"', get(site_icon_smoke.SIGN_IN_HOST, "/sign-in"))
            self.assertEqual(get(site_icon_smoke.SIGN_IN_HOST, "/sign-in.png"), site_icon_smoke.png(site_icon_smoke.SIGN_IN))
            self.assertEqual(get(redirecting, "/favicon.ico"), site_icon_smoke.png(site_icon_smoke.OWN))

            # DEV-1108: the app's directory shows its own icon only with the
            # profile's cookie; without it, both pages send to the sign-in page.
            app = site_icon_smoke.APP_HOST
            for path in ("/", "/mail/"):
                request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers={"Host": f"{app}:{port}"})
                with self.assertRaises(urllib.error.HTTPError) as redirect:
                    opener.open(request, timeout=2)
                self.assertEqual(redirect.exception.headers["Location"], f"http://{site_icon_smoke.SIGN_IN_HOST}:{port}/sign-in")
            request = urllib.request.Request(f"http://127.0.0.1:{port}/sign-in-here", headers={"Host": f"{app}:{port}"})
            with urllib.request.urlopen(request, timeout=2) as response:
                self.assertIn(site_icon_smoke.APP_COOKIE, response.headers["Set-Cookie"])
                self.assertIn(b'rel="icon" href="data:image/png;base64,', response.read())
            request = urllib.request.Request(f"http://127.0.0.1:{port}/mail/", headers={
                "Host": f"{app}:{port}", "Cookie": site_icon_smoke.APP_COOKIE})
            with urllib.request.urlopen(request, timeout=2) as response:
                self.assertIn(b'href="/mail/icon.png"', response.read())
            self.assertEqual(get(app, "/mail/icon.png"), site_icon_smoke.png(site_icon_smoke.APP_ICON))
            self.assertEqual(get(app, "/favicon.ico"), site_icon_smoke.png(site_icon_smoke.APP_OWN))
            server.site_icon_restart_forbidden = True
            server.site_icon_restart_requests = []
            with self.assertRaises(urllib.error.HTTPError) as failure:
                get(declared, "/")
            self.assertEqual(failure.exception.code, 410)
            self.assertEqual(server.site_icon_restart_requests, ["/"])
        finally:
            site_icon_smoke.stop_icon_origin(server, thread)

    def test_fetches_go_only_to_hosts_no_other_stage_uses(self):
        # Cookies are kept per host, not per port: a cookie another stage stored for
        # the fixture's own 127.0.0.1 or localhost would reach these page requests.
        own = {site_icon_smoke.DECLARED_HOST, site_icon_smoke.BARE_HOST, site_icon_smoke.SIGN_IN_HOST,
               site_icon_smoke.REDIRECTING_HOST, site_icon_smoke.APP_HOST}
        self.assertEqual(len(own), 5)
        self.assertLessEqual({host for host, _, _ in site_icon_smoke.FETCH_REQUESTS}, own)
        self.assertFalse(own & {"localhost", "127.0.0.1"})

    def test_fetch_requires_pages_and_icon_once_per_profile_with_cookies_only_on_pages(self):
        good = list(reversed(site_icon_smoke.FETCH_REQUESTS))
        site_icon_smoke.verify_fetch(good)
        icon = next(index for index, request in enumerate(good) if request[1] == "/mail/icon.png")
        signed_in = good.index((site_icon_smoke.APP_HOST, "/mail/", True))
        for requests in (
            [],
            good[1:],
            good + [good[0]],
            good + [(site_icon_smoke.DECLARED_HOST, "/saved/deep.html", False)],
            # A cookie on an icon request, or none on the signed-in page request.
            good[:icon] + [(*good[icon][:2], True)] + good[icon + 1:],
            good[:signed_in] + [(*good[signed_in][:2], False)] + good[signed_in + 1:],
        ):
            with self.subTest(requests=requests), self.assertRaises(ValueError):
                site_icon_smoke.verify_fetch(requests)

    def test_restart_requires_clean_exit_marker_allocator_and_zero_network_requests(self):
        stdout = site_icon_smoke.RESTART_MARKER + "\n"
        stderr = "ARX_BOOTSTRAP_ENTRY threads=1\nARX_BOOTSTRAP_REGISTERED\nARX_BOOTSTRAP_FRAMEWORK_VERIFIED\n"
        good = subprocess.CompletedProcess("owned", 0, stdout, stderr)
        site_icon_smoke.verify_restart(good, [])
        for result, requests, reason in (
            (subprocess.CompletedProcess("owned", 1, stdout, stderr), [], "exit status 1"),
            (subprocess.CompletedProcess("owned", 0, "", stderr), [], "no restart marker"),
            (subprocess.CompletedProcess("owned", 0, stdout, ""), [], "missing startup markers ARX_BOOTSTRAP_ENTRY"),
            (good, ["/site-icons/page.html"], "requests on restart: ['/site-icons/page.html']"),
            (good, ["/site-icons/blue.png"], "requests on restart: ['/site-icons/blue.png']"),
        ):
            # Each failure names its reason (DEV-965).
            with self.subTest(result=result, requests=requests), self.assertRaisesRegex(ValueError, re.escape(reason)):
                site_icon_smoke.verify_restart(result, requests)

    def test_restart_timeout_kills_only_its_owned_process_and_never_runs_crash_injection(self):
        process = Mock()
        process.__enter__ = Mock(return_value=process)
        process.__exit__ = Mock(return_value=False)
        process.communicate.side_effect = [subprocess.TimeoutExpired("owned", 40), ("", "")]
        server = SimpleNamespace()
        with patch.object(site_icon_smoke.subprocess, "Popen", return_value=process) as launch, \
                patch.object(site_icon_smoke.smoke, "append"), self.assertRaisesRegex(ValueError, "timed out"):
            site_icon_smoke.restart(
                Path("/owned/Arx.app"), {"ARX_ENGINE_SMOKE_CRASH_REQUEST": "/owned/old"}, server, "fixture.log"
            )
        process.kill.assert_called_once_with()
        self.assertEqual(launch.call_args.args[0], ["/owned/Arx.app/Contents/MacOS/Arx"])
        self.assertEqual(launch.call_args.kwargs["env"], {"ARX_SITE_ICONS_RESTART": "1"})
        self.assertTrue(server.site_icon_restart_forbidden)
