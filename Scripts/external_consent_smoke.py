"""Run the actual signed app with an owned native external-dialog fixture."""
from . import app_smoke
from .core import smoke


def main():
    with smoke.log('external-consent-smoke') as log:
        app_smoke.run(log, external_consent=True)
