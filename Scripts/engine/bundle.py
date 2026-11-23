"""Validate the pinned Chromium bundle before building or launching a runtime app."""

import os
import plistlib

from ..core.process import run
from . import artifact, cache
from .config import LOCK


HELPERS = (
    "Arx Helper", "Arx Helper (Renderer)", "Arx Helper (GPU)", "Arx Helper (Alerts)",
    "Arx Helper (Aperitif)", "Arx Helper (Aperitif Renderer)",
    "Arx Helper (Aperitif GPU)", "Arx Helper (Aperitif Alerts)",
)
LIBRARIES = ("libaperitif.dylib", "libvk_swiftshader.dylib", "libvulkan.dylib")
RESOURCES = (
    "chrome_100_percent.pak", "chrome_200_percent.pak", "resources.pak", "icudtl.dat",
    "en.lproj/locale.pak",
)


def require_file(path, *, executable=False):
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f"Runtime bundle is missing a required file: {path}")
    if executable and not os.access(path, os.X_OK):
        raise ValueError(f"Runtime bundle executable has no execute permission: {path}")


def validate_architectures(path, expected):
    actual = run(["lipo", "-archs", str(path)], capture=True).strip().split()
    if not set(expected).issubset(actual):
        raise ValueError(f"Runtime binary {path} has architectures {actual}; requires {expected}")


def validate_framework(framework, *, architectures=None):
    cache.validate_framework(framework)
    expected = architectures or [artifact.identity()["architecture"]]
    version = framework / "Versions" / LOCK["chromium"]
    if (framework / "Versions/Current").resolve() != version.resolve():
        raise ValueError("Runtime framework Versions/Current does not select the pinned Chromium version")
    for name in ("Arx Framework", "Helpers", "Libraries", "Resources"):
        if (framework / name).resolve() != (version / name).resolve():
            raise ValueError(f"Runtime framework has a missing or misplaced {name} link")

    binaries = [version / "Arx Framework"]
    for name in HELPERS:
        contents = version / "Helpers" / f"{name}.app" / "Contents"
        metadata = contents / "Info.plist"
        require_file(metadata)
        with metadata.open("rb") as source:
            if plistlib.load(source).get("CFBundleExecutable") != name:
                raise ValueError(f"Runtime helper has an unexpected executable: {metadata}")
        binaries.append(contents / "MacOS" / name)
    binaries += [version / "Helpers" / name for name in (
        "app_mode_loader", "chrome_crashpad_handler", "web_app_shortcut_copier",
    )]
    binaries += [version / "Libraries" / name for name in LIBRARIES]
    for path in binaries:
        require_file(path, executable=True)
        validate_architectures(path, expected)
    for name in RESOURCES:
        require_file(version / "Resources" / name)
    metadata = version / "Resources/Info.plist"
    require_file(metadata)
    with metadata.open("rb") as source:
        data = plistlib.load(source)
    if (data.get("CFBundleVersion") != LOCK["helium_macos"]["version"]
            or data.get("CFBundleIdentifier") != LOCK["bundle_id"] + ".framework"
            or data.get("CFBundleExecutable") != "Arx Framework"):
        raise ValueError("Runtime framework metadata does not match the pinned Arx engine")


def validate_application(app, *, executable="Arx"):
    expected = [artifact.identity()["architecture"]]
    binary = app / "Contents/MacOS" / executable
    require_file(binary, executable=True)
    validate_architectures(binary, expected)
    validate_framework(app / "Contents/Frameworks" / LOCK["framework"], architectures=expected)


def require():
    framework = cache.require()
    validate_framework(framework)
    return framework
