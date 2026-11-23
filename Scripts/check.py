"""Validate package documentation, bundle metadata, translations of shipped languages, and reproducible generation."""

import hashlib
import json
import plistlib

from .core.paths import ROOT, packages
from .core.process import execute, run
from .localization import check_shipped as check_localization
from .project import main as project
from .tools.swift import check_toolchain, command as swift


def generated_hashes():
    paths = [
        ROOT / "Project.xcworkspace/contents.xcworkspacedata",
        ROOT / "Containers/macOS/Info.plist",
        ROOT / "Containers/macOS/Arx.entitlements",
    ]
    paths += sorted((ROOT / "Project.xcodeproj").rglob("project.pbxproj"))
    paths += sorted((ROOT / "Project.xcodeproj/xcshareddata").rglob("*.xcscheme"))
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def main():
    check_toolchain()
    check_localization()
    for package in packages():
        manifest = json.loads(run(swift(package, "package", "dump-package"), capture=True))
        platforms = manifest["platforms"]
        if len(platforms) != 1 or platforms[0]["platformName"] != "macos":
            raise ValueError(f"{package}: only macOS is supported")
        description = json.loads(run(swift(package, "package", "describe", "--type", "json"), capture=True))
        required = [package / "README.md"]
        required += [package / target["path"] / "README.md" for target in description["targets"]]
        for readme in required:
            if not readme.is_file():
                raise ValueError(f"Missing target/package documentation: {readme}")
    for container in (ROOT / "Containers").iterdir():
        if container.is_dir() and not (container / "README.md").is_file():
            raise ValueError(f"Missing container documentation: {container}")
    project()
    for filename in ["Info.plist", "Arx.entitlements"]:
        with (ROOT / "Containers/macOS" / filename).open("rb") as source:
            plistlib.load(source)
    before = generated_hashes()
    project()
    if before != generated_hashes():
        raise ValueError("Project generation is not deterministic")
    print("Manifest, README, plist, entitlements, and project determinism checks passed.")


if __name__ == "__main__":
    raise SystemExit(execute(main))
