"""Verify native reference activation in one disposable owned browser process."""

from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("reference-click-smoke") as log:
        engine_smoke.run(log, reference_click=True)
