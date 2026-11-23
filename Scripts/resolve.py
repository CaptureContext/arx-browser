"""Resolve dependencies after checking the toolchain and local forks."""

from .core.paths import ROOT
from .core.process import execute, run
from .tools.git import submodules
from .tools.swift import check_toolchain, command as swift


def main():
    check_toolchain()
    submodules()
    run(swift(ROOT, "package", "resolve"), log="resolve.log")


if __name__ == "__main__":
    raise SystemExit(execute(main))
