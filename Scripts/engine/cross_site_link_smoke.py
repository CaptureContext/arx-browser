"""Verify the ABI43 cross-site link offer with owned disposable storage (DEV-727)."""
from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("cross-site-link-smoke") as log:
        engine_smoke.run(log, cross_site_link=True)
