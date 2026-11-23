"""Run actual full-document pixels only in the explicitly owned native host."""
from ..core import smoke
from . import smoke as engine_smoke


def main():
    with smoke.log("document-capture-smoke") as log:
        engine_smoke.run(log, document_capture=True)
