"""Run automation tests and discover packages with Swift test targets."""

import json
import os
import sys

from .core.paths import packages
from .core.process import execute, run
from .tools.swift import command as swift

# Swift Testing's own cap on how many tests run at once.
PARALLELIZATION_WIDTH = "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"


def environment(base=None):
    """The environment `swift test` runs with: Swift Testing capped at `TEST_PARALLELISM` tests.

    Swift Testing otherwise starts every test at once. Most feature tests are `@MainActor` and
    share the one main thread, so with hundreds in flight a test's wall time is mostly its wait
    behind the others, and `.timeLimit(.minutes(1))` fails whenever a loaded machine stretches
    the whole run past a minute (DEV-970). A narrow width keeps each test's time its own.
    """
    result = dict(os.environ if base is None else base)
    width = result.get("TEST_PARALLELISM", "").strip() or "8"
    if not width.isdigit() or int(width) < 1:
        raise ValueError("TEST_PARALLELISM must be a positive whole number")
    result.setdefault(PARALLELIZATION_WIDTH, width)
    return result


def main():
    run([sys.executable, "-m", "unittest", "discover", "-s", "Scripts/tests", "-v"])
    test_environment = environment()
    for package in packages():
        manifest = json.loads(run(swift(package, "package", "dump-package"), capture=True))
        if any(target["type"] == "test" for target in manifest["targets"]):
            run(
                swift(package, "test", "--jobs", os.environ.get("BUILD_JOBS", "8")),
                env=test_environment,
                log=f"test-{package.name}.log",
            )


if __name__ == "__main__":
    raise SystemExit(execute(main))
