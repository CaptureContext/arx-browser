"""Verify renderer-originated link menus with owned disposable storage."""
from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("link-context-smoke") as log:
        engine_smoke.run(log, link_context=True)
