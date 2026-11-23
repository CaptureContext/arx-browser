"""Development and Developer ID signing identities; certificates remain in the user's keychain."""

import datetime
import hashlib
import os
import plistlib
import re
import shutil
import ssl
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .core.process import run


BUNDLE_ID = "dev.capturecontext.arx"
# Arx Dev (DEV-1013): Debug builds have their own bundle ID, so their data and Keychain items
# never meet an installed Arx's. It shares the iCloud container, in its Development environment.
DEV_BUNDLE_ID = BUNDLE_ID + ".dev"
DEVELOPMENT = "development"
DEVELOPER_ID = "developer_id"
# Match names its macOS profiles "match <Development|Direct> <bundle ID> macos".
PROFILE_KINDS = {DEVELOPMENT: "Development", DEVELOPER_ID: "Direct"}
PROFILE_NAMES = {kind: f"match {name} {BUNDLE_ID} macos" for kind, name in PROFILE_KINDS.items()}
PROFILE_OVERRIDES = {DEVELOPMENT: "ARX_DEVELOPMENT_PROFILE", DEVELOPER_ID: "ARX_DEVELOPER_ID_PROFILE"}
PROFILE_DIRECTORIES = (
    Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    Path.home() / "Library/MobileDevice/Provisioning Profiles",
)
ICLOUD_CONTAINER = "iCloud.dev.capturecontext.arx"
# iCloud and push environments the app's entitlements ask for under each kind of profile.
ICLOUD_ENVIRONMENTS = {DEVELOPMENT: "Development", DEVELOPER_ID: "Production"}
APS_ENVIRONMENTS = {DEVELOPMENT: "development", DEVELOPER_ID: "production"}
NO_DEV_PROFILE = (
    "No Arx Dev development profile \"{name}\" yet: Arx Dev is signed without iCloud and push. "
    "See DEVELOPMENT.md › Arx Dev for the portal steps."
)
MISSING_PROFILE = (
    "No usable {kind} provisioning profile \"{name}\" for team {team} that includes this signing certificate. "
    "Run {setup} to restore it from Match. If Match has none, or the certificate or capabilities changed, "
    "the profiles have to be regenerated with the writing lane: mise exec -- fastlane mac signing_profiles force:true"
)


MISSING_DEVELOPER_ID = (
    "No Developer ID Application certificate for team {team} in the keychain. "
    "It has to be created once in the Apple Developer portal (Certificates, Developer ID Application) "
    "and stored in the match repository; then run make release-signing-setup."
)


def team():
    value = os.environ.get("DEVELOPMENT_TEAM", "").strip()
    if not re.fullmatch(r"[A-Z0-9]{10}", value):
        raise ValueError("Set DEVELOPMENT_TEAM in .env before signing.")
    return value


def identity():
    team_id = team()

    listing = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        capture_output=True, text=True, check=True,
    ).stdout
    valid = set(re.findall(r'\b([A-F0-9]{40}) "Apple Development:', listing))
    certificates = subprocess.run(
        ["security", "find-certificate", "-a", "-p"],
        capture_output=True, text=True, check=True,
    ).stdout
    candidates = []
    for certificate in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certificates, re.S):
        details = subprocess.run(
            ["openssl", "x509", "-noout", "-fingerprint", "-sha1", "-subject", "-nameopt", "sep_multiline", "-enddate"],
            input=certificate, capture_output=True, text=True, check=True,
        ).stdout
        fingerprint = re.search(r"Fingerprint=([A-F0-9:]+)", details).group(1).replace(":", "")
        belongs_to_team = re.search(r"^\s*OU\s*=\s*" + re.escape(team_id) + r"\s*$", details, re.M)
        if fingerprint in valid and belongs_to_team:
            expiration = re.search(r"^notAfter=(.+)$", details, re.M).group(1)
            candidates.append((ssl.cert_time_to_seconds(expiration), fingerprint))

    requested = os.environ.get("ARX_SIGNING_IDENTITY", "").strip().upper()
    if requested:
        candidates = [candidate for candidate in candidates if candidate[1] == requested]
    if not candidates:
        raise ValueError("No valid Apple Development identity for this team. Run make signing-setup, or install its certificate and private key in Keychain.")
    return max(candidates)[1]


def developer_id():
    """The team's Developer ID Application identity, chosen by fingerprint so no name is printed."""
    team_id = team()
    listing = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        capture_output=True, text=True, check=True,
    ).stdout
    pattern = r'\b([A-F0-9]{40}) "Developer ID Application: [^"]*\(' + re.escape(team_id) + r'\)"'
    candidates = sorted(set(re.findall(pattern, listing)))
    requested = os.environ.get("ARX_RELEASE_IDENTITY", "").strip().upper()
    if requested:
        candidates = [candidate for candidate in candidates if candidate == requested]
    if not candidates:
        raise ValueError(MISSING_DEVELOPER_ID.format(team=team_id))
    return candidates[0]


def bundle_id(configuration):
    """The app's bundle ID in this build configuration: Arx Dev's in Debug."""
    return DEV_BUNDLE_ID if configuration == "Debug" else BUNDLE_ID


def profile_name(kind, bundle=BUNDLE_ID):
    return f"match {PROFILE_KINDS[kind]} {bundle} macos"


@dataclass(frozen=True)
class Profile:
    path: Path
    uuid: str
    kind: str

    @property
    def icloud_environment(self):
        return ICLOUD_ENVIRONMENTS[self.kind]

    @property
    def aps_environment(self):
        return APS_ENVIRONMENTS[self.kind]


def decode_profile(path):
    """The profile's property list, from its CMS envelope. Never printed: it lists devices."""
    output = subprocess.run(
        ["security", "cms", "-D", "-i", str(path)], capture_output=True, check=False,
    ).stdout
    try:
        return plistlib.loads(output) if output.strip() else None
    except Exception:
        return None


def profile_problems(contents, kind, team_id, fingerprint, *, bundle=BUNDLE_ID, now=None):
    """Why a decoded profile can't sign this app (`bundle`) with this identity; empty when it can."""
    if contents is None:
        return ["unreadable"]
    problems = []
    if contents.get("Name") != profile_name(kind, bundle):
        problems.append("another profile name")
    if team_id not in contents.get("TeamIdentifier", []):
        problems.append("another team")
    entitlements = contents.get("Entitlements", {})
    if entitlements.get("com.apple.application-identifier") != f"{team_id}.{bundle}":
        problems.append("another app identifier")
    if kind == DEVELOPER_ID and not contents.get("ProvisionsAllDevices"):
        problems.append("not a Developer ID profile")
    if kind == DEVELOPMENT and "ProvisionedDevices" not in contents:
        problems.append("not a development profile")
    problems += grant_problems(entitlements, kind)
    expiration = contents.get("ExpirationDate")
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if expiration and expiration.replace(tzinfo=expiration.tzinfo or datetime.timezone.utc) <= now:
        problems.append("expired")
    certificates = {hashlib.sha1(certificate).hexdigest().upper() for certificate in contents.get("DeveloperCertificates", [])}
    if fingerprint not in certificates:
        problems.append("doesn't include the signing certificate")
    return problems


def _granted(value, wanted):
    """A profile grants a value as a string, a list of strings, or the wildcard "*"."""
    values = value if isinstance(value, list) else [value]
    return "*" in values or wanted in values


def grant_problems(entitlements, kind):
    """What the app's iCloud and push entitlements ask for that the profile doesn't grant, as with
    a profile made before those capabilities were turned on."""
    wanted = [
        ("com.apple.developer.icloud-container-identifiers", ICLOUD_CONTAINER, "the iCloud container"),
        ("com.apple.developer.icloud-services", "CloudKit", "CloudKit"),
        ("com.apple.developer.icloud-container-environment", ICLOUD_ENVIRONMENTS[kind], f"the {ICLOUD_ENVIRONMENTS[kind]} iCloud environment"),
        ("com.apple.developer.aps-environment", APS_ENVIRONMENTS[kind], f"{APS_ENVIRONMENTS[kind]} push"),
    ]
    return [
        f"doesn't grant {name}" for key, value, name in wanted
        if key not in entitlements or not _granted(entitlements[key], value)
    ]


def profile(kind, fingerprint, bundle=BUNDLE_ID):
    """The installed Match profile of this kind for this bundle ID that covers the signing
    identity, newest first."""
    team_id = team()
    override = os.environ.get(PROFILE_OVERRIDES[kind], "").strip()
    if override:
        paths = [Path(override).expanduser()]
    else:
        paths = [
            path for directory in PROFILE_DIRECTORIES if directory.is_dir()
            for path in directory.iterdir() if path.suffix == ".provisionprofile"
        ]
    candidates = []
    for path in paths:
        contents = decode_profile(path)
        if not profile_problems(contents, kind, team_id, fingerprint, bundle=bundle):
            candidates.append((contents.get("CreationDate"), contents["UUID"], path))
    if not candidates:
        setup = "make signing-setup" if kind == DEVELOPMENT else "make release-signing-setup"
        raise ValueError(MISSING_PROFILE.format(kind=kind.replace("_", " "), name=profile_name(kind, bundle), team=team_id, setup=setup))
    _, uuid, path = max(candidates, key=lambda candidate: candidate[0] or datetime.datetime.min)
    return Profile(path, uuid, kind)


def install_for_xcode(selected):
    """Xcode finds profiles by UUID only in its own directory, so a profile elsewhere (an override
    file, or one only in the legacy MobileDevice directory) is copied there first. Returns the
    installed path."""
    if selected.path.parent == PROFILE_DIRECTORIES[0]:
        return selected.path
    destination = PROFILE_DIRECTORIES[0] / f"{selected.uuid}.provisionprofile"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.is_file() or destination.read_bytes() != selected.path.read_bytes():
        shutil.copyfile(selected.path, destination)
    return destination


def dev_profile(fingerprint):
    """Arx Dev's development profile, or None until it exists in the portal and Match."""
    try:
        return profile(DEVELOPMENT, fingerprint, DEV_BUNDLE_ID)
    except ValueError:
        return None


def check():
    fingerprint = identity()
    print(f"Development signing identity: {fingerprint}")
    print(f"Development provisioning profile: {profile(DEVELOPMENT, fingerprint).uuid}")
    selected = dev_profile(fingerprint)
    if selected:
        print(f"Arx Dev development provisioning profile: {selected.uuid}")
    else:
        print(NO_DEV_PROFILE.format(name=profile_name(DEVELOPMENT, DEV_BUNDLE_ID)))


def release_check():
    fingerprint = developer_id()
    print(f"Developer ID signing identity: {fingerprint}")
    print(f"Developer ID provisioning profile: {profile(DEVELOPER_ID, fingerprint).uuid}")


def setup():
    # Only restore shared certificates. Never create/revoke certificates or profiles.
    run(["fastlane", "mac", "development_signing"])
    check()


def release_setup():
    # Read-only like setup(): restores an existing Developer ID certificate and never creates one.
    run(["fastlane", "mac", "developer_id_signing"])
    release_check()


def release_cleanup():
    # Removes only the throwaway keychain named by ARX_RELEASE_KEYCHAIN; does nothing without it.
    if os.environ.get("ARX_RELEASE_KEYCHAIN", "").strip():
        run(["fastlane", "mac", "release_keychain_cleanup"])


def sign(app):
    run(["codesign", "--force", "--deep", "--sign", identity(), str(app)])
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
