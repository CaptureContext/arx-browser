"""Install from a loopback Chrome Web Store stand-in in owned native storage (DEV-765).

Chromium's own `--apps-gallery-url` test switch exposes `webstorePrivate` to the
loopback fixture origin, and native downloads packages from it instead of
Google. The package is a recorded, unmodified store CRX, so Chromium's
publisher-proof verifier runs for real. No network is used.

DEV-951 installs the same item by ID in a throwaway profile, as MCP's
installExtension does: declined, then approved.

DEV-776 store updates run against the same item: nothing newer, a corrupt
package and another profile. The update itself needs a second recorded store
version of the item, `<id>-next.crx`. The store only ever serves its latest
version, so it can be recorded only once the item publishes a newer one (see
fixtures/webstore/README.md); without it the newer-version phase is skipped and
says so.
"""

import functools
import http.server
import io
import json
import os
import struct
import subprocess
import tempfile
import threading
import zipfile
from pathlib import Path
from urllib.parse import urlsplit

from ..core import smoke
from . import host
from .config import WORK

FIXTURE = Path(__file__).parent / "fixtures/webstore/bcjindcccaagfpapjjmafapmmgkkhgoa.crx"
# DEV-776: a newer recorded store version of the same item, when one exists.
NEXT_FIXTURE = FIXTURE.with_name("bcjindcccaagfpapjjmafapmmgkkhgoa-next.crx")

MARKERS = [
    "ARX_EXTENSION_INSTALL_FIXTURE_OWNED_STORAGE",
    "ARX_WEBSTORE_FIXTURE_ORIGIN",
    "ARX_WEBSTORE_INSTALL_SMOKE_DECLINED",
    "ARX_WEBSTORE_INSTALL_SMOKE_REVIEW_HASH_PERMISSIONS",
    "ARX_WEBSTORE_INSTALL_SMOKE_INSTALLED",
    "ARX_WEBSTORE_INSTALL_SMOKE_RUNS",
    "ARX_WEBSTORE_INSTALL_SMOKE_PROFILE_ISOLATION",
    "ARX_WEBSTORE_INSTALL_SMOKE_SIGNATURE_ID_GUARDS",
    # DEV-951: browser_settings installExtension's path, by ID with no store page.
    "ARX_WEBSTORE_INSTALL_SMOKE_BY_ID",
    "ARX_WEBSTORE_UPDATE_SMOKE_UP_TO_DATE",
    "ARX_WEBSTORE_UPDATE_SMOKE_GUARDS",
    "ARX_WEBSTORE_INSTALL_SMOKE_VERIFIED",
]
NEWER_MARKER = "ARX_WEBSTORE_UPDATE_SMOKE_NEWER"
NEWER_SKIPPED = "ARX_WEBSTORE_UPDATE_SMOKE_NEWER_SKIPPED"


def crx_version(package):
    """The manifest version inside a CRX3 package (magic, version, header size, header, ZIP)."""
    if package[:4] != b"Cr24" or struct.unpack("<I", package[4:8])[0] != 3:
        raise ValueError("Not a CRX3 package")
    header = struct.unpack("<I", package[8:12])[0]
    with zipfile.ZipFile(io.BytesIO(package[12 + header:])) as archive:
        return json.loads(archive.read("manifest.json"))["version"]

# The store page asks to install the item named in its fragment
# (`<id>:<variant>`), as the real store's Add to Chrome does, then completes.
STORE_PAGE = """<!doctype html><title>Arx store loading</title><script>
const [id, variant] = location.hash.slice(1).split(':');
const manifest = %s;
const api = chrome.webstorePrivate;
fetch('/variant?' + variant).then(() => {
  api.beginInstallWithManifest3({id, manifest: JSON.stringify(manifest)}, result => {
    const error = chrome.runtime.lastError;
    if (error) { document.title = 'ARX_WEBSTORE:begin=' + (result || 'error'); return; }
    api.completeInstall(id, () => {
      document.title = chrome.runtime.lastError
          ? 'ARX_WEBSTORE:complete=' + chrome.runtime.lastError.message : 'ARX_WEBSTORE:installed';
    });
  });
});
</script>"""

STATUS_PAGE = """<!doctype html><title>Arx store status loading</title><script>
chrome.webstorePrivate.getExtensionStatus(location.hash.slice(1),
    status => document.title = 'ARX_WEBSTORE_STATUS:' + status);
</script>"""


def manifest():
    """The store's copy of the item's manifest, as the real store sends it."""
    return {
        "name": "JSON Formatter", "version": "0.10.2", "manifest_version": 3,
        "description": "Makes JSON easy to read", "minimum_chrome_version": "88",
        "icons": {"128": "icons/128.png", "32": "icons/32.png"},
        "content_scripts": [
            {"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end"},
            {"matches": ["<all_urls>"], "js": ["set-json-global.js"], "run_at": "document_idle", "world": "MAIN"},
        ],
        "permissions": ["storage"],
        "host_permissions": ["*://*/*", "<all_urls>"],
        "options_ui": {"page": "options/options.html", "open_in_tab": False},
    }


class WebstoreHandler(http.server.BaseHTTPRequestHandler):
    package = b""
    next_package = b""
    variant = "valid"
    downloads = 0
    lock = threading.Lock()

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/index.html":
            self.reply("text/html", b"<!doctype html><title>Arx engine smoke</title>")
        elif url.path == "/store.html":
            self.reply("text/html", (STORE_PAGE % json.dumps(manifest())).encode())
        elif url.path == "/status.html":
            self.reply("text/html", STATUS_PAGE.encode())
        elif url.path == "/variant":
            with WebstoreHandler.lock:
                WebstoreHandler.variant = url.query if url.query in ("corrupt", "next") else "valid"
                variant = WebstoreHandler.variant
            self.reply("text/html", f"<!doctype html><title>ARX_WEBSTORE_VARIANT:{variant}</title>".encode())
        elif url.path.startswith("/crx/") and url.path.endswith(".crx"):
            with WebstoreHandler.lock:
                WebstoreHandler.downloads += 1
                body = bytearray(WebstoreHandler.next_package
                                 if WebstoreHandler.variant == "next" else WebstoreHandler.package)
                if WebstoreHandler.variant == "corrupt":
                    # A byte inside the signed ZIP archive: the signature must fail.
                    body[len(body) // 2] ^= 0xFF
            self.reply("application/x-chrome-extension", bytes(body))
        elif url.path == "/data.json":
            self.reply("application/json", b'{"arx": [1, 2, 3], "store": "fixture"}')
        else:
            self.send_error(404)

    def reply(self, content_type, body):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    with smoke.log("webstore-install-smoke") as log:
        run(log)


def run(log):
    host.main(native_messaging_fixture=False)
    WebstoreHandler.package = FIXTURE.read_bytes()
    next_version = ""
    if NEXT_FIXTURE.is_file():
        WebstoreHandler.next_package = NEXT_FIXTURE.read_bytes()
        next_version = crx_version(WebstoreHandler.next_package)
        if next_version == crx_version(WebstoreHandler.package):
            raise ValueError(f"{NEXT_FIXTURE.name} is the same version as {FIXTURE.name}")
    with tempfile.TemporaryDirectory(prefix="smoke-", dir=WORK.resolve()) as directory:
        root = Path(directory)
        root.chmod(0o700)
        (root / ".arx-engine-smoke").write_text("Arx disposable engine smoke\n")
        # The host accepts the root only with this page beside the marker; the handler serves its own.
        (root / "index.html").write_text("<!doctype html><title>Arx engine smoke</title>")
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(WebstoreHandler))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            env = dict(os.environ, ARX_ENGINE_PROFILE=str(root / "profile"),
                       ARX_ENGINE_URL=f"http://127.0.0.1:{server.server_port}/index.html",
                       ARX_ENGINE_SMOKE_TITLE="Arx engine smoke",
                       ARX_WEBSTORE_NEXT_VERSION=next_version)
            arguments = [str(host.APP / "Contents/MacOS/ChromiumHost"),
                         "--disposable-smoke-root", str(root), "--webstore-install-fixture"]
            try:
                result = subprocess.run(arguments, env=env, capture_output=True, text=True, timeout=180)
            except subprocess.TimeoutExpired as error:
                smoke.append(log, error.stdout, error.stderr)
                raise ValueError(f"Web Store smoke timed out; inspect {log}") from error
            smoke.append(log, result.stdout, result.stderr)
            lines = result.stderr.splitlines()
            if (result.returncode or "ARX_WEBSTORE_INSTALL_SMOKE_SUCCESS" not in result.stdout.splitlines()
                    or "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN" not in lines):
                raise ValueError(f"Web Store smoke failed; inspect {log}")
            required = MARKERS + [NEWER_MARKER if next_version else NEWER_SKIPPED]
            missing = [marker for marker in required if marker not in lines]
            if missing:
                raise ValueError(f"Web Store smoke is missing {', '.join(missing)}; inspect {log}")
            if (root / "profile").exists():
                raise ValueError(f"Native fixture used caller-supplied storage; inspect {log}")
            # Decline downloads nothing; review-cancel, install and the two guards each download
            # at least once (a stale inventory makes the page ask again), and so do the
            # up-to-date and corrupt update checks (DEV-776).
            if WebstoreHandler.downloads < 6:
                raise ValueError(f"Expected at least 6 package downloads, saw {WebstoreHandler.downloads}; inspect {log}")
            newer = (f"updated it to {next_version} through review" if next_version
                     else "skipped the newer-version update (no second recorded version)")
            print(f"A loopback Chrome Web Store installed a recorded store package through review into one "
                  f"disposable mock-Keychain profile only, found it up to date, refused a corrupt update "
                  f"and {newer}. No network was used. Log: {log}")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
