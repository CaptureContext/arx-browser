"""Generate both Xcode artifacts or open the generated workspace."""

from . import generate_xcodeproj, generate_xcworkspace
from .core.process import execute, run


def main():
    generate_xcodeproj.main()
    generate_xcworkspace.main()


def open_project():
    main()
    run(["open", "Project.xcworkspace"])


if __name__ == "__main__":
    raise SystemExit(execute(main))
