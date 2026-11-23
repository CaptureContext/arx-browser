"""Run real renderer/native history arbitration in owned disposable storage."""
from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("gesture-smoke") as log:
        engine_smoke.run(log, gestures=True)
