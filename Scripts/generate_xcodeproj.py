"""Arx project-generation entry point. Run through mise or Make."""

from .core.paths import ROOT
from .core.process import execute
from .tools import xcodegen


def main():
    xcodegen.generate(ROOT)


if __name__ == "__main__":
    raise SystemExit(execute(main))
