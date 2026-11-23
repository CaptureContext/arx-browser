"""Run DEV-936 background-page visibility checks in owned disposable storage."""
from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("background-visibility-smoke") as log:
        engine_smoke.run(log, background_visibility=True)
