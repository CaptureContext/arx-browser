"""Developer ID release: inside-out signing, notarization and the disk image behind make dmg and make dmg-verify."""

import argparse
import base64
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from . import build_app, signing, versioning
from .core.paths import ROOT
from .core.process import run
from .engine.bundle import HELPERS


RELEASE = ROOT / "build/release"
APP = RELEASE / "Arx.app"
DERIVED_DATA = ROOT / "build/ReleaseDerivedData"
DISTRIBUTION = ROOT / "Distribution"
ENTITLEMENTS = DISTRIBUTION / "Entitlements"
DMG_SETTINGS = DISTRIBUTION / "dmg_settings.py"
DMG_BACKGROUND = DISTRIBUTION / "dmg-background.png"  # with dmg-background@2x.png beside it
APP_ENTITLEMENTS = ROOT / "Containers/macOS/Arx.entitlements"
SIGNING_ENTITLEMENTS = RELEASE / "Arx.entitlements"
EMBEDDED_PROFILE = Path("Contents/embedded.provisionprofile")
ICLOUD_CONTAINERS = "com.apple.developer.icloud-container-identifiers"
ICLOUD_ENVIRONMENT = "com.apple.developer.icloud-container-environment"
APS_ENVIRONMENT = "com.apple.developer.aps-environment"
APPLICATION_IDENTIFIER = "com.apple.application-identifier"
TEAM_IDENTIFIER = "com.apple.developer.team-identifier"
ARCHITECTURE = "arm64"
DMG_FORMAT = "ULFO"

# Update channels (DEV-888). A release is built for one; the app's ArxUpdateChannel says which.
CHANNELS = ("stable", "beta")

# A Release Arx syncs with the container's Production environment, which has only the record types
# someone deployed. Without them CloudKit refuses every save, and SQLiteData doesn't say (DEV-1209).
ICLOUD_SCHEMA_REMINDER = (
    "Before publishing, Production must have every record type in CloudKit/arx.ckdb: "
    "make cloudkit-schema ARGS='--compare production' (DEVELOPMENT.md › iCloud schema)."
)
STEPS = ("build", "sign", "check", "notarize-app", "dmg", "sign-dmg", "notarize-dmg", "checksum")
NOTARIZE_STEPS = ("notarize-app", "notarize-dmg")

# Chromium's own signing options (chrome/installer/mac/signing/parts.py). Library validation is
# incompatible with the JIT entitlement, so the renderer and GPU helpers leave it out.
FULL_RUNTIME = "restrict,library,runtime,kill"
JIT_RUNTIME = "restrict,kill,runtime"
JIT = "com.apple.security.cs.allow-jit"
JIT_HELPERS = {
    "Arx Helper (Renderer)": "helper-renderer.plist",
    "Arx Helper (GPU)": "helper-gpu.plist",
    "Arx Helper (Aperitif Renderer)": "helper-renderer.plist",
    "Arx Helper (Aperitif GPU)": "helper-gpu.plist",
}
# Arx's own helper apps with entitlements of their own (DEV-1144): the FairPlay helper is
# sandboxed with outgoing network only.
SANDBOXED_HELPERS = {
    "ArxFairPlay": ENTITLEMENTS / "fairplay-helper.plist",
}
DEBUG_ENTITLEMENTS = (
    "com.apple.security.get-task-allow",
    "com.apple.security.cs.debugger",
)
# Xcode's Debug launcher shell and the development-only engine host must never ship.
DEVELOPMENT_SHELL = (
    "Arx.debug.dylib", "__preview.dylib",
    "Arx Engine Host.app", "ChromiumHost", "ArxNativeMessagingFixture",
)
BUNDLE_SUFFIXES = (".app", ".framework", ".xpc", ".appex")
# Sparkle's own signing guide re-signs its Downloader service with its sandbox entitlements kept.
# Arx isn't sandboxed, so Sparkle doesn't use its XPC services, but they stay signed as shipped.
SPARKLE_FRAMEWORK = "Sparkle.framework"
SPARKLE_PRESERVED_ENTITLEMENTS = ("Downloader.xpc",)
MACHO_MAGIC = {
    b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


@dataclass(frozen=True)
class Part:
    path: Path
    options: str | None
    entitlements: Path | None
    bundle: bool
    preserve_entitlements: bool = False

    @property
    def jit(self):
        return self.path.suffix == ".app" and self.path.stem in JIT_HELPERS


@dataclass(frozen=True)
class Signer:
    identity: str
    team: str
    developer_id: bool
    profile: signing.Profile


# Discovery and signing order


def is_macho(path):
    try:
        with path.open("rb") as source:
            return source.read(4) in MACHO_MAGIC
    except OSError:
        return False


def bundle_executable(bundle):
    if bundle.suffix == ".framework":
        return (bundle / "Versions/Current" / bundle.stem).resolve()
    with (bundle / "Contents/Info.plist").open("rb") as source:
        name = plistlib.load(source).get("CFBundleExecutable")
    if not name:
        raise ValueError(f"Bundle has no CFBundleExecutable: {bundle}")
    return (bundle / "Contents/MacOS" / name).resolve()


def code_parts(app, entitlements=None):
    """Every piece of code in the app, innermost first, with the app itself last."""
    app = Path(app)
    bundles, files = [], []
    for directory, directories, names in os.walk(app):
        directory = Path(directory)
        for name in directories:
            path = directory / name
            if path.suffix in BUNDLE_SUFFIXES and not path.is_symlink():
                bundles.append(path)
        for name in names:
            path = directory / name
            if not path.is_symlink() and is_macho(path):
                files.append(path)
    executables = {bundle_executable(app)} | {bundle_executable(bundle) for bundle in bundles}
    helpers = {bundle.stem for bundle in bundles if bundle.suffix == ".app"}
    missing = [name for name in HELPERS if name not in helpers]
    if missing:
        raise ValueError(f"Release app is missing Chromium helpers: {', '.join(missing)}")

    parts = []
    for bundle in bundles:
        if bundle.suffix == ".framework":
            parts.append(Part(bundle, None, None, True))
        elif SPARKLE_FRAMEWORK in bundle.parts and bundle.name in SPARKLE_PRESERVED_ENTITLEMENTS:
            parts.append(Part(bundle, FULL_RUNTIME, None, True, preserve_entitlements=True))
        elif bundle.stem in JIT_HELPERS:
            parts.append(Part(bundle, JIT_RUNTIME, ENTITLEMENTS / JIT_HELPERS[bundle.stem], True))
        elif bundle.suffix == ".app" and bundle.stem in SANDBOXED_HELPERS:
            parts.append(Part(bundle, FULL_RUNTIME, SANDBOXED_HELPERS[bundle.stem], True))
        else:
            parts.append(Part(bundle, FULL_RUNTIME, None, True))
    for path in files:
        if path.resolve() in executables:
            continue
        library = path.suffix in (".dylib", ".so")
        parts.append(Part(path, None if library else FULL_RUNTIME, None, False))

    def depth(part):
        return len(part.path.relative_to(app).parts)
    parts.sort(key=lambda part: (-depth(part), part.bundle, str(part.path)))
    parts.append(Part(app, FULL_RUNTIME, entitlements or APP_ENTITLEMENTS, True))
    return parts


def sign_arguments(part, signer, *, timestamp=True):
    """A Developer ID signature carries Apple's secure timestamp, which notarization requires.
    `timestamp=False` leaves it out, for a build that stays on this Mac: the timestamp service is
    then never asked, so signing works while it's down or out of reach."""
    arguments = ["codesign", "--force", "--sign", signer.identity]
    arguments.append("--timestamp" if signer.developer_id and timestamp else "--timestamp=none")
    if part.options:
        arguments += ["--options", part.options]
    if part.entitlements:
        arguments += ["--entitlements", str(part.entitlements)]
    elif part.preserve_entitlements:
        arguments.append("--preserve-metadata=entitlements")
    return [*arguments, str(part.path)]


# Profile and app entitlements


def identity_entitlements(team):
    """The app and team identifiers the profile grants. Restricted entitlements such as iCloud
    are only honoured when the signature names the app the profile was made for."""
    return {APPLICATION_IDENTIFIER: f"{team}.{signing.BUNDLE_ID}", TEAM_IDENTIFIER: team}


def app_entitlements(profile, team, source=None):
    """The generated app entitlements with the app identity and the iCloud and push environments
    the profile allows. Xcode fills these in for its own builds; codesign takes the file as it is,
    so they're set here."""
    with Path(source or APP_ENTITLEMENTS).open("rb") as file:
        entitlements = plistlib.load(file)
    entitlements.update(identity_entitlements(team))
    entitlements[ICLOUD_ENVIRONMENT] = profile.icloud_environment
    entitlements[APS_ENVIRONMENT] = profile.aps_environment
    return entitlements


def write_app_entitlements(profile, team, destination=None):
    destination = destination or SIGNING_ENTITLEMENTS
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as file:
        plistlib.dump(app_entitlements(profile, team), file)
    return destination


def embed_profile(app, profile):
    """Copies the profile into the app; it has to be there before the app itself is signed."""
    shutil.copyfile(profile.path, Path(app) / EMBEDDED_PROFILE)


def profile_problems(app, entitlements, profile, team):
    embedded = Path(app) / EMBEDDED_PROFILE
    if not embedded.is_file():
        return [f"{Path(app).name} has no {EMBEDDED_PROFILE}"]
    problems = []
    if embedded.read_bytes() != Path(profile.path).read_bytes():
        problems.append(f"{EMBEDDED_PROFILE} isn't the {profile.kind.replace('_', ' ')} profile for this identity")
    if not entitlements.get(ICLOUD_CONTAINERS):
        problems.append(f"{Path(app).name} is missing {ICLOUD_CONTAINERS}")
    expected = [
        *identity_entitlements(team).items(),
        (ICLOUD_ENVIRONMENT, profile.icloud_environment), (APS_ENVIRONMENT, profile.aps_environment),
    ]
    for key, value in expected:
        if entitlements.get(key) != value:
            problems.append(f"{Path(app).name} has {key} {entitlements.get(key)!r}, expected {value!r}")
    return problems


# Checks


def development_shell(app):
    found = []
    for directory, directories, names in os.walk(app):
        for name in [*directories, *names]:
            if name in DEVELOPMENT_SHELL:
                found.append(Path(directory) / name)
    return found


def entitlement_problems(part, entitlements):
    problems = [
        f"{part.path.name} has the debug-only entitlement {key}"
        for key in DEBUG_ENTITLEMENTS if entitlements.get(key)
    ]
    if part.jit and not entitlements.get(JIT):
        problems.append(f"{part.path.name} is missing {JIT}, which Chromium's V8 needs")
    if not part.jit and entitlements.get(JIT):
        problems.append(f"{part.path.name} has {JIT}, which only the renderer and GPU helpers may have")
    return problems


def signature_problems(part, details, team):
    if "not signed at all" in details:
        return [f"{part.path} is unsigned"]
    problems = []
    if f"TeamIdentifier={team}" not in details:
        problems.append(f"{part.path} is not signed by team {team}")
    if part.options and "runtime" not in _flags(details):
        problems.append(f"{part.path} is signed without the hardened runtime")
    return problems


def _flags(details):
    for line in details.splitlines():
        if line.startswith("CodeDirectory") and "flags=" in line:
            return line.split("flags=", 1)[1]
    return ""


def _codesign_details(path):
    result = subprocess.run(["codesign", "--display", "--verbose=4", str(path)], capture_output=True, text=True)
    return result.stdout + result.stderr


def _entitlements(path):
    output = subprocess.run(
        ["codesign", "--display", "--entitlements", "-", "--xml", str(path)],
        capture_output=True, check=True,
    ).stdout
    return plistlib.loads(output) if output.strip() else {}


def code_problems(app, team, *, profile=None):
    """Signature, hardened runtime and entitlement problems of every piece of code in a signed app.
    With a profile, the app must also embed it and carry the identity and environments it allows;
    without one (a disk image checked on another Mac), the embedded profile only has to be there."""
    shell = development_shell(app)
    if shell:
        raise ValueError("Release app contains development-only code: " + ", ".join(map(str, shell)))
    run(["codesign", "--verify", "--strict", "--deep", "--verbose=2", str(app)])
    problems = []
    for part in code_parts(app):
        problems += signature_problems(part, _codesign_details(part.path), team)
        if part.options:
            entitlements = _entitlements(part.path)
            problems += entitlement_problems(part, entitlements)
            if part.path == Path(app):
                if profile:
                    problems += profile_problems(app, entitlements, profile, team)
                elif not (Path(app) / EMBEDDED_PROFILE).is_file():
                    problems.append(f"{Path(app).name} has no {EMBEDDED_PROFILE}")
    return problems


def check(app, signer):
    problems = code_problems(app, signer.team, profile=signer.profile)
    if problems:
        raise ValueError("Release signature check failed:\n  " + "\n  ".join(problems))
    if signer.developer_id:
        assess(app, "execute", notarized=False)
    print("Release signatures, hardened runtime and entitlements are valid.", flush=True)
    print(ICLOUD_SCHEMA_REMINDER, flush=True)


def assess(path, kind, *, notarized=True):
    arguments = ["spctl", "--assess", "--type", kind, "-vv"]
    if kind == "open":
        arguments += ["--context", "context:primary-signature"]
    print("+ " + " ".join([*arguments, str(path)]), flush=True)
    result = subprocess.run([*arguments, str(path)], capture_output=True, text=True)
    output = (result.stdout + result.stderr).strip()
    print(output, flush=True)
    if result.returncode == 0:
        return
    # Before notarization Gatekeeper can only say the Developer ID signature itself is sound.
    if not notarized and "source=Unnotarized Developer ID" in output:
        print("Gatekeeper accepts the Developer ID signature; notarization is still pending.", flush=True)
        return
    raise ValueError(f"Gatekeeper rejected {path}")


# Notarization


def notary_configuration():
    """Validates notarization settings without touching the key, so missing values fail before a build."""
    profile = os.environ.get("ARX_NOTARY_KEYCHAIN_PROFILE", "").strip()
    if profile:
        return {"profile": profile}
    key_id = os.environ.get("APP_STORE_CONNECT_API_KEY_KEY_ID", "").strip()
    issuer = os.environ.get("APP_STORE_CONNECT_API_KEY_ISSUER_ID", "").strip()
    key_file = os.environ.get("APP_STORE_CONNECT_API_KEY_KEY_FILEPATH", "").strip()
    key_content = os.environ.get("APP_STORE_CONNECT_API_KEY_KEY_CONTENT", "").strip()
    if not key_id or not issuer or not (key_file or key_content):
        raise ValueError(
            "Notarization needs the App Store Connect API key in .env: APP_STORE_CONNECT_API_KEY_KEY_ID, "
            "APP_STORE_CONNECT_API_KEY_ISSUER_ID and APP_STORE_CONNECT_API_KEY_KEY_FILEPATH or _KEY_CONTENT. "
            "Use --skip-notarize for a local dry run."
        )
    if key_file and not (ROOT / key_file).is_file():
        raise ValueError("APP_STORE_CONNECT_API_KEY_KEY_FILEPATH does not name a readable key file.")
    return {"key_id": key_id, "issuer": issuer, "key_file": key_file, "key_content": key_content}


def notary_credentials(directory):
    configuration = notary_configuration()
    if "profile" in configuration:
        return ["--keychain-profile", configuration["profile"]]
    if configuration["key_file"]:
        key = ROOT / configuration["key_file"]
    else:
        content = configuration["key_content"]
        if os.environ.get("APP_STORE_CONNECT_API_KEY_IS_KEY_CONTENT_BASE64", "").strip().lower() == "true":
            content = base64.b64decode(content).decode()
        key = Path(directory) / "AuthKey.p8"
        descriptor = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as output:
            output.write(content.replace("\\n", "\n"))
    return ["--key", str(key), "--key-id", configuration["key_id"], "--issuer", configuration["issuer"]]


def notarytool(arguments, credentials):
    # Credentials are passed to notarytool but never echoed.
    print("+ xcrun notarytool " + " ".join(arguments) + " <App Store Connect API key>", flush=True)
    result = subprocess.run(
        ["xcrun", "notarytool", *arguments, *credentials, "--output-format", "json"],
        capture_output=True, text=True,
    )
    if result.returncode and not result.stdout.strip():
        print(result.stderr, file=sys.stderr)
        result.check_returncode()
    return json.loads(result.stdout)


def notarize(path):
    with tempfile.TemporaryDirectory(prefix="arx-notary-") as directory:
        credentials = notary_credentials(directory)
        upload = Path(path)
        if upload.suffix == ".app":
            upload = Path(directory) / "Arx.zip"
            run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(path), str(upload)])
        submission = notarytool(["submit", str(upload), "--wait"], credentials)
        status = submission.get("status")
        print(f"Notarization {submission.get('id')}: {status}", flush=True)
        if status != "Accepted":
            if submission.get("id"):
                log = notarytool(["log", submission["id"]], credentials)
                print(json.dumps(log, indent=2), file=sys.stderr)
            raise ValueError(f"Notarization of {Path(path).name} finished with status {status}")
    run(["xcrun", "stapler", "staple", str(path)])
    run(["xcrun", "stapler", "validate", str(path)])


# Disk image


def _info(app, key):
    with (Path(app) / "Contents/Info.plist").open("rb") as source:
        value = str(plistlib.load(source).get(key, "")).strip()
    if not value:
        raise ValueError(f"{app} has no {key}")
    return value


def version(app):
    return _info(app, "CFBundleShortVersionString")


def build_number(app):
    return _info(app, "CFBundleVersion")


def disk_image(app):
    return RELEASE / f"Arx-{version(app)}-{build_number(app)}-{ARCHITECTURE}.dmg"


def build_dmg(app, image):
    if not shutil.which("dmgbuild"):
        raise ValueError("dmgbuild is missing. Run mise install.")
    image.unlink(missing_ok=True)
    command = ["dmgbuild", "-s", str(DMG_SETTINGS), "-D", f"app={app}", "-D", f"background={DMG_BACKGROUND}"]
    run([*command, "Arx", str(image)], log="release-dmg.log")


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checksum_path(image):
    return image.with_name(image.name + ".sha256")


def checksum(image):
    digest = sha256(image)
    destination = checksum_path(image)
    destination.write_text(f"{digest}  {image.name}\n")
    print(f"Disk image: {image}\nSHA-256: {digest}", flush=True)
    return destination


def checksum_problems(image):
    """The .sha256 next to the disk image must exist, name it, and match its contents."""
    sidecar = checksum_path(image)
    if not sidecar.is_file():
        return [f"{sidecar.name} is missing; run make dmg ARGS='--only checksum'"]
    fields = sidecar.read_text().split()
    if len(fields) != 2 or fields[1] != image.name:
        return [f"{sidecar.name} doesn't name {image.name}"]
    if fields[0].lower() != sha256(image):
        return [f"{image.name} doesn't match {sidecar.name}"]
    return []


def image_format(image):
    output = subprocess.run(["hdiutil", "imageinfo", "-plist", str(image)], capture_output=True, check=True).stdout
    return plistlib.loads(output).get("Format")


# Pipeline


def stage(source, destination=APP):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    # ditto keeps the framework's version symlinks and nested helper apps intact.
    run(["ditto", str(source), str(destination)])


DSYMS = RELEASE / "dSYMs"


def keep_dsym(app, marketing, number):
    """Archives the release executable's dSYM (DEV-901): the shipped binary is stripped, so
    crash reports from this build can only be symbolicated with it. Xcode leaves it next to
    the built app in the derived data, which the next build overwrites."""
    dsym = app.with_name(app.name + ".dSYM")
    if not dsym.is_dir():
        print(f"warning: no dSYM next to {app}; crash reports from this build can't be symbolicated", flush=True)
        return None
    DSYMS.mkdir(parents=True, exist_ok=True)
    archive = DSYMS / f"Arx-{marketing}-{number}-{ARCHITECTURE}.dSYM.zip"
    archive.unlink(missing_ok=True)
    run(["ditto", "-c", "-k", "--keepParent", str(dsym), str(archive)])
    print(f"dSYM: {archive}", flush=True)
    return archive


def size_in_bytes(path):
    """A file's size, or a bundle's total without following symlinks (the framework's
    version links would count it twice)."""
    if path.is_symlink() or path.is_file():
        return path.lstat().st_size
    return sum(item.lstat().st_size for item in path.rglob("*") if item.is_symlink() or item.is_file())


def report_size(path, label):
    if not path.exists():
        return
    print(f"{label}: {size_in_bytes(path) / 1_000_000:.1f} MB ({path.name})", flush=True)


def channel(app):
    """The update channel the app was built for; builds from before channels are Stable."""
    with (Path(app) / "Contents/Info.plist").open("rb") as source:
        value = str(plistlib.load(source).get("ArxUpdateChannel", "")).strip().lower()
    return value or "stable"


def channel_problems(app, expected):
    found = channel(app)
    if found != expected:
        return [f"{Path(app).name} was built for the {found} channel, not {expected}; build it with --channel {expected}"]
    return []


def build(*, bump=True, destination=APP, update_channel="stable"):
    # Every release build gets the next build number; the marketing version only changes
    # through make version (DEV-837). make install and make update build with the current
    # number and leave the settings file alone (DEV-856).
    number = versioning.next_build_number() if bump else versioning.build_number()
    marketing = versioning.marketing_version()
    print(f"Building Arx {marketing} ({number}) for the {update_channel} channel", flush=True)
    app = build_app.main(
        log="build-app-release.log", require_engine=True,
        configuration="Release", derived_data=DERIVED_DATA,
        # The engine is arm64 only, so the release is too.
        build_settings=[
            f"ARCHS={ARCHITECTURE}", "ONLY_ACTIVE_ARCH=NO",
            f"MARKETING_VERSION={marketing}", f"CURRENT_PROJECT_VERSION={number}",
            f"ARX_UPDATE_CHANNEL={update_channel}",
        ],
    )
    stage(app, destination)
    keep_dsym(app, marketing, number)
    report_size(destination, "Release app")
    report_size(destination / "Contents/MacOS/Arx", "Its executable")
    if bump:
        print(f"Build number {number} is saved in {versioning.display_path()}; commit it.", flush=True)


def sign(app, signer, *, entitlements=None, timestamp=True):
    embed_profile(app, signer.profile)
    entitlements = write_app_entitlements(signer.profile, signer.team, entitlements)
    for part in code_parts(app, entitlements):
        run(sign_arguments(part, signer, timestamp=timestamp))


def selected_steps(options):
    steps = list(options.only or STEPS)
    unknown = [step for step in steps + list(options.skip) if step not in STEPS]
    if unknown:
        raise ValueError(f"Unknown release steps: {', '.join(unknown)}. Steps: {', '.join(STEPS)}")
    skipped = set(options.skip)
    if options.skip_notarize or options.development_identity:
        skipped |= set(NOTARIZE_STEPS)
    return [step for step in STEPS if step in steps and step not in skipped]


def signer(options):
    """The identity and the provisioning profile made for it: development or Developer ID."""
    if options.development_identity:
        identity = signing.identity()
        return Signer(identity, signing.team(), False, signing.profile(signing.DEVELOPMENT, identity))
    identity = signing.developer_id()
    return Signer(identity, signing.team(), True, signing.profile(signing.DEVELOPER_ID, identity))


def parser():
    result = argparse.ArgumentParser(prog="make dmg", description="Build, sign, notarize and package Arx.")
    result.add_argument("--only", action="append", metavar="STEP", help=f"run only these steps: {', '.join(STEPS)}")
    result.add_argument("--skip", action="append", default=[], metavar="STEP", help="skip a step")
    result.add_argument("--skip-notarize", action="store_true", help="skip both notarization steps (local dry run)")
    result.add_argument(
        "--development-identity", action="store_true",
        help="sign with the Apple Development identity instead of Developer ID; implies --skip-notarize",
    )
    result.add_argument("--app", type=Path, help="stage this already built app instead of building one")
    result.add_argument(
        "--channel", choices=CHANNELS, default="stable",
        help="the update channel the release is for (default: stable); a beta build starts on Beta",
    )
    return result


def main(arguments=()):
    options = parser().parse_args(list(arguments))
    steps = selected_steps(options)
    print("Release steps: " + ", ".join(steps), flush=True)
    needs_signer = {"sign", "check", "sign-dmg"} & set(steps)
    current = signer(options) if needs_signer else None
    if set(NOTARIZE_STEPS) & set(steps):
        notary_configuration()
    if options.app:
        stage(options.app.resolve())
    elif "build" in steps:
        build(update_channel=options.channel)
    if not APP.is_dir():
        raise ValueError(f"No staged release app at {APP}. Run make dmg ARGS='--only build' first.")
    # A staged app is checked when this run built or staged it; later steps take it as it is.
    problems = channel_problems(APP, options.channel) if options.app or "build" in steps else []
    if problems:
        raise ValueError("; ".join(problems))
    image = disk_image(APP)
    for step in steps:
        if step == "sign":
            sign(APP, current)
        elif step == "check":
            check(APP, current)
        elif step == "notarize-app":
            notarize(APP)
            assess(APP, "execute")
        elif step == "dmg":
            build_dmg(APP, image)
        elif step == "sign-dmg":
            run(sign_arguments(Part(image, None, None, False), current))
        elif step == "notarize-dmg":
            notarize(image)
        elif step == "checksum":
            checksum(image)
    if image.is_file():
        print(f"Release disk image: {image}", flush=True)
        report_size(image, "Disk image")


# Verification


def latest_disk_image():
    images = sorted(RELEASE.glob("Arx-*.dmg"), key=lambda path: path.stat().st_mtime)
    if not images:
        raise ValueError(f"No disk image in {RELEASE}. Run make dmg first, or pass a path.")
    return images[-1]


def verify(arguments=()):
    options = argparse.ArgumentParser(prog="make dmg-verify")
    options.add_argument("image", nargs="?", type=Path)
    options.add_argument(
        "--allow-unnotarized", action="store_true",
        help="check signatures only, for disk images from a --skip-notarize dry run",
    )
    options = options.parse_args(list(arguments))
    image = (options.image or latest_disk_image()).resolve()
    if not image.is_file():
        raise ValueError(f"No disk image at {image}")
    team = signing.team()
    notarized = not options.allow_unnotarized

    problems = checksum_problems(image)
    if problems:
        raise ValueError("; ".join(problems))
    if (found := image_format(image)) != DMG_FORMAT:
        raise ValueError(f"{image.name} is in {found} format, expected {DMG_FORMAT} (LZFSE)")
    run(["codesign", "--verify", "--strict", "--verbose=2", str(image)])
    if f"TeamIdentifier={team}" not in _codesign_details(image):
        raise ValueError(f"{image.name} is not signed by team {team}")
    if notarized:
        run(["xcrun", "stapler", "validate", str(image)])
        assess(image, "open")

    mountpoint = Path(tempfile.mkdtemp(prefix="arx-dmg-verify-"))
    run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mountpoint), str(image)])
    try:
        app = mountpoint / "Arx.app"
        if not app.is_dir():
            raise ValueError("The disk image has no Arx.app")
        # No Applications shortcut by design: Arx moves itself there on first launch.
        if (mountpoint / "Applications").is_symlink():
            raise ValueError("The disk image has an Applications shortcut, which the design dropped")
        # The same per-part checks as make dmg's check step, minus comparing the embedded profile
        # with an installed one, which another Mac doesn't have.
        problems = code_problems(app, team)
        if problems:
            raise ValueError(f"Arx.app on {image.name} failed the signature check:\n  " + "\n  ".join(problems))
        if notarized:
            run(["xcrun", "stapler", "validate", str(app)])
            assess(app, "execute")
    finally:
        run(["hdiutil", "detach", str(mountpoint)])
        mountpoint.rmdir()
    print(f"{image.name} passed verification" + ("" if notarized else " (signatures only, not notarized)"), flush=True)
