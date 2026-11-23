"""Verify reference-scoped native scroll actions in owned disposable storage."""

from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("reference-scroll-smoke") as log:
        engine_smoke.run(log, reference_scroll=True)
