"""Run the full validation sequence, stopping at the first failure."""

from . import build_app, build_package, check, preview, test
from .core.process import execute


def main():
    check.main()
    test.main()
    build_package.main()
    build_app.main()
    preview.test()


if __name__ == "__main__":
    raise SystemExit(execute(main))
