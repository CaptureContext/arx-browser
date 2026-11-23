"""Advisory style checks: SwiftFormat and SwiftLint in lint mode, then StyleCheck (DEV-1280).

All three tools get the same explicit file list: Arx's own Swift files as Git sees them, never
`Forks/`, vendored or ignored files, or build output such as `vendor/bundle` and `Packages/*/.build`.
SwiftLint gets the production part of that list. Every finding is a warning printed as
`path:line:column: warning: [rule] message`, or as a GitHub workflow annotation when
GITHUB_ACTIONS is true. The command exits 0 whatever the tools find and fails only when a tool
itself crashes. A SwiftFormat or SwiftLint binary that isn't installed is reported as skipped.
Nothing is rewritten. See Packages/tools/README.md for the rules.
"""

import collections
import fnmatch
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys

from .core.paths import ROOT
from .core.process import run
from .tools.swift import command as swift

TOOLS_PACKAGE = ROOT / "Packages/tools"
# Kept as copied from upstream, with its MIT notice: not Arx's code to restyle.
VENDORED = {"Packages/extensions/Sources/Files/Files.swift"}
# Directories that never hold Arx's own sources, wherever they sit: build output, dependency
# checkouts and installed gems. Git ignores most of them; this keeps them out when it doesn't.
SKIPPED_DIRECTORIES = {".build", ".swiftpm", "build", "DerivedData", "Forks", "vendor"}
# SwiftLint checks production code only, as `.swiftlint.yml` says: these top-level folders,
# without tests, manifests or prototypes. A test keeps this list and the config in step.
PRODUCTION_ROOTS = ("Containers/", "Packages/", "Previews/", "Sources/")
NOT_PRODUCTION = ("Packages/*/Package.swift", "Packages/*/Tests/*", "Packages/engine/Prototypes/*", "Previews/*/Tests/*")

FINDING = re.compile(r"^(?P<path>[^:\n]+):(?P<line>\d+):(?P<column>\d+): (?:warning|error): (?P<rest>.*)$")
SWIFTFORMAT_RULE = re.compile(r"^\((?P<rule>\w+)\) (?P<message>.*)$")
SWIFTLINT_RULE = re.compile(r"^(?P<message>.*) \((?P<rule>[a-z_]+)\)$")
STYLECHECK_RULE = re.compile(r"^\[(?P<rule>[a-z-]+)\] (?P<message>.*)$")

# Exit codes that mean "ran and found something", not a crash.
FINDINGS_EXIT_CODES = {"swiftformat": {0, 1}, "swiftlint": {0, 2}, "StyleCheck": {0}}
VERSION_ARGUMENTS = {"swiftformat": ["--version"], "swiftlint": ["version"]}

Finding = collections.namedtuple("Finding", "path line column rule message")


def is_own_source(path):
    parts = PurePosixPath(path).parts
    return (
        path.endswith(".swift")
        and path not in VENDORED
        and not any(part in SKIPPED_DIRECTORIES or part.startswith(".") for part in parts[:-1])
    )


def is_production(path):
    return path.startswith(PRODUCTION_ROOTS) and not any(fnmatch.fnmatch(path, pattern) for pattern in NOT_PRODUCTION)


def swift_files(root=ROOT):
    """Arx's own Swift files, relative to `root`: tracked or new but not ignored."""
    listed = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.swift"],
        cwd=root, text=True, capture_output=True, check=True,
    ).stdout.splitlines()
    return sorted(path for path in set(listed) if is_own_source(path) and (Path(root) / path).is_file())


def relative(path, root=ROOT):
    if os.path.isabs(path):
        try:
            return os.path.relpath(path, root)
        except ValueError:
            return path
    return path


def parse(output, tool, root=ROOT):
    """Findings from one tool's `path:line:column: warning|error: …` lines; other lines are dropped."""
    rule_pattern = {"swiftformat": SWIFTFORMAT_RULE, "swiftlint": SWIFTLINT_RULE, "StyleCheck": STYLECHECK_RULE}[tool]
    prefix = "" if tool == "StyleCheck" else f"{tool}/"
    findings = []
    for line in output.splitlines():
        match = FINDING.match(line.strip())
        if not match:
            continue
        rule = rule_pattern.match(match["rest"])
        if not rule:
            continue
        findings.append(Finding(
            relative(match["path"], root), int(match["line"]), int(match["column"]), prefix + rule["rule"],
            rule["message"],
        ))
    return findings


def escape(value, *, in_property=False):
    value = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return value.replace(":", "%3A").replace(",", "%2C") if in_property else value


def format_finding(finding, github):
    if github:
        return (
            f"::warning file={escape(finding.path, in_property=True)},line={finding.line},col={finding.column},"
            f"title={escape(finding.rule, in_property=True)}::{escape(finding.message)}"
        )
    return f"{finding.path}:{finding.line}:{finding.column}: warning: [{finding.rule}] {finding.message}"


def execute_tool(tool, arguments, root=ROOT):
    """Run a tool and return its combined output; raise only when it crashed."""
    result = subprocess.run(arguments, cwd=root, text=True, capture_output=True)
    if result.returncode not in FINDINGS_EXIT_CODES[tool]:
        print(result.stdout + result.stderr, file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, arguments)
    return result.stdout + result.stderr


def pinned_version(tool, root=ROOT):
    match = re.search(rf'^{tool}\s*=\s*"([^"]+)"', (Path(root) / "mise.toml").read_text(), re.M)
    return match[1] if match else None


def describe(tool, binary, root=ROOT):
    """`swiftlint 0.65.1`, with the pin when the binary isn't the version mise.toml names."""
    version = subprocess.run(
        [binary, *VERSION_ARGUMENTS[tool]], cwd=root, text=True, capture_output=True,
    ).stdout.strip().splitlines()
    version = version[-1] if version else "unknown version"
    pinned = pinned_version(tool, root)
    mismatch = f", not the {pinned} mise.toml pins: {binary}" if pinned and pinned != version else ""
    return f"{tool} {version}{mismatch}"


def build_style_check():
    run(swift(TOOLS_PACKAGE, "build", "--product", "StyleCheck"), log="build-StyleCheck.log")
    bin_path = run(swift(TOOLS_PACKAGE, "build", "--show-bin-path"), capture=True).strip()
    return os.path.join(bin_path, "StyleCheck")


def main(github=None, root=ROOT):
    """Check the checkout at `root` (this one by default) with tools built and found here."""
    github = os.environ.get("GITHUB_ACTIONS") == "true" if github is None else github
    files = swift_files(root)
    production = [path for path in files if is_production(path)]
    results = []

    for tool, arguments, checked in [
        ("swiftformat", ["--lint", *files], files),
        ("swiftlint", ["lint", "--quiet", "--force-exclude", "--reporter", "xcode", *production], production),
    ]:
        binary = shutil.which(tool)
        if binary is None:
            print(f"{tool}: skipped, not installed (`mise install` installs the version in mise.toml)", flush=True)
            continue
        findings = parse(execute_tool(tool, [binary, *arguments], root), tool, root)
        results.append((describe(tool, binary, root), findings, len(checked)))

    style_check = build_style_check()
    findings = parse(execute_tool("StyleCheck", [style_check, *files], root), "StyleCheck", root)
    results.append(("StyleCheck (Packages/tools)", findings, len(files)))

    for _, findings, _ in results:
        for finding in sorted(findings):
            print(format_finding(finding, github))

    print(f"Style: advisory warnings for {len(files)} Swift files of Arx's own; nothing failed.", flush=True)
    for name, findings, checked in results:
        counts = collections.Counter(finding.rule.split("/")[-1] for finding in findings)
        detail = ", ".join(f"{rule} {count}" for rule, count in sorted(counts.items()))
        print(f"  {name}: {len(findings)} in {checked} files" + (f" ({detail})" if detail else ""), flush=True)


if __name__ == "__main__":
    from .core.process import execute
    raise SystemExit(execute(main))
