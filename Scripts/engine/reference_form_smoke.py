"""Verify reference-scoped native form actions in owned disposable storage."""

from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("reference-form-smoke") as log:
        engine_smoke.run(log, reference_form=True)
