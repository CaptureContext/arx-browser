"""Verify bounded native inspection with owned semantic and mutation fixtures."""

from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("inspection-smoke") as log:
        engine_smoke.run(log, inspection=True)
