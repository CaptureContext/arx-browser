"""The engine bump commands the nightly workflow runs on GitHub's Ubuntu runner (DEV-955).

`Scripts.tasks` imports every command, and some load macOS libraries when imported (the
benchmark's process metrics load libSystem). This entry point imports only what the bump needs:

    python3 -m Scripts.engine.automation engine-upstream --json build/engine-upstream/update.json
    python3 -m Scripts.engine.automation engine-bump --json build/engine-upstream/update.json
    python3 -m Scripts.engine.automation engine-anchor-check --report build/engine-upstream/anchors.md
    python3 -m Scripts.engine.automation pull-request UPDATE.json ANCHORS.md STATE OUTPUT_DIR

On a Mac, `make engine-upstream`, `make engine-bump` and `make engine-anchor-check` run the same
functions.
"""

import sys
from functools import partial

from ..core.process import execute
from . import anchors, upstream

COMMANDS = {
    "engine-upstream": upstream.main,
    "engine-bump": upstream.bump_main,
    "engine-anchor-check": anchors.main,
    "pull-request": upstream.pull_request_main,
}


def main(arguments):
    if not arguments or arguments[0] not in COMMANDS:
        print("Usage: python3 -m Scripts.engine.automation " + "|".join(COMMANDS) + " [arguments]", file=sys.stderr)
        return 2
    return execute(partial(COMMANDS[arguments[0]], arguments[1:]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
