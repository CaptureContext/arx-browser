"""Keep Helium's Python dependencies local to the ignored engine build directory."""

from ..core.process import run
from .config import PACKAGE, WORK


def main():
    run(["mise", "install", "python@3.13.9"])
    python = WORK / "python/bin/python3"
    if not python.exists():
        run(["mise", "exec", "python@3.13.9", "--", "python", "-m", "venv", str(WORK / "python")])
    run([str(python), "-m", "pip", "install", "-r", str(PACKAGE / "build-requirements.txt")])
