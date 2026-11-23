"""Initialize missing forks while preserving divergent local revisions."""

from ..core.process import run


def submodules():
    status = run(["git", "submodule", "status", "--recursive"], capture=True)
    missing = []
    for line in status.splitlines():
        if line.startswith(("+", "U")):
            raise ValueError("A fork differs from its recorded revision. Preserve and reconcile it before bootstrap.")
        if line.startswith("-"):
            missing.append(line.split()[1])
    if missing:
        run(["git", "submodule", "update", "--init", "--recursive", "--", *missing])
