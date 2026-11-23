"""A stdio relay between a real MCP client and Arx's helper, recording every message.

`make agent-evals ARGS='--model claude'` gives Claude Code this relay as the `arx` server, so the
run is measured from the same JSON-RPC messages as a scripted one. Standard library only: it runs
as `python3 -I relay.py TRANSCRIPT HELPER [ARGS…]`, outside the Scripts package.
"""

import json
import subprocess
import sys
import threading


def relay(transcript, command):
    """Copies stdio between a client and the helper, writing each message to `transcript`."""
    helper = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    lock = threading.Lock()
    with open(transcript, "a") as log:

        def record(origin, line):
            try:
                message = json.loads(line)
            except ValueError:
                return
            with lock:
                log.write(json.dumps({"from": origin, "message": message}) + "\n")
                log.flush()

        def upstream():
            try:
                for line in sys.stdin.buffer:
                    record("client", line)
                    helper.stdin.write(line)
                    helper.stdin.flush()
                helper.stdin.close()
            except BrokenPipeError:
                pass  # The helper ended first; its exit status says why.

        threading.Thread(target=upstream, daemon=True).start()
        try:
            for line in helper.stdout:
                record("server", line)
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
        except BrokenPipeError:
            helper.terminate()  # The client went away.
        return helper.wait()


if __name__ == "__main__":
    sys.exit(relay(sys.argv[1], sys.argv[2:]))
