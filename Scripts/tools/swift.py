"""SwiftPM commands with shared build paths and toolchain requirements."""

import os
import re

from ..core.paths import ROOT
from ..core.process import run


def command(package, *arguments):
    options = [
        "swift", *arguments[:1], "--package-path", str(package),
        "--scratch-path", str(ROOT / ".build"),
        "--security-path", str(ROOT / "build/swift-security"),
    ]
    if os.environ.get("SWIFT_DISABLE_SANDBOX") == "1":
        options.append("--disable-sandbox")
    return [*options, *arguments[1:]]


def check_toolchain():
    version = run(["swift", "--version"], capture=True)
    match = re.search(r"Swift version (\d+)\.(\d+)", version)
    if not match or tuple(map(int, match.groups())) < (6, 4):
        raise ValueError("Arx requires Swift 6.4 or newer. Select the matching Xcode toolchain.")
