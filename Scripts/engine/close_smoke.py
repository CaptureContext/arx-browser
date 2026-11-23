"""Run document-bound close checks in a fresh disposable browser profile."""

from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("close-smoke") as log:
        engine_smoke.run(log, authorized_close=True)
