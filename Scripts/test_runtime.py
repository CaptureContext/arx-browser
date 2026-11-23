"""Run signed, interactive Chromium checks separately from unsigned validation."""

from . import app_smoke
from .engine import smoke as engine_smoke


def main():
    engine_smoke.main()
    app_smoke.main()
