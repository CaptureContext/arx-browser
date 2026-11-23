"""Verify the ABI37 focused-link read with owned disposable storage (DEV-713)."""
from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("focused-link-smoke") as log:
        engine_smoke.run(log, focused_link=True)
