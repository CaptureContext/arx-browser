"""Fetch exact Helium revisions without changing existing source checkouts."""

from ..core.process import run
from .config import LOCK, UPSTREAM, WORK


def verify():
    expected = [(UPSTREAM, LOCK["helium_macos"]["revision"]),
                (UPSTREAM / "helium-chromium", LOCK["helium"]["revision"])]
    for path, revision in expected:
        actual = run(["git", "rev-parse", "HEAD"], cwd=path, capture=True).strip()
        if actual != revision:
            raise ValueError(f"Engine checkout revision mismatch: {path}")
        if run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=path, capture=True).strip():
            raise ValueError(f"Engine checkout has tracked edits: {path}")
    version = (UPSTREAM / "helium-chromium/chromium_version.txt").read_text().strip()
    if version != LOCK["chromium"]:
        raise ValueError("Helium's Chromium version differs from engine.lock.json")


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    if not UPSTREAM.exists():
        run(["git", "clone", "--no-checkout", LOCK["helium_macos"]["repository"], str(UPSTREAM)])
        run(["git", "checkout", "--detach", LOCK["helium_macos"]["revision"]], cwd=UPSTREAM)
        run(["git", "submodule", "update", "--init", "--recursive"], cwd=UPSTREAM)
    verify()
