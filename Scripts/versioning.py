"""The app's marketing version and build number, kept in the XcodeGen settings.

The marketing version (`MARKETING_VERSION`, e.g. 0.1.0) changes only through `make version`.
The build number (`CURRENT_PROJECT_VERSION`) goes up by one for every release build, starting
from 1, and never resets, so each disk image is told apart from the one before it.
"""

import argparse
import os
import re
from pathlib import Path

from .core.paths import ROOT


SETTINGS = ROOT / ".xcodegen/settings.yml"
MARKETING_KEY = "MARKETING_VERSION"
BUILD_KEY = "CURRENT_PROJECT_VERSION"
# CI checkouts can't keep a bumped number, so a release job passes its own.
BUILD_OVERRIDE = "ARX_BUILD_NUMBER"
SEMANTIC = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")


def _pattern(key):
    return re.compile(rf"^(?P<prefix>\s*{key}:\s*)(?P<quote>'?)(?P<value>[^'\s]*)(?P=quote)\s*$", re.MULTILINE)


def _settings(settings):
    return SETTINGS if settings is None else Path(settings)


def _read(key, settings):
    settings = _settings(settings)
    match = _pattern(key).search(Path(settings).read_text())
    if not match:
        raise ValueError(f"{settings} has no {key}")
    return match.group("value")


def _write(key, value, settings, quoted):
    settings = _settings(settings)
    path = settings
    text = path.read_text()
    replacement = f"'{value}'" if quoted else value
    updated, count = _pattern(key).subn(lambda match: f"{match.group('prefix')}{replacement}", text, count=1)
    if count != 1:
        raise ValueError(f"{settings} has no {key}")
    path.write_text(updated)


def display_path(settings=None):
    """The settings file as it's named in messages: relative to the repository when inside it."""
    path = _settings(settings)
    return path.relative_to(ROOT) if path.is_relative_to(ROOT) else path


def marketing_version(settings=None):
    return _read(MARKETING_KEY, settings)


def build_number(settings=None):
    value = _read(BUILD_KEY, settings)
    if not value.isdigit():
        raise ValueError(f"{BUILD_KEY} in {settings} must be a whole number, not {value!r}")
    return int(value)


def next_build_number(settings=None, environment=None):
    """The build number for this release build, written back to the settings file."""
    environment = os.environ if environment is None else environment
    override = environment.get(BUILD_OVERRIDE, "").strip()
    if override:
        if not override.isdigit() or int(override) < 1:
            raise ValueError(f"{BUILD_OVERRIDE} must be a whole number from 1, not {override!r}")
        number = int(override)
    else:
        number = build_number(settings) + 1
    _write(BUILD_KEY, str(number), settings, quoted=True)
    return number


def set_marketing_version(value, settings=None):
    value = value.strip()
    if not SEMANTIC.match(value):
        raise ValueError(f"Marketing versions look like 0.1.0, not {value!r}")
    _write(MARKETING_KEY, value, settings, quoted=False)
    return value


def main(arguments=()):
    parser = argparse.ArgumentParser(
        prog="make version",
        description="Show the app version, or set the marketing version (make version ARGS=0.2.0).",
    )
    parser.add_argument("version", nargs="?", help="the new marketing version, e.g. 0.2.0")
    options = parser.parse_args(list(arguments))
    if options.version:
        set_marketing_version(options.version)
        print(f"Marketing version is now {marketing_version()}. Commit {display_path()}.")
    print(f"Arx {marketing_version()} (build {build_number()}); the next release build is {build_number() + 1}.")
    return 0
