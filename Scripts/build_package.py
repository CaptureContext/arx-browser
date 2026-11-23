"""Build the root package and selected infrastructure products."""

import os

from .core.paths import ROOT
from .core.process import execute, run
from .tools.swift import check_toolchain, command as swift


def main():
    check_toolchain()
    run(swift(ROOT, "build", "--jobs", os.environ.get("BUILD_JOBS", "8")), log="build-package.log")
    # These selected infrastructure products are not linked by the initial app shell.
    for target in ["_IssueReporting", "_SQLiteData", "_TestSupport", "_URLRouting", "package-resources-cli"]:
        run(swift(ROOT, "build", "--target", target, "--jobs", os.environ.get("BUILD_JOBS", "8")), log=f"build-{target}.log")


if __name__ == "__main__":
    raise SystemExit(execute(main))
