"""Run the exact developer MV3 fixture in fresh native-owned profile storage."""

from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("extensions-smoke") as log:
        engine_smoke.run(log, extensions=True)
