"""Repository paths and app-owned package discovery."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def packages(root=ROOT):
    return [root, *sorted(path.parent for path in (root / "Packages").glob("*/Package.swift"))]
