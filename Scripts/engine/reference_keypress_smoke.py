"""Verify guarded keypresses against static hostile pages in owned storage."""

from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("reference-keypress-smoke") as log:
        engine_smoke.run(log, reference_keypress=True)
