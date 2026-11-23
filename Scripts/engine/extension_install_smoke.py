"""Exercise verified local CRX install/update consent in owned native storage."""

from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("extension-install-smoke") as log:
        engine_smoke.run(log, extension_install=True)
