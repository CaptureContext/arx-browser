"""make appcast: the Sparkle feed and delta updates for a signed, notarized release disk image.

Nothing is uploaded. The output folder holds what one GitHub release needs: the disk image, a copy
of it named Arx.dmg, deltas from the previous releases, and the feeds whose enclosures point at that
release's tag. The command prints the `gh` commands that would publish them; run them yourself after
checking.

Arx.dmg is the stable name the website links to, releases/latest/download/Arx.dmg. The feed, the
deltas and --previous only ever use the versioned name, Arx-<version>-<build>-<arch>.dmg, which
Arx.dmg never matches.

There are two channels (DEV-888). The Stable feed, appcast.xml, is an asset of the release marked
latest. The Beta feed, appcast-beta.xml, is an asset of the fixed `beta-feed` prerelease and is
replaced on every release of either channel: it always lists the newest build of all, so people on
Beta get stable releases too. Build numbers only go up across both channels, so the newest release
is always the highest build, and nobody is offered a downgrade.

A release's tag is its version alone, x.y.z, with no prefix and no build number. Two builds of one
version can't both be released, so every release needs a new version as well as a new build.

The EdDSA private key is read from the login keychain by Sparkle's tools, under the
dev.capturecontext.arx account generate_keys stores it in. It's never passed on the command line, written to the repository or printed.
"""

import argparse
import filecmp
import plistlib
import re
import shlex
import shutil
import xml.etree.ElementTree as XML
from dataclasses import dataclass
from pathlib import Path

from . import release
from .core.paths import ROOT
from .core.process import run


OUTPUT = release.RELEASE / "appcast"
TOOL_DIRECTORIES = (
    # make dmg's Release build resolves Sparkle here.
    release.DERIVED_DATA / "SourcePackages/artifacts/sparkle/Sparkle/bin",
    # swift build and swift test resolve it here.
    ROOT / ".build/artifacts/sparkle/Sparkle/bin",
)
TOOLS = ("generate_appcast", "sign_update", "generate_keys")
DISK_IMAGE = re.compile(r"^Arx-(?P<version>\d+(?:\.\d+)*)-(?P<build>\d+)-(?P<architecture>[a-z0-9_]+)\.dmg$")
# Every release also carries its disk image under this fixed name, for the website's
# releases/latest/download/Arx.dmg link. It matches neither DISK_IMAGE nor the Arx-*.dmg globs.
DOWNLOAD_IMAGE = "Arx.dmg"
PLACEHOLDER = "ARX_RELEASES_"
# The Arx repository: both feeds, the disk images and the deltas are its release assets.
RELEASES_REPOSITORY = "capturecontext/arx-browser"
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MAXIMUM_DELTAS = 5
# The keychain account Sparkle's tools keep Arx's EdDSA key under, apart from other apps' keys.
KEY_ACCOUNT = "dev.capturecontext.arx"
CHANNELS = release.CHANNELS
STABLE_FEED = "appcast.xml"
BETA_FEED = "appcast-beta.xml"
# The prerelease whose appcast-beta.xml asset is the Beta feed. It's never marked latest.
BETA_FEED_TAG = "beta-feed"
# Where What's New links to the full notes (the manual's release notes page).
FULL_RELEASE_NOTES = "https://manual.arx.capturecontext.dev/help/release-notes"


@dataclass(frozen=True)
class Image:
    path: Path
    version: str
    build: int

    @property
    def tag(self):
        """The release's tag: the version alone, such as 0.2.0."""
        return self.version


def parse_image(path):
    """Version and build number from make dmg's name for a disk image."""
    path = Path(path)
    match = DISK_IMAGE.match(path.name)
    if not match:
        raise ValueError(f"{path.name} isn't a make dmg disk image (Arx-<version>-<build>-<arch>.dmg)")
    return Image(path, match["version"], int(match["build"]))


def previous_images(directory, current):
    """The earlier releases deltas are made from. A build at or above the new one means the
    folder is wrong or the build number wasn't bumped: Arx never ships a downgrade or a repeat.
    A release is tagged with its version alone, so an earlier build of the same version means
    the version wasn't bumped."""
    directory = Path(directory)
    if not directory.is_dir():
        raise ValueError(f"No folder of previous releases at {directory}")
    # Arx-*.dmg leaves out Arx.dmg, the copy every release carries: downloaded beside the versioned
    # images, it's the same build again under a name without one.
    images = [parse_image(path) for path in sorted(directory.glob("Arx-*.dmg"))]
    newer = [image.path.name for image in images if image.build >= current.build]
    if newer:
        raise ValueError(
            f"Build {current.build} isn't newer than these previous releases: {', '.join(newer)}. "
            "Run make version or make dmg again so the build number goes up."
        )
    released = [image.path.name for image in images if image.version == current.version]
    if released:
        raise ValueError(
            f"Version {current.version} was already released as {', '.join(released)}, "
            f"and a release's tag is its version alone. Bump the version (make version ARGS=<x.y.z>), "
            "then make dmg again."
        )
    return sorted(images, key=lambda image: image.build)


def tools(directories=None):
    for directory in directories or TOOL_DIRECTORIES:
        if all((Path(directory) / name).is_file() for name in TOOLS):
            return Path(directory)
    raise ValueError("Sparkle's tools weren't found. Run make dmg, or make resolve and make test, first.")


def repository(value):
    value = (value or "").strip()
    if not REPOSITORY.match(value) or PLACEHOLDER in value:
        raise ValueError("Pass --repository owner/name for the public GitHub repository the release goes to.")
    return value


def app_info(app):
    with (Path(app) / "Contents/Info.plist").open("rb") as source:
        return plistlib.load(source)


def app_problems(info, image, repository_name, update_channel="stable"):
    """The app the disk image was made from must trust the key that signs the feed, read the feeds
    this release publishes, be built for its channel, and be the build the disk image is named for."""
    problems = []
    if str(info.get("CFBundleVersion", "")).strip() != str(image.build):
        problems.append(f"the app is build {info.get('CFBundleVersion')!r}, the disk image says {image.build}")
    if str(info.get("CFBundleShortVersionString", "")).strip() != image.version:
        problems.append(f"the app is version {info.get('CFBundleShortVersionString')!r}, the disk image says {image.version}")
    if not str(info.get("SUPublicEDKey", "")).strip():
        problems.append("SUPublicEDKey is empty; set ARX_UPDATE_PUBLIC_ED_KEY and build again")
    feed = str(info.get("SUFeedURL", "")).strip()
    if feed != feed_url(repository_name):
        problems.append(f"SUFeedURL is {feed!r}, expected {feed_url(repository_name)!r}")
    beta = str(info.get("ArxBetaFeedURL", "")).strip()
    if beta != beta_feed_url(repository_name):
        problems.append(f"ArxBetaFeedURL is {beta!r}, expected {beta_feed_url(repository_name)!r}")
    built_for = str(info.get("ArxUpdateChannel", "")).strip().lower() or "stable"
    if built_for != update_channel:
        problems.append(f"the app was built for the {built_for} channel; run make dmg ARGS='--channel {update_channel}'")
    return problems


def feed_url(repository_name):
    return f"https://github.com/{repository_name}/releases/latest/download/appcast.xml"


def beta_feed_url(repository_name):
    return f"https://github.com/{repository_name}/releases/download/{BETA_FEED_TAG}/{BETA_FEED}"


def download_prefix(repository_name, image):
    return f"https://github.com/{repository_name}/releases/download/{image.tag}/"


def public_key(bin_directory):
    """The public half of the keychain's EdDSA key. Prints nothing secret."""
    output = run([str(bin_directory / "generate_keys"), "--account", KEY_ACCOUNT, "-p"], capture=True)
    return output.strip().splitlines()[-1].strip() if output.strip() else ""


def overlap_problems(output, inputs):
    """The output folder is emptied first, so it may not be or hold anything the release is made from:
    the disk image, the previous releases' folder or the app."""
    output = Path(output).resolve()
    problems = []
    for path in inputs:
        path = Path(path).resolve()
        if path == output or output in path.parents:
            problems.append(f"{path} is inside the output folder {output}")
        elif path.is_dir() and path in output.parents and path.suffix == ".app":
            problems.append(f"the output folder {output} is inside the app {path}")
    return problems


def stage(image, previous, output, notes=None):
    """A fresh folder with the new disk image and the previous ones generate_appcast diffs against.
    Release notes go next to the new disk image under its name, which is how generate_appcast
    finds them."""
    output = Path(output)
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    for source in [*(item.path for item in previous), image.path]:
        shutil.copy2(source, output / source.name)
    if notes:
        shutil.copy2(notes, output / notes_name(image))
    return output


def stage_download_image(output, image):
    """Copies the new disk image, as generate_appcast signed and sign_update verified it, to Arx.dmg.
    It runs after generate_appcast, which takes every disk image in the folder for an update
    archive and would find Arx.dmg to be a second one of the same build."""
    output = Path(output)
    source = output / image.path.name
    destination = output / DOWNLOAD_IMAGE
    shutil.copy2(source, destination)
    if not filecmp.cmp(source, destination, shallow=False):
        raise ValueError(f"{DOWNLOAD_IMAGE} isn't the same as {source.name}")
    return destination


def notes_name(image):
    return Path(image.path.name).with_suffix(".md").name


def notes_problems(notes):
    """Release notes are a short Markdown file: What's New shows them as they are."""
    if notes is None:
        return []
    notes = Path(notes)
    if not notes.is_file():
        return [f"No release notes at {notes}"]
    if notes.suffix.lower() != ".md":
        return [f"{notes.name} isn't Markdown (.md)"]
    if not notes.read_text().strip():
        return [f"{notes.name} is empty"]
    return []


def generate_arguments(bin_directory, output, repository_name, image, *, full_notes=FULL_RELEASE_NOTES, embed_notes=False):
    notes = ["--embed-release-notes"] if embed_notes else []
    return [
        str(bin_directory / "generate_appcast"),
        "--account", KEY_ACCOUNT,
        "--download-url-prefix", download_prefix(repository_name, image),
        "--link", f"https://github.com/{repository_name}/releases",
        # Only the new release is listed, whatever minimum macOS earlier ones had; deltas from
        # earlier builds hang off it, and every URL in the feed points at this release's tag.
        "--versions", str(image.build),
        "--maximum-versions", "1",
        "--maximum-deltas", str(MAXIMUM_DELTAS),
        # What's New links here for everything the short notes leave out.
        "--full-release-notes-url", full_notes,
        *notes,
        str(output),
    ]


def enclosure_signature(appcast, image_name):
    """The EdDSA signature generate_appcast wrote for the new disk image."""
    root = XML.parse(appcast).getroot()
    for enclosure in root.iter("enclosure"):
        if enclosure.get("url", "").endswith("/" + image_name):
            signature = enclosure.get(f"{{{SPARKLE}}}edSignature")
            if signature:
                return signature
    raise ValueError(f"appcast.xml has no signed enclosure for {image_name}")


def appcast_versions(appcast):
    root = XML.parse(appcast).getroot()
    return [element.text.strip() for element in root.iter(f"{{{SPARKLE}}}version") if element.text]


def write_feeds(output, update_channel):
    """generate_appcast writes appcast.xml. A stable release is the newest build of both channels,
    so the same feed is the Beta feed too; a beta release only replaces the Beta feed."""
    output = Path(output)
    generated = output / STABLE_FEED
    shutil.copy2(generated, output / BETA_FEED)
    if update_channel == "beta":
        generated.unlink()
    return [output / name for name in ((STABLE_FEED, BETA_FEED) if update_channel == "stable" else (BETA_FEED,))]


def release_assets(output, image, update_channel="stable"):
    output = Path(output)
    assets = [output / image.path.name]
    checksum = release.checksum_path(image.path)
    if checksum.is_file():
        assets.append(checksum)
    # Both channels carry it; releases/latest/download/Arx.dmg finds only the release marked latest.
    assets.append(output / DOWNLOAD_IMAGE)
    assets += sorted(output.glob("*.delta"))
    if update_channel == "stable":
        # releases/latest/download/appcast.xml follows the release marked latest.
        assets.append(output / STABLE_FEED)
    return assets


def release_commands(repository_name, image, assets, output, update_channel="stable", notes=None):
    """The commands that would publish the release and its feeds. Printed, never run."""
    arguments = [
        "gh", "release", "create", image.tag,
        "--repo", repository_name,
        # The title is the version alone, like the tag; the build number is in the feed.
        "--title", image.version,
    ]
    arguments += ["--notes-file", str(notes)] if notes else ["--notes", f"Arx {image.version}, build {image.build}."]
    # Only stable releases become latest; the Stable feed URL follows the release marked latest.
    arguments += ["--latest"] if update_channel == "stable" else ["--prerelease", "--latest=false"]
    beta_feed = [
        "gh", "release", "upload", BETA_FEED_TAG,
        "--repo", repository_name, "--clobber", str(Path(output) / BETA_FEED),
    ]
    return [shlex.join([*arguments, *map(str, assets)]), shlex.join(beta_feed)]


def beta_feed_setup_command(repository_name):
    """Creates the Beta feed's prerelease once, before the first upload."""
    return shlex.join([
        "gh", "release", "create", BETA_FEED_TAG,
        "--repo", repository_name, "--prerelease", "--latest=false",
        "--title", "Arx beta feed",
        "--notes", "The Beta channel's update feed. Its appcast-beta.xml is replaced on every release.",
    ])


def check_disk_image(image, *, notarized=True):
    run(["codesign", "--verify", "--strict", "--verbose=2", str(image.path)])
    if notarized:
        run(["xcrun", "stapler", "validate", str(image.path)])


def parser():
    result = argparse.ArgumentParser(
        prog="make appcast",
        description="Sign a release disk image and generate its Sparkle appcast and deltas. Publishes nothing.",
    )
    result.add_argument("image", nargs="?", type=Path, help="the release disk image (default: the newest in build/release)")
    result.add_argument(
        "--repository", default=RELEASES_REPOSITORY,
        help=f"the GitHub repository the release goes to, owner/name (default: {RELEASES_REPOSITORY})",
    )
    result.add_argument(
        "--previous", type=Path, required=True,
        help="a folder with earlier release disk images (Arx-*.dmg) to make deltas from; may be empty",
    )
    result.add_argument("--output", type=Path, default=OUTPUT, help=f"where the release files go (default: {OUTPUT.relative_to(ROOT)})")
    result.add_argument("--app", type=Path, default=release.APP, help="the app the disk image was made from (default: make dmg's staged app)")
    result.add_argument("--allow-unnotarized", action="store_true", help="skip the stapled-ticket check, for a dry run")
    result.add_argument(
        "--channel", choices=CHANNELS, default="stable",
        help="the channel the release goes to (default: stable). Stable also updates the Beta feed",
    )
    result.add_argument(
        "--notes", type=Path,
        help="short release notes in Markdown, embedded in the feed and shown by What's New",
    )
    result.add_argument(
        "--full-notes-url", default=FULL_RELEASE_NOTES,
        help=f"the full release notes What's New links to (default: {FULL_RELEASE_NOTES})",
    )
    return result


def main(arguments=()):
    options = parser().parse_args(list(arguments))
    repository_name = repository(options.repository)
    image = parse_image((options.image or release.latest_disk_image()).resolve())
    if not image.path.is_file():
        raise ValueError(f"No disk image at {image.path}")
    previous = previous_images(options.previous, image)
    inputs = [image.path, options.previous, options.app, *([options.notes] if options.notes else [])]
    problems = overlap_problems(options.output, inputs)
    if problems:
        raise ValueError("Choose another --output; it's emptied first:\n  " + "\n  ".join(problems))
    problems = notes_problems(options.notes)
    if problems:
        raise ValueError("; ".join(problems))
    bin_directory = tools()

    problems = app_problems(app_info(options.app), image, repository_name, options.channel)
    if problems:
        raise ValueError("The release app can't be updated from this feed:\n  " + "\n  ".join(problems))
    key = public_key(bin_directory)
    if key != str(app_info(options.app)["SUPublicEDKey"]).strip():
        raise ValueError("The keychain's EdDSA key isn't the one the app trusts (SUPublicEDKey).")
    check_disk_image(image, notarized=not options.allow_unnotarized)

    output = stage(image, previous, options.output.resolve(), options.notes)
    run(generate_arguments(
        bin_directory, output, repository_name, image,
        full_notes=options.full_notes_url, embed_notes=options.notes is not None,
    ))
    appcast = output / STABLE_FEED
    versions = appcast_versions(appcast)
    if versions != [str(image.build)]:
        raise ValueError(f"appcast.xml lists builds {versions}, expected only {image.build}")
    signature = enclosure_signature(appcast, image.path.name)
    run([
        str(bin_directory / "sign_update"), "--account", KEY_ACCOUNT,
        "--verify", str(output / image.path.name), signature,
    ])

    write_feeds(output, options.channel)
    stage_download_image(output, image)
    assets = release_assets(output, image, options.channel)
    print(f"{options.channel.capitalize()} release files for {image.tag} are in {output}.", flush=True)
    print("Nothing was published. After checking them, publish with:", flush=True)
    for command in release_commands(repository_name, image, assets, output, options.channel, options.notes):
        print(command, flush=True)
    print(f"The first time, create the Beta feed's release before the upload:\n{beta_feed_setup_command(repository_name)}", flush=True)
