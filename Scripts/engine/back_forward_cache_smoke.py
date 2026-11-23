"""Verify that Back restores a page from the back/forward cache, with owned disposable storage (DEV-943)."""
from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("back-forward-cache-smoke") as log:
        engine_smoke.run(log, back_forward_cache=True)
