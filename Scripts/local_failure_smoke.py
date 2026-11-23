"""Check the local development page failure explanations in the signed app.

Launches on a loopback port nothing listens on and expects the connection
refused explanation with that port, then navigates to a loopback HTTPS server
with a throwaway self-signed certificate and expects the certificate
explanation. Last it requests https:// from a plain-HTTP loopback server, expects
the suggestion to use http://, and follows it to the same port, path and query.
Certificate validation stays on; nothing is trusted or bypassed.

Then (DEV-1226) it opens a name that never resolves (`.invalid`, so no network is
needed, online or off). The engine commits its own "This site can't be reached"
page with a Reload button, and Arx's "This page could not load" card mustn't
show on top of it.
"""

import http.server
import os
import socket
import ssl
import subprocess
import tempfile
import threading
from pathlib import Path

from . import build_app
from .core import smoke
from .engine.config import WORK


PLAIN_TITLE = "Arx plain HTTP fixture"
PLAIN_PATH = "/plain?phase=http"
# DEV-1226: a name that never resolves; the engine shows its own error page for it.
UNRESOLVED_URL = "http://arx-local-failure.invalid/"


class Fixture(http.server.BaseHTTPRequestHandler):
    body = b"<!doctype html><title>Arx local failure fixture</title><p>Trusted unexpectedly</p>"

    def do_GET(self):
        body = self.body
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class PlainFixture(Fixture):
    body = f"<!doctype html><title>{PLAIN_TITLE}</title><p>Served over plain HTTP</p>".encode()


def plain_server():
    """A plain-HTTP loopback server; an https:// request to it fails the TLS handshake."""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), PlainFixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def environment(profile, refused_port, tls_port, plain_port):
    return {
        "ARX_LOCAL_FAILURE_SMOKE": "1",
        "ARX_ENGINE_PROFILE": str(profile),
        "ARX_ENGINE_URL": f"http://127.0.0.1:{refused_port}/",
        "ARX_LOCAL_FAILURE_TLS_URL": f"https://127.0.0.1:{tls_port}/",
        "ARX_LOCAL_FAILURE_PLAIN_URL": f"https://127.0.0.1:{plain_port}{PLAIN_PATH}",
        "ARX_LOCAL_FAILURE_PLAIN_TITLE": PLAIN_TITLE,
        "ARX_LOCAL_FAILURE_UNRESOLVED_URL": UNRESOLVED_URL,
    }


def closed_port():
    """A loopback port that was free a moment ago; nothing in the smoke listens on it."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def self_signed(directory):
    key, certificate = directory / "key.pem", directory / "certificate.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
                    "-keyout", str(key), "-out", str(certificate)], check=True, capture_output=True)
    return certificate, key


def main():
    if os.environ.get("CONFIGURATION", "Debug") != "Debug":
        raise ValueError("local-failure-smoke uses the Debug development configuration")
    with smoke.log("local-failure-smoke") as log:
        app = build_app.main(log="local-failure-smoke-build.log", signed=True, require_engine=True)
        WORK.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="local-failure-", dir=WORK) as directory:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(*self_signed(Path(directory)))
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            plain = plain_server()
            try:
                env = dict(os.environ, **environment(Path(directory) / "profile", closed_port(),
                                                     server.server_port, plain.server_port))
                process = subprocess.run([str(app / "Contents/MacOS/Arx")], env=env, capture_output=True,
                                         text=True, timeout=90)
            except subprocess.TimeoutExpired as error:
                raise ValueError(f"Local failure smoke timed out; inspect {log}") from error
            finally:
                server.shutdown()
                plain.shutdown()
        smoke.append(log, process.stdout, process.stderr)
        if process.returncode != 0 or "ARX_LOCAL_FAILURE_SMOKE_SUCCESS\n" not in process.stdout:
            raise ValueError(f"Local failure smoke failed; inspect {log}")
        print("Closed loopback ports, untrusted loopback certificates and https:// against plain-HTTP loopback servers "
              "show their local development explanations.")
