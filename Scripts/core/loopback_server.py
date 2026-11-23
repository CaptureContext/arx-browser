"""One loopback fixture on both `127.0.0.1` and `::1`, at the same port.

`localhost` resolves to `::1` as well as `127.0.0.1`, and a page on `localhost` must reach the
fixture whichever address the client tries first. A server bound to `127.0.0.1` alone leaves
`::1` at its port to whatever else holds it there. So a companion server listens on `::1` at the
same port and hands each request to the main server's handler, with the main server as the
handler's `server`, so state the fixture keeps on its server is shared.
"""

import errno
import http.server
import socket
import threading

ATTEMPTS = 20


class Companion(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def __init__(self, main):
        self.main = main
        super().__init__(("::1", main.server_port), main.RequestHandlerClass)

    def finish_request(self, request, client_address):
        self.RequestHandlerClass(request, client_address, self.main)


class LoopbackServer:
    """The main `ThreadingHTTPServer` on `127.0.0.1`, and its `::1` companion when this Mac has
    IPv6 loopback. Attributes the fixture sets go on `server`."""

    def __init__(self, handler, attempts=ATTEMPTS):
        for _ in range(attempts):
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
            try:
                self.companion = Companion(server)
            except OSError as error:
                if error.errno != errno.EADDRINUSE:
                    # No IPv6 loopback: nothing will try ::1 either.
                    self.companion = None
                    self.server = server
                    break
                server.server_close()
                continue
            self.server = server
            break
        else:
            raise OSError(errno.EADDRINUSE, "No port is free on both 127.0.0.1 and ::1")
        self.threads = []

    @property
    def servers(self):
        return [self.server] + ([self.companion] if self.companion else [])

    def start(self):
        for server in self.servers:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.threads.append(thread)
        return self

    def stop(self):
        for server in self.servers:
            if self.threads:
                server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join()
        self.threads = []
