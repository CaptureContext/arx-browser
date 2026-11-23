"""Verify the ABI38 site permissions and page zoom with owned disposable storage (DEV-716)."""
from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("site-settings-smoke") as log:
        engine_smoke.run(log, site_settings=True)
