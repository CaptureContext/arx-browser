"""Arx workspace composition, separate from the XML writer."""

from .core.paths import ROOT, packages
from .core.process import execute
from .tools import xcworkspace


def groups(root=ROOT):
    return ["Project.xcodeproj", ".", *[str(path.relative_to(root)) for path in packages(root)[1:]]]


def main():
    xcworkspace.generate(ROOT, name="Project", groups=groups())


if __name__ == "__main__":
    raise SystemExit(execute(main))
