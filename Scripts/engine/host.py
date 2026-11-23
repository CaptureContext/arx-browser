"""Bundle a development-only Swift host with the complete locally built engine."""

import os
import plistlib
import shutil

from .. import signing
from ..core.privacy import BONJOUR_SERVICES, USAGE_DESCRIPTIONS
from ..core.process import run
from ..tools.swift import command as swift
from .config import LOCK, PACKAGE, WORK
from . import bundle

APP = WORK / "Arx Engine Host.app"


def main(*, native_messaging_fixture=False):
    framework = bundle.require()
    run(swift(PACKAGE, "build", "--jobs", os.environ.get("BUILD_JOBS", "8"), "--product", "ChromiumHost"), log="engine-host-build.log")
    binary_dir = run(swift(PACKAGE, "build", "--show-bin-path"), capture=True).strip()
    if APP.exists():
        shutil.rmtree(APP)
    contents = APP / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Frameworks").mkdir()
    shutil.copy2(f"{binary_dir}/ChromiumHost", contents / "MacOS/ChromiumHost")
    if native_messaging_fixture:
        run([
            "xcrun", "clang", "-std=c17", "-Wall", "-Wextra", "-Werror", "-O2",
            str(PACKAGE.parents[1] / "Scripts/engine/fixtures/native_message_host.c"),
            "-o", str(contents / "MacOS/ArxNativeMessagingFixture"),
        ], log="native-messaging-fixture-build.log")
    run(["ditto", str(framework), str(contents / "Frameworks" / LOCK["framework"])])
    with (contents / "Info.plist").open("wb") as output:
        plistlib.dump({
            "CFBundleName": "Arx", "CFBundleDisplayName": "Arx engine host",
            "CFBundleIdentifier": LOCK["bundle_id"] + ".engine-host", "CFBundleExecutable": "ChromiumHost",
            "CFBundlePackageType": "APPL", "CFBundleVersion": LOCK["chromium"],
            "CFBundleShortVersionString": "0.0.1", "NSPrincipalClass": "BrowserCrApplication",
            "LSMinimumSystemVersion": "27.0", "NSHighResolutionCapable": True,
            **USAGE_DESCRIPTIONS,
            "NSBonjourServices": BONJOUR_SERVICES,
        }, output)
    bundle.validate_application(APP, executable="ChromiumHost")
    signing.sign(APP)
    print(f"Development host: {APP}")
