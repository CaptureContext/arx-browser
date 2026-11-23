"""Verify the ABI39 Clear Browsing Data and downloads location with owned disposable storage (DEV-647)."""
from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("browsing-data-smoke") as log:
        engine_smoke.run(log, browsing_data=True)
