"""Lists the dependencies a change adds, removes or moves, for Danger and for a look before pushing (DEV-1281).

It compares two trees: every `Package.resolved` (the pins), every `Package.swift` (the remote
packages and their version rules), the package rows of `THIRD_PARTY_NOTICES.md` and the forks
under `Forks/` (Git submodules). The base is the merge base of `--base` and the head, as a pull
request shows it. Without `--head` it reads the working tree, so

    python3 -m Scripts.dependency_diff

shows what the current checkout changes against `main`. `--markdown` and `--json` write the table
and the list for Danger, which labels the pull request `new dependency` when there is anything.

It only reads the trees through `git`: it never runs, builds or imports what it compares, so the
pull request workflow can point it at a fork's commit. It uses the standard library alone.
"""

import argparse
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NOTICES = "THIRD_PARTY_NOTICES.md"
LABEL = "new dependency"

# The arguments of `.package(url: "…", <requirement>)`, with an optional `name:` first. Local `path:` packages are app-owned.
PACKAGE_URL = re.compile(r'^\s*(?:name:\s*"[^"]*"\s*,\s*)?url:\s*"(?P<url>[^"]+)"\s*,?(?P<requirement>.*)$', re.DOTALL)
# `| [name](url) | version | licence | copyright |`
NOTICE_ROW = re.compile(r"^\|\s*\[(?P<name>[^\]]+)\]\((?P<url>[^)]+)\)\s*\|\s*(?P<version>[^|]*?)\s*\|\s*(?P<licence>[^|]*?)\s*\|")


@dataclass(frozen=True)
class Change:
    source: str  # "pin", "manifest", "notice" or "fork"
    name: str
    change: str  # "added", "removed" or "changed"
    before: str = ""
    after: str = ""
    files: tuple = field(default_factory=tuple)


class Tree:
    """A commit's files, read with `git` and never checked out."""

    def __init__(self, revision, root=ROOT):
        self.revision = revision
        self.root = root

    def _git(self, *arguments):
        return subprocess.run(
            ["git", *arguments], cwd=self.root, check=True, capture_output=True, text=True
        ).stdout

    def entries(self):
        """(mode, path) for every file and submodule in the commit."""
        result = []
        for line in self._git("ls-tree", "-r", "--full-tree", self.revision).splitlines():
            meta, path = line.split("\t", 1)
            mode, kind, object_id = meta.split()
            result.append((mode, path, object_id))
        return result

    def paths(self):
        return [path for mode, path, _ in self.entries() if mode != "160000"]

    def read(self, path):
        try:
            return self._git("show", f"{self.revision}:{path}")
        except subprocess.CalledProcessError:
            return None

    def gitlinks(self):
        return {path: object_id for mode, path, object_id in self.entries() if mode == "160000"}


class WorkTree(Tree):
    """The checkout as it is on disk: tracked and untracked files Git doesn't ignore, and the index's submodules."""

    def __init__(self, root=ROOT):
        super().__init__(None, root)

    def paths(self):
        listed = self._git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split("\0")
        gitlinks = self.gitlinks()
        return sorted({path for path in listed if path and path not in gitlinks and (self.root / path).is_file()})

    def read(self, path):
        file = self.root / path
        return file.read_text() if file.is_file() else None

    def gitlinks(self):
        result = {}
        for line in self._git("ls-files", "--stage").splitlines():
            meta, path = line.split("\t", 1)
            mode, object_id, _ = meta.split()
            if mode == "160000":
                result[path] = object_id
        return result


def normalized_url(url):
    url = url.strip().lower().rstrip("/")
    return url[:-4] if url.endswith(".git") else url


def pin_state(pin):
    """The pin's version or branch with its full revision, so a moved revision under the same version counts."""
    state = pin.get("state", {})
    revision = state.get("revision", "")
    label = state.get("version") or state.get("branch")
    text = f"{label} @ {revision}" if label and revision else label or revision
    # Where it comes from too (`repositoryURL` in version 1 files); the table shows it only when it moved.
    location = pin.get("location") or pin.get("repositoryURL") or ""
    kind = pin.get("kind") or ""
    return f"{text} <{kind + ' ' if kind else ''}{normalized_url(location) if location else ''}>"


def pins(tree):
    """identity -> {state: [files]} over every Package.resolved in the tree."""
    result = {}
    for path in tree.paths():
        if Path(path).name != "Package.resolved":
            continue
        text = tree.read(path)
        if not text:
            continue
        try:
            document = json.loads(text)
        except json.JSONDecodeError:
            raise ValueError(f"{path} isn't valid JSON") from None
        for pin in document.get("pins", document.get("object", {}).get("pins", [])):
            identity = pin.get("identity") or pin.get("package", "").lower()
            result.setdefault(identity, {}).setdefault(pin_state(pin), []).append(path)
    return result


def package_calls(text):
    """The argument text of every `.package(…)` call, with nested parentheses and strings kept whole."""
    calls = []
    start = text.find(".package(")
    while start != -1:
        index = start + len(".package(")
        depth, quoted = 1, False
        while index < len(text) and depth:
            character = text[index]
            if quoted:
                if character == "\\":
                    index += 1
                elif character == '"':
                    quoted = False
            elif character == '"':
                quoted = True
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
            index += 1
        if depth == 0:
            calls.append(text[start + len(".package("):index - 1])
        start = text.find(".package(", index)
    return calls


def manifests(tree):
    """normalized URL -> {requirement: [files]} over every Package.swift outside Forks/."""
    result = {}
    for path in tree.paths():
        if Path(path).name != "Package.swift" or path.startswith("Forks/"):
            continue
        for arguments in package_calls(tree.read(path) or ""):
            match = PACKAGE_URL.match(arguments)
            if not match:
                continue
            requirement = " ".join(match["requirement"].split()).strip(", ")
            result.setdefault(normalized_url(match["url"]), {}).setdefault(requirement, []).append(path)
    return result


def notices(tree):
    """package name -> "version, licence" from THIRD_PARTY_NOTICES.md's tables."""
    result = {}
    for line in (tree.read(NOTICES) or "").splitlines():
        match = NOTICE_ROW.match(line)
        if match:
            result[match["name"]] = f"{match['version']}, {match['licence']}"
    return result


def submodule_urls(tree):
    """path -> normalized URL from the tree's .gitmodules."""
    urls, path, url = {}, None, None
    for line in [*(tree.read(".gitmodules") or "").splitlines(), "[end]"]:
        line = line.strip()
        if line.startswith("["):
            if path:
                urls[path] = url or ""
            path, url = None, None
        elif "=" in line:
            key, value = (part.strip() for part in line.split("=", 1))
            if key == "path":
                path = value
            elif key == "url":
                url = normalized_url(value)
    return urls


def forks(tree):
    """Fork path -> its commit and remote, so a fork pointed at another remote counts too."""
    urls = submodule_urls(tree)
    return {
        path: f"{object_id[:7]} from {urls.get(path) or 'no remote'}"
        for path, object_id in tree.gitlinks().items()
        if path.startswith("Forks/")
    }


FULL_REVISION = re.compile(r"\b([0-9a-f]{7})[0-9a-f]{33}\b")


SOURCE = re.compile(r" <[^>]*>$")


def _describe(states, with_files=False, with_sources=False):
    """States for the table, with revisions shortened; `with_files` names where each state is, and
    `with_sources` keeps a pin's source, which is otherwise left out."""
    described = []
    for state in sorted(states):
        text = FULL_REVISION.sub(r"\1", state if with_sources else SOURCE.sub("", state))
        if with_files:
            text += " in " + ", ".join(sorted(set(states[state])))
        described.append(text)
    return ", ".join(described)


def _placement(states):
    return {state: sorted(set(files)) for state, files in states.items()}


def _files(*state_maps):
    return tuple(sorted({file for states in state_maps for files in states.values() for file in files}))


def compare_states(source, before, after):
    """Compares name -> {state: [files]} maps."""
    changes = []
    for name in sorted(set(before) | set(after)):
        old, new = before.get(name, {}), after.get(name, {})
        if not old:
            changes.append(Change(source, name, "added", "", _describe(new), _files(new)))
        elif not new:
            changes.append(Change(source, name, "removed", _describe(old), "", _files(old)))
        elif set(old) != set(new):
            # Only the source moved: show it.
            sources = {SOURCE.sub("", state) for state in old} == {SOURCE.sub("", state) for state in new}
            changes.append(Change(
                source, name, "changed", _describe(old, with_sources=sources), _describe(new, with_sources=sources),
                _files(old, new),
            ))
        elif _placement(old) != _placement(new):
            # The same states, but used or pinned in other files: added to a package, or moved.
            changes.append(Change(
                source, name, "changed", _describe(old, with_files=True), _describe(new, with_files=True), _files(old, new)
            ))
    return changes


def compare_values(source, before, after, files=()):
    """Compares name -> value maps."""
    changes = []
    for name in sorted(set(before) | set(after)):
        old, new = before.get(name), after.get(name)
        if old is None:
            changes.append(Change(source, name, "added", "", new, tuple(files)))
        elif new is None:
            changes.append(Change(source, name, "removed", old, "", tuple(files)))
        elif old != new:
            changes.append(Change(source, name, "changed", old, new, tuple(files)))
    return changes


def compare(base, head):
    changes = compare_states("pin", pins(base), pins(head))
    changes += compare_states("manifest", manifests(base), manifests(head))
    changes += compare_values("notice", notices(base), notices(head), (NOTICES,))
    old_forks, new_forks = forks(base), forks(head)
    changes += compare_values("fork", old_forks, new_forks, sorted(set(old_forks) | set(new_forks)))
    for index, change in enumerate(changes):
        if change.source == "fork":
            changes[index] = Change("fork", change.name, change.change, change.before, change.after, (change.name,))
    return changes


SOURCE_TITLES = {
    "pin": "Package.resolved",
    "manifest": "Package.swift",
    "notice": NOTICES,
    "fork": "Fork (submodule)",
}


def _cell(text):
    return (text or "–").replace("|", "\\|").replace("\n", " ")


def markdown(changes):
    if not changes:
        return "No dependency changes.\n"
    lines = [
        "| Dependency | Change | Before | After | Where |",
        "| --- | --- | --- | --- | --- |",
    ]
    for change in changes:
        where = SOURCE_TITLES[change.source]
        if change.source != "notice" and change.files:
            where += ": " + ", ".join(f"`{file}`" for file in change.files)
        lines.append(
            f"| `{_cell(change.name)}` | {change.change} | {_cell(change.before)} | {_cell(change.after)} | {_cell(where)} |"
        )
    return "\n".join(lines) + "\n"


def report(changes):
    return {
        "label": LABEL if changes else None,
        "added": sorted({change.name for change in changes if change.change == "added" and change.source != "notice"}),
        "changes": [asdict(change) for change in changes],
    }


def merge_base(base, head, root=ROOT):
    return subprocess.run(
        ["git", "merge-base", base, head], cwd=root, check=True, capture_output=True, text=True
    ).stdout.strip()


def main(arguments=None, root=ROOT):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", default="main", help="the branch or commit the change goes into (default: main)")
    parser.add_argument("--head", help="the commit to compare (default: the working tree)")
    parser.add_argument("--no-merge-base", action="store_true", help="compare with --base itself, not the merge base")
    parser.add_argument("--markdown", type=Path, help="also write the table here")
    parser.add_argument("--json", type=Path, help="also write the changes and the label here")
    options = parser.parse_args(arguments)

    base = options.base
    if not options.no_merge_base:
        base = merge_base(options.base, options.head or "HEAD", root)
    head = Tree(options.head, root) if options.head else WorkTree(root)
    changes = compare(Tree(base, root), head)
    table = markdown(changes)
    print(table, end="")
    if options.markdown:
        options.markdown.parent.mkdir(parents=True, exist_ok=True)
        options.markdown.write_text(table)
    if options.json:
        options.json.parent.mkdir(parents=True, exist_ok=True)
        options.json.write_text(json.dumps(report(changes), indent=2) + "\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(error.stderr or str(error), file=sys.stderr)
        raise SystemExit(error.returncode or 1)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
