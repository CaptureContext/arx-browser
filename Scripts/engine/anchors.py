"""Check every overlay anchor against a Helium release without the 30 GB Chromium tree (DEV-955).

`make engine-anchor-check` builds a sparse copy of the tree `make engine-prepare` would make for
engine.lock.json: it fetches only the Chromium files Arx's overlays touch, at the locked Chromium
tag, applies Helium's patches for those files (helium-chromium's series, then helium-macos's) and
Helium's domain substitution, and runs the real overlays on it. A file is fetched the first time
an overlay opens it, so the set follows the overlays without a list to keep.

The tree is close to the prepared one, not identical: Helium's name substitution and
translations (.grd, .grdp and .xtb files), its version stamp (chrome/VERSION) and its resource
replacements aren't simulated, and the report names any such file an overlay touches. Treat the
result as the nightly first look; `make engine-overlay-report` on a prepared tree is the authority.
"""

import base64
import configparser
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import tarfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

from ..core.paths import ROOT
from . import overlay
from .config import LOCK, PACKAGE

GITILES = "https://chromium.googlesource.com"
WORK = ROOT / "build/engine-anchors"
BOOTSTRAP_MANIFEST = PACKAGE / "Sources/ChromiumBootstrap/Upstream/source-manifest.json"
# More rounds than the overlays could ever open files; a loop that reaches it is a bug.
ROUNDS = 2000


# MARK: - Unified diffs

class Hunk:
    def __init__(self, old_start, old_count, lines):
        self.old_start = old_start
        self.old_count = old_count
        self.lines = lines

    def operations(self):
        """The hunk's lines as `(marker, text)` pairs (" ", "-" or "+"), with "\\ No newline at
        end of file" applied to the line before it."""
        result = []
        for line in self.lines:
            if line.startswith("\\"):
                if result and result[-1][1].endswith("\n"):
                    result[-1] = (result[-1][0], result[-1][1][:-1])
                continue
            marker, text = line[:1] or " ", line[1:] or "\n"
            result.append((marker, text))
        return result

    def sides(self):
        """The hunk's old and new lines."""
        operations = self.operations()
        return ([text for marker, text in operations if marker in " -"],
                [text for marker, text in operations if marker in " +"])


class Section:
    """One file's part of a patch. `old` and `new` are tree-relative paths, None for /dev/null."""

    def __init__(self, old, new, hunks):
        self.old = old
        self.new = new
        self.hunks = hunks

    @property
    def path(self):
        return self.new or self.old


def _diff_path(text):
    text = text.rstrip("\n").split("\t", 1)[0].strip()
    if text == "/dev/null":
        return None
    return text.split("/", 1)[1] if "/" in text else text


HUNK_HEADER = re.compile(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def sections(text):
    """Split a patch into per-file sections. Hunk lengths come from the headers, so a removed
    line that starts with `-- ` isn't taken for the next file's header."""
    lines = text.splitlines(keepends=True)
    result = []
    index = 0
    while index < len(lines):
        if not (lines[index].startswith("--- ") and index + 1 < len(lines)
                and lines[index + 1].startswith("+++ ")):
            index += 1
            continue
        old, new = _diff_path(lines[index][4:]), _diff_path(lines[index + 1][4:])
        index += 2
        hunks = []
        while index < len(lines) and lines[index].startswith("@@ "):
            match = HUNK_HEADER.match(lines[index])
            if not match:
                raise ValueError(f"Malformed hunk header: {lines[index].strip()}")
            old_start, old_count = int(match.group(1)), int(match.group(2) or 1)
            new_count = int(match.group(4) or 1)
            index += 1
            body = []
            remaining_old, remaining_new = old_count, new_count
            while index < len(lines) and (remaining_old > 0 or remaining_new > 0):
                line = lines[index]
                marker = line[:1]
                if marker == "\\":
                    body.append(line)
                elif marker == "-":
                    remaining_old -= 1
                    body.append(line)
                elif marker == "+":
                    remaining_new -= 1
                    body.append(line)
                elif marker in (" ", "\n", "\r"):
                    remaining_old -= 1
                    remaining_new -= 1
                    body.append(line if marker == " " else " " + line)
                else:
                    raise ValueError(f"Hunk for {new or old} ends early: {line.strip()}")
                index += 1
            if index < len(lines) and lines[index].startswith("\\"):
                body.append(lines[index])
                index += 1
            hunks.append(Hunk(old_start, old_count, body))
        result.append(Section(old, new, hunks))
    return result


def _normal(line):
    return " ".join(line.split())


def _find(lines, wanted, expected, loose):
    if not wanted:
        return min(max(expected, 0), len(lines))
    compare = (lambda a, b: _normal(a) == _normal(b)) if loose else (lambda a, b: a == b)
    limit = len(lines) - len(wanted)
    for distance in range(0, max(limit, 0) + max(expected, 0) + 2):
        for start in (expected + distance, expected - distance) if distance else (expected,):
            if 0 <= start <= limit and all(compare(lines[start + offset], line)
                                           for offset, line in enumerate(wanted)):
                return start
    return None


def apply_section(text, section):
    """Apply a section's hunks to `text` (None when the file doesn't exist) as GNU patch would
    with `--ignore-whitespace` and its default fuzz of 2: exact context first, then context
    compared without whitespace, then up to two context lines dropped at each end. Returns the
    new text, or None when the section deletes the file."""
    if section.new is None:
        return None
    lines = (text or "").splitlines(keepends=True)
    # Hunk headers number the original file's lines; `offset` maps them to the lines as patched.
    offset = 0
    for hunk in section.hunks:
        operations = hunk.operations()
        # A hunk that removes nothing inserts after line `old_start`; any other starts at it.
        original = max(hunk.old_start - 1, 0) if hunk.old_count else hunk.old_start
        expected = original + offset
        placed = None
        for fuzz in range(3):
            leading = min(fuzz, _context(operations, leading=True))
            trailing = min(fuzz, _context(operations, leading=False))
            if fuzz and not (leading or trailing):
                break
            trimmed = operations[leading:len(operations) - trailing]
            wanted = [text for marker, text in trimmed if marker in " -"]
            for loose in (False, True):
                start = _find(lines, wanted, expected + leading, loose)
                if start is not None:
                    placed = (start, leading, trimmed, len(wanted))
                    break
            if placed:
                break
        if placed is None:
            raise ValueError(f"A hunk at line {hunk.old_start} doesn't apply to {section.path}")
        start, leading, trimmed, removed = placed
        # Context keeps the file's own text, as GNU patch does when whitespace differs.
        replacement = []
        position = start
        for marker, text in trimmed:
            if marker == " ":
                replacement.append(lines[position])
                position += 1
            elif marker == "-":
                position += 1
            else:
                replacement.append(text)
        lines[start:start + removed] = replacement
        offset = start - leading - original + len(replacement) - removed
    return "".join(lines)


def _context(operations, leading):
    count = 0
    for marker, _ in (operations if leading else reversed(operations)):
        if marker != " ":
            break
        count += 1
    return count


def series(patches):
    """The patches a GNU quilt `series` file lists, in order."""
    result = []
    for line in (patches / "series").read_text().splitlines():
        name = line.split("#", 1)[0].strip()
        if name:
            result.append(patches / name)
    return result


def patches_by_file(directories):
    """Each tree-relative path → the sections that change it, in the order Helium applies them."""
    result = {}
    for directory in directories:
        for patch in series(directory):
            for section in sections(patch.read_text(encoding="utf-8", errors="surrogateescape")):
                result.setdefault(section.path, []).append((patch.relative_to(directory), section))
    return result


# MARK: - Helium's domain substitution

class DomainSubstitution:
    def __init__(self, helium):
        self.files = set(filter(None, (helium / "domain_substitution.list").read_text().splitlines()))
        self.pairs = []
        for line in filter(None, (helium / "domain_regex.list").read_text().splitlines()):
            pattern, replacement = line.split("#")
            self.pairs.append((re.compile(pattern), replacement))

    def __call__(self, relative, text):
        if relative not in self.files:
            return text
        for pattern, replacement in self.pairs:
            text = pattern.sub(replacement, text)
        return text


# MARK: - Fetching Chromium

def gitiles(repository, revision, path, attempts=4):
    """A file's text from Chromium's Gitiles, or None when it isn't there."""
    url = f"{GITILES}/{repository}/+/{revision}/{path}?format=TEXT"
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "arx-engine-anchors"})
            with urllib.request.urlopen(request, timeout=60) as response:
                return base64.b64decode(response.read()).decode("utf-8", errors="surrogateescape")
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            if error.code not in (429, 500, 502, 503, 504) or attempt == attempts - 1:
                raise ValueError(f"Gitiles {repository}/{path}: HTTP {error.code}") from error
        except urllib.error.URLError as error:
            if attempt == attempts - 1:
                raise ValueError(f"Gitiles {repository}/{path}: {error.reason}") from error
        time.sleep(2 ** attempt)


DEPS_ENTRY = re.compile(
    r"'src/([^']+)':\s*(?:\{\s*'url':\s*)?Var\('chromium_git'\)\s*\+\s*'/([^']+?)(?:\.git)?'"
    r"\s*\+\s*'@'\s*\+\s*(?:'([0-9a-f]{40})'|Var\('([A-Za-z0-9_]+)'\))")
DEPS_VARIABLE = re.compile(r"^\s*'([A-Za-z0-9_]+)':\s*'([0-9a-f]{40})',", re.MULTILINE)


class Chromium:
    """Chromium's files at a version tag, from chromium/src and, for a path in another
    repository DEPS pulls in (such as PartitionAlloc), from that repository at its DEPS pin."""

    def __init__(self, version, fetch=gitiles):
        self.version = version
        self.fetch = fetch
        self._deps = None

    def deps(self):
        if self._deps is None:
            text = self.fetch("chromium/src", f"refs/tags/{self.version}", "DEPS") or ""
            variables = dict(DEPS_VARIABLE.findall(text))
            entries = [(path, repository, revision or variables.get(variable))
                       for path, repository, revision, variable in DEPS_ENTRY.findall(text)]
            self._deps = sorted((entry for entry in entries if entry[2]), key=lambda entry: -len(entry[0]))
        return self._deps

    def read(self, relative):
        for path, repository, revision in self.deps():
            if relative.startswith(path + "/"):
                return self.fetch(repository, revision, relative[len(path) + 1:])
        return self.fetch("chromium/src", f"refs/tags/{self.version}", relative)


class Deps:
    """Files from the archives Helium's deps.ini unpacks into the tree after Chromium (uBlock,
    the onboarding page, search engine data). An archive is downloaded the first time an
    overlay needs a file from it, and checked against its pinned SHA-256."""

    def __init__(self, helium, download=None):
        parser = configparser.ConfigParser()
        parser.read(helium / "deps.ini")
        self.download = download or _download
        self.entries = []
        for name in parser.sections():
            properties = parser[name]
            output = PurePosixPath(properties["output_path"]).as_posix().removeprefix("./")
            self.entries.append((output, name, properties))
        self.entries.sort(key=lambda entry: -len(entry[0]))
        self.archives = {}

    def covers(self, relative):
        return any(relative.startswith(output + "/") for output, _, _ in self.entries)

    def read(self, relative):
        for output, name, properties in self.entries:
            if not relative.startswith(output + "/"):
                continue
            if name not in self.archives:
                data = self.download(properties["url"])
                expected = properties.get("sha256")
                if expected and hashlib.sha256(data).hexdigest() != expected:
                    raise ValueError(f"deps.ini {name}: the download's SHA-256 isn't the pinned one")
                self.archives[name] = data
            member = relative[len(output) + 1:]
            prefix = properties.get("strip_leading_dirs")
            if prefix:
                member = f"{prefix}/{member}"
            data = _extract(self.archives[name], properties.get("download_filename") or properties["url"], member)
            return None if data is None else data.decode("utf-8", errors="surrogateescape")
        raise ValueError(f"{relative} isn't in a deps.ini archive")


def _download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "arx-engine-anchors"})
    with urllib.request.urlopen(request, timeout=300) as response:
        return response.read()


def _extract(data, filename, member):
    if filename.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            try:
                return archive.read(member)
            except KeyError:
                return None
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for candidate in (member, f"./{member}"):
            try:
                handle = archive.extractfile(candidate)
            except KeyError:
                continue
            return handle.read() if handle else None
    return None


# MARK: - The sparse tree

# Files Helium changes in steps the sparse tree doesn't simulate.
UNSIMULATED = re.compile(r"(\.(grd|grdp|xtb)$)|(^chrome/VERSION$)")


class SparseTree:
    def __init__(self, root, read, patches, substitute):
        """`read(relative)` is the unpatched file's text: Chromium's, or a deps.ini archive's."""
        self.root = root
        self.read = read
        self.patches = patches
        self.substitute = substitute
        self.fetched = {}
        self.absent = []
        self.failures = []

    def materialize(self, relative):
        """Write Helium's version of a file into the tree; False when neither Chromium nor
        Helium's patches have it. A Helium patch that doesn't apply is recorded and the file is
        written as far as it got."""
        changes = self.patches.get(relative, [])
        # A patch that moves a file starts from the old path's text.
        first = changes[0][1] if changes else None
        text = self.read(first.old if first and first.old and first.old != relative else relative)
        for patch, section in changes:
            try:
                text = apply_section(text, section)
            except ValueError as error:
                self.failures.append(f"{patch}: {error}")
        if text is not None:
            text = self.substitute(relative, text)
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8", errors="surrogateescape")
        self.fetched[relative] = text is not None
        return text is not None

    def run(self, apply=None):
        """Run the overlays, fetching each file the first time one opens it. Returns
        `(missing, stopped)` as `collect` does."""
        run_overlays = apply or collect
        placeholders = set()
        for _ in range(ROUNDS):
            try:
                return run_overlays(self.root)
            except FileNotFoundError as error:
                path = Path(error.filename or "")
                try:
                    relative = path.resolve().relative_to(self.root.resolve()).as_posix()
                except ValueError:
                    raise error from None
                if relative not in self.fetched:
                    if not self.materialize(relative):
                        # An overlay may be creating it; give it a directory to write into.
                        path.parent.mkdir(parents=True, exist_ok=True)
                elif not self.fetched[relative] and relative not in placeholders:
                    # Opened for reading and not upstream: let its anchors show up as missing.
                    placeholders.add(relative)
                    self.absent.append(relative)
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("")
                else:
                    raise
        raise ValueError(f"The overlays kept opening new files after {ROUNDS} rounds")


def collect(source):
    """Apply every overlay to `source`, collecting missing anchors as `make engine-overlay-report`
    does instead of stopping at the first. Returns `(missing, stopped)`: each missing anchor as
    `(overlay file, line, path, times found, first anchor line)`, and the error an overlay stopped
    with, or None. Other errors, such as a file the tree doesn't have yet, propagate.

    It sets `overlay._missing` itself rather than sharing a helper with `overlay.report`:
    overlay.py is part of the cached engine's fingerprint, so changing it means a new engine."""
    overlay._missing = []
    stopped = None
    try:
        overlay.apply(source, team="")
    except ValueError as error:
        stopped = error
    finally:
        missing, overlay._missing = overlay._missing, None
    return missing, stopped


# MARK: - Checking a release

def checkout(destination, lock=LOCK, run=subprocess.run):
    """Shallow clones of the locked helium-macos and helium-chromium commits: their patches and
    lists, not Chromium."""
    if destination.exists():
        shutil.rmtree(destination)
    macos = destination / "helium-macos"

    def fetch(repository, revision, path):
        path.mkdir(parents=True)
        for arguments in (["init", "--quiet"], ["remote", "add", "origin", repository],
                          ["fetch", "--quiet", "--depth", "1", "origin", revision],
                          ["checkout", "--quiet", "--detach", "FETCH_HEAD"]):
            run(["git", *arguments], cwd=path, check=True)

    fetch(lock["helium_macos"]["repository"], lock["helium_macos"]["revision"], macos)
    modules = (macos / ".gitmodules").read_text()
    match = re.search(r'\[submodule "helium-chromium"\][^\[]*?url\s*=\s*(\S+)', modules)
    if not match:
        raise ValueError("helium-macos has no helium-chromium submodule")
    helium = macos / "helium-chromium"
    shutil.rmtree(helium, ignore_errors=True)
    fetch(match.group(1), lock["helium"]["revision"], helium)
    version = (helium / "chromium_version.txt").read_text().strip()
    if version != lock["chromium"]:
        raise ValueError(f"Helium {lock['helium']['revision'][:7]} is on Chromium {version}, "
                         f"but engine.lock.json pins {lock['chromium']}")
    return macos, helium


def bootstrap(tree, manifest=BOOTSTRAP_MANIFEST):
    """The allocator bootstrap's vendored files: which still match the new tree."""
    result = []
    for entry in json.loads(manifest.read_text())["files"]:
        relative = entry["source"]
        if relative not in tree.fetched:
            tree.materialize(relative)
        path = tree.root / relative
        if not tree.fetched[relative]:
            result.append((relative, "not found at this release"))
        elif hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"]:
            result.append((relative, "unchanged"))
        else:
            result.append((relative, "changed: refresh the vendored copy"))
    return result


def check(work=WORK, lock=LOCK, chromium=None, deps=None, fetch_helium=checkout, manifest=BOOTSTRAP_MANIFEST):
    """Run the overlays on a sparse tree for `lock`. Returns the report as a dict."""
    macos, helium = fetch_helium(work / "helium", lock)
    chromium = chromium or Chromium(lock["chromium"])
    deps = deps or Deps(helium)

    def read(relative):
        return deps.read(relative) if deps.covers(relative) else chromium.read(relative)

    tree = SparseTree(work / "src", read,
                      patches_by_file([helium / "patches", macos / "patches"]),
                      DomainSubstitution(helium))
    if tree.root.exists():
        shutil.rmtree(tree.root)
    tree.root.mkdir(parents=True)
    # Before the overlays run, so the hashes are of Helium's files, not Arx's edits.
    vendored = bootstrap(tree, manifest)
    missing, stopped = tree.run()
    return {
        "helium_macos": lock["helium_macos"]["version"],
        "chromium": lock["chromium"],
        "missing": [{"overlay": name, "line": line, "path": Path(path).relative_to(tree.root).as_posix(),
                     "found": count, "anchor": anchor} for name, line, path, count, anchor in missing],
        "stopped": str(stopped) if stopped else None,
        "absent": tree.absent,
        "patch_failures": tree.failures,
        "unsimulated": sorted(relative for relative, exists in tree.fetched.items()
                              if exists and UNSIMULATED.search(relative)),
        "files": sum(tree.fetched.values()),
        "bootstrap": vendored,
    }


def clean(result):
    return not (result["missing"] or result["stopped"] or result["absent"] or result["patch_failures"])


def markdown(result):
    """The report the bump pull request carries."""
    lines = [f"### Overlay anchors at helium-macos {result['helium_macos']} (Chromium {result['chromium']})", ""]
    if clean(result):
        lines.append(f"Every overlay applies ({result['files']} upstream files checked).")
    else:
        lines.append(f"{result['files']} upstream files checked.")
    if result["missing"]:
        lines += ["", f"**{len(result['missing'])} missing anchors**", "",
                  "| Overlay | File | Found | Anchor |", "| --- | --- | --- | --- |"]
        for item in result["missing"]:
            anchor = item["anchor"].replace("|", "\\|").replace("`", "'")
            lines.append(f"| `{item['overlay']}:{item['line']}` | `{item['path']}` | {item['found']} | `{anchor}` |")
    if result["stopped"]:
        lines += ["", f"**An overlay stopped:** {result['stopped']}"]
    if result["absent"]:
        lines += ["", "**Files the overlays read that aren't in Chromium or Helium at this release:**", ""]
        lines += [f"- `{path}`" for path in result["absent"]]
    if result["patch_failures"]:
        lines += ["", "**Helium patches the check couldn't apply** (the file was checked as far as they went):", ""]
        lines += [f"- {failure}" for failure in result["patch_failures"]]
    if result["unsimulated"]:
        lines += ["", "Helium also changes these files in steps the check doesn't simulate; confirm them with "
                  "`make engine-overlay-report`:", ""]
        lines += [f"- `{path}`" for path in result["unsimulated"]]
    lines += ["", "**Allocator bootstrap's vendored files**", ""]
    lines += [f"- `{path}`: {status}" for path, status in result["bootstrap"]]
    return "\n".join(lines) + "\n"


def main(arguments=()):
    """`make engine-anchor-check [ARGS='--report PATH --json PATH']`."""
    arguments = list(arguments)
    options = {}
    while arguments:
        name = arguments.pop(0)
        if name not in ("--report", "--json") or not arguments:
            raise ValueError("Usage: make engine-anchor-check [ARGS='--report PATH] [--json PATH]']")
        options[name] = Path(arguments.pop(0))
    result = check()
    text = markdown(result)
    print(text, end="")
    for name, content in (("--report", text), ("--json", json.dumps(result, indent=2) + "\n")):
        if name in options:
            options[name].parent.mkdir(parents=True, exist_ok=True)
            options[name].write_text(content)
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as handle:
            handle.write(f"anchors={'clean' if clean(result) else 'missing'}\n")
    if not clean(result):
        raise ValueError("The overlays don't all apply at this release; see the report above.")
