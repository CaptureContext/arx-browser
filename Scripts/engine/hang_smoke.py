"""Run the frozen-page check (DEV-1009) in a fresh disposable browser profile."""

from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("hang-smoke") as log:
        engine_smoke.run(log, hang=True)
