"""Find Helium's newest macOS release, compare it with engine.lock.json, and move the pins (DEV-955).

`make engine-upstream` prints whether helium-macos has a release newer than the lock, what kind of
release it is (a Helium minor release on a new Chromium major, a Chromium security respin, or a
Helium-only release) and by when the engine should follow it. `make engine-bump` rewrites the lock
and every file that names the pins to that release. Neither builds anything; the nightly workflow
runs both on a GitHub-hosted runner, then `make engine-anchor-check`.
"""

import base64
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

from ..core.paths import ROOT
from .config import PACKAGE

REPOSITORY = "imputnet/helium-macos"
API = "https://api.github.com"

# The cadence DEVELOPMENT.md › Engine updates sets: a minor release within a week, a security
# respin within 48 hours. A Helium-only release (same Chromium) gets the minor release's week.
KINDS = {
    "minor": ("Helium minor release on a new Chromium major", datetime.timedelta(days=7)),
    "security": ("Chromium security respin", datetime.timedelta(hours=48)),
    "helium": ("Helium-only release on the same Chromium", datetime.timedelta(days=7)),
}

LOCK_PATH = PACKAGE / "engine.lock.json"

# Files that name the pinned revisions or Chromium version in prose or metadata. Credits.rtf is
# generated from THIRD_PARTY_NOTICES.md by `make credits`.
PINNED_FILES = [
    "README.md",
    "THIRD_PARTY_NOTICES.md",
    "Packages/engine/README.md",
    "Packages/engine/Sources/ChromiumBootstrap/Upstream/source-manifest.json",
    "Packages/engine/Sources/ChromiumBootstrap/Config/partition_alloc/buildflags.h",
]


def version_key(text):
    """`0.21.3.1` as `(0, 21, 3, 1)`, or None for a tag that isn't a dotted version."""
    if not isinstance(text, str) or not re.fullmatch(r"\d+(\.\d+)+", text):
        return None
    return tuple(int(part) for part in text.split("."))


def newest(releases, lock):
    """The newest published, non-prerelease helium-macos release past the lock's, or None."""
    current = version_key(lock["helium_macos"]["version"])
    if current is None:
        raise ValueError(f"engine.lock.json's helium_macos version isn't a version: {lock['helium_macos']['version']}")
    candidates = [release for release in releases
                  if not release.get("draft") and not release.get("prerelease")
                  and version_key(release.get("tag_name")) is not None]
    if not candidates:
        return None
    release = max(candidates, key=lambda release: version_key(release["tag_name"]))
    return release if version_key(release["tag_name"]) > current else None


def kind(current_chromium, chromium):
    """`minor` for a new Chromium major, `security` for a new Chromium patch version on the same
    major, `helium` when Chromium stays the same."""
    old, new = version_key(current_chromium), version_key(chromium)
    if old is None or new is None:
        raise ValueError(f"Not a Chromium version: {current_chromium if old is None else chromium}")
    if new[0] != old[0]:
        return "minor"
    if new != old:
        return "security"
    return "helium"


def due(published_at, release_kind):
    """When the engine should be on the release, from its publication time (ISO 8601)."""
    published = datetime.datetime.fromisoformat(published_at.replace("Z", "+00:00"))
    return published + KINDS[release_kind][1]


def github(path, token=None):
    """GET a GitHub REST API path as JSON. `GITHUB_TOKEN` or `GH_TOKEN` raises the rate limit."""
    token = token if token is not None else os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    request = urllib.request.Request(f"{API}/{path}", headers={
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "arx-engine-upstream",
    })
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise ValueError(f"GitHub API {path}: HTTP {error.code}") from error


def releases(api=github):
    return api(f"repos/{REPOSITORY}/releases?per_page=30")


def _repository(url):
    match = re.fullmatch(r"https://github\.com/([^/]+/[^/]+?)(?:\.git)?/?", url or "")
    if not match:
        raise ValueError(f"helium-chromium's submodule isn't a GitHub repository: {url}")
    return match.group(1)


def _text(api, repository, path, ref):
    data = api(f"repos/{repository}/contents/{path}?ref={urllib.parse.quote(ref)}")
    if data.get("encoding") != "base64":
        raise ValueError(f"Unexpected encoding for {repository}/{path}")
    return base64.b64decode(data["content"]).decode()


def resolve(release, api=github):
    """The lock identity a release pins: helium-macos's tag commit, the helium-chromium submodule
    commit at that tag, Helium's version (the tag without its platform revision) and Chromium's."""
    tag = release["tag_name"]
    if version_key(tag) is None or len(version_key(tag)) != 4:
        raise ValueError(f"Expected a four-part helium-macos tag such as 0.21.3.1: {tag}")
    target = api(f"repos/{REPOSITORY}/git/ref/tags/{urllib.parse.quote(tag)}")["object"]
    # An annotated tag points at a tag object; follow it to the commit.
    while target["type"] == "tag":
        target = api(f"repos/{REPOSITORY}/git/tags/{target['sha']}")["object"]
    if target["type"] != "commit":
        raise ValueError(f"helium-macos tag {tag} doesn't point at a commit")
    revision = target["sha"]
    submodule = api(f"repos/{REPOSITORY}/contents/helium-chromium?ref={revision}")
    if submodule.get("type") != "submodule":
        raise ValueError(f"helium-chromium isn't a submodule at helium-macos {tag}")
    helium_repository = _repository(submodule.get("submodule_git_url"))
    chromium = _text(api, helium_repository, "chromium_version.txt", submodule["sha"]).strip()
    if version_key(chromium) is None:
        raise ValueError(f"Helium's chromium_version.txt at {submodule['sha']} isn't a version: {chromium!r}")
    return {
        "helium_macos": {"version": tag, "revision": revision},
        "helium": {"version": tag.rsplit(".", 1)[0], "revision": submodule["sha"],
                   "repository": helium_repository},
        "chromium": chromium,
    }


def check(lock, api=github):
    """What `make engine-upstream` reports: the lock's pins, the newest release and, when it's
    newer, its identity, kind, deadline and notes."""
    release = newest(releases(api), lock)
    result = {
        "current": {"helium_macos": lock["helium_macos"]["version"], "chromium": lock["chromium"]},
        "update": None,
    }
    if release is None:
        return result
    identity = resolve(release, api)
    release_kind = kind(lock["chromium"], identity["chromium"])
    result["update"] = {
        **identity,
        "kind": release_kind,
        "summary": KINDS[release_kind][0],
        "published_at": release["published_at"],
        "due": due(release["published_at"], release_kind).isoformat().replace("+00:00", "Z"),
        "url": release.get("html_url") or f"https://github.com/{REPOSITORY}/releases/tag/{release['tag_name']}",
        "notes": (release.get("body") or "").replace("\r\n", "\n").strip(),
    }
    return result


def bumped_lock(lock, identity):
    """The lock with the release's pins. The ABI, architectures and identities stay."""
    result = json.loads(json.dumps(lock))
    result["helium_macos"]["version"] = identity["helium_macos"]["version"]
    result["helium_macos"]["revision"] = identity["helium_macos"]["revision"]
    result["helium"]["version"] = identity["helium"]["version"]
    result["helium"]["revision"] = identity["helium"]["revision"]
    result["chromium"] = identity["chromium"]
    return result


def replacements(lock, identity):
    """Old text → new text for the pins in prose: full revisions before their short forms."""
    pairs = []
    for key in ["helium_macos", "helium"]:
        old, new = lock[key]["revision"], identity[key]["revision"]
        if old != new:
            pairs.append((old, new))
            pairs.append((old[:7], new[:7]))
    if lock["chromium"] != identity["chromium"]:
        pairs.append((lock["chromium"], identity["chromium"]))
    return pairs


def rewrite(text, pairs):
    for old, new in pairs:
        text = re.sub(rf"(?<![0-9A-Za-z.]){re.escape(old)}(?![0-9A-Za-z])", new, text)
    return text


def bump(identity, root=ROOT, regenerate_credits=None):
    """Write the release's pins into the lock and every file that names them. Returns the paths
    it changed, relative to `root`."""
    lock_path = root / LOCK_PATH.relative_to(ROOT)
    lock = json.loads(lock_path.read_text())
    if version_key(identity["helium_macos"]["version"]) <= version_key(lock["helium_macos"]["version"]):
        raise ValueError(f"helium-macos {identity['helium_macos']['version']} isn't newer than the "
                         f"locked {lock['helium_macos']['version']}")
    pairs = replacements(lock, identity)
    changed = []
    for name in PINNED_FILES:
        path = root / name
        text = path.read_text()
        updated = rewrite(text, pairs)
        if updated != text:
            path.write_text(updated)
            changed.append(name)
        stale = [old for old, _ in pairs if re.search(rf"(?<![0-9A-Za-z.]){re.escape(old)}(?![0-9A-Za-z])", updated)]
        if stale:
            raise ValueError(f"{name} still names {', '.join(stale)}")
    lock_path.write_text(json.dumps(bumped_lock(lock, identity), indent=2) + "\n")
    changed.insert(0, str(lock_path.relative_to(root)))
    # make credits writes this checkout's Credits.rtf, so only for this checkout.
    if regenerate_credits if regenerate_credits is not None else root == ROOT:
        from .. import credits
        credits.main()
        changed.append(str(credits.CREDITS.relative_to(root)))
    return changed


def pull_request(result, anchors=None, clean=False):
    """The title and body of the bump pull request the nightly workflow opens. `result` is what
    `check` returned, `anchors` the anchor check's Markdown report (None when it didn't finish)."""
    current, update = result["current"], result["update"]
    title = (f"Pin the engine to Chromium {update['chromium']} on Helium {update['helium']['version']} "
             f"(helium-macos {update['helium_macos']['version']})")
    if anchors is None:
        anchors = ("### Overlay anchors\n\nThe anchor check didn't finish; see the workflow run. "
                   "Run `make engine-prepare` and `make engine-overlay-report` on this branch.\n")
    overlays = ("Every overlay anchor was found; confirm with `make engine-prepare`." if clean else
                "Re-anchor the overlays the report lists (`make engine-prepare`, then "
                "`make engine-overlay-report`) and refresh their test fixtures.")
    body = "\n".join([
        f"helium-macos [{update['helium_macos']['version']}]({update['url']}) is out: a "
        f"**{update['summary'][0].lower() + update['summary'][1:]}**, Chromium {current['chromium']} → "
        f"{update['chromium']}. The engine should follow it by **{update['due']}** "
        "(DEVELOPMENT.md › Engine updates).",
        "",
        "This branch moves `engine.lock.json` and the files that name the pins. Nothing is built yet.",
        "",
        f"- [ ] {overlays}",
        "- [ ] Label this pull request `engine-build` to build and test it. "
        "It commits the cached engine to this branch and posts the results here.",
        "- [ ] Check by hand what the runner doesn't: the Dock menu and the display smokes.",
        "",
        anchors.rstrip("\n"),
        "",
        "<details><summary>Helium's release notes</summary>",
        "",
        update["notes"],
        "",
        "</details>",
        "",
        "Opened by the nightly engine upstream check (DEV-955).",
    ]) + "\n"
    return title, body


def pull_request_main(arguments=()):
    """`python3 -m Scripts.engine.automation pull-request UPDATE.json ANCHORS.md STATE OUTPUT_DIR`:
    write title.txt and body.md for the workflow."""
    update, anchors, state, output = (list(arguments) + [None] * 4)[:4]
    if output is None:
        raise ValueError("Usage: pull-request UPDATE.json ANCHORS.md STATE OUTPUT_DIR")
    with open(update) as source:
        result = json.load(source)
    text = None
    if os.path.isfile(anchors):
        with open(anchors) as source:
            text = source.read()
    title, body = pull_request(result, text, clean=state == "clean")
    os.makedirs(output, exist_ok=True)
    with open(os.path.join(output, "title.txt"), "w") as handle:
        handle.write(title)
    with open(os.path.join(output, "body.md"), "w") as handle:
        handle.write(body)


def _lock():
    return json.loads(LOCK_PATH.read_text())


def _write_outputs(values):
    """Hand values to later workflow steps through `$GITHUB_OUTPUT` when it's set."""
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def main(arguments=()):
    """`make engine-upstream [ARGS='--json PATH']`: report the newest helium-macos release."""
    arguments = list(arguments)
    destination = None
    if arguments[:1] == ["--json"] and len(arguments) == 2:
        destination = arguments[1]
    elif arguments:
        raise ValueError("Usage: make engine-upstream [ARGS='--json PATH']")
    result = check(_lock())
    if destination:
        os.makedirs(os.path.dirname(os.path.abspath(destination)), exist_ok=True)
        with open(destination, "w") as output:
            json.dump(result, output, indent=2)
            output.write("\n")
    update = result["update"]
    if update is None:
        print(f"engine.lock.json pins helium-macos {result['current']['helium_macos']}, the newest release.")
        _write_outputs({"update": "false"})
        return
    print(f"helium-macos {update['helium_macos']['version']} (Chromium {update['chromium']}) is newer than the "
          f"locked {result['current']['helium_macos']} (Chromium {result['current']['chromium']}).")
    print(f"{update['summary']}; the engine should follow it by {update['due']}.")
    _write_outputs({"update": "true", "version": update["helium_macos"]["version"],
                    "chromium": update["chromium"], "kind": update["kind"], "due": update["due"]})


def bump_main(arguments=()):
    """`make engine-bump ARGS='--json PATH | --version TAG'`: move the pins to a release."""
    arguments = list(arguments)
    if len(arguments) != 2 or arguments[0] not in ("--json", "--version"):
        raise ValueError("Usage: make engine-bump ARGS='--json PATH' (from make engine-upstream) "
                         "or ARGS='--version 0.21.3.1'")
    if arguments[0] == "--json":
        with open(arguments[1]) as source:
            identity = json.load(source)["update"]
        if identity is None:
            raise ValueError(f"{arguments[1]} has no newer release to bump to")
    else:
        release = github(f"repos/{REPOSITORY}/releases/tags/{urllib.parse.quote(arguments[1])}")
        identity = resolve(release)
    for name in bump(identity):
        print(f"Updated {name}")
    print("Check the allocator bootstrap's vendored files against the new tree "
          "(make engine-anchor-check lists them).", file=sys.stderr)

