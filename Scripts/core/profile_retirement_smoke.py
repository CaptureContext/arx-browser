"""Strict owned-root acceptance oracle. No boot UUID injection or user storage."""

import json
import os
import stat
import subprocess
from uuid import UUID

from .routing_smoke import exclusive_json, is_same_application

PHASES = ("queue", "quarantine", "sameBoot")
# "Clear Arx data first" before an import (DEV-833): one phase, run by `make migration-clear-smoke`.
CLEAR_PHASES = ("clearForImport",)
SENTINEL = "Arx profile retirement disposable fixture v1\n"
LEGACY = "00000000-0000-4000-8000-000000000001"
ORDINARY = "00000000-0000-4000-8000-000000000002"
SURVIVOR = "00000000-0000-4000-8000-000000000003"
TARGETS = (LEGACY, ORDINARY)
CLEAR_TARGETS = (LEGACY, ORDINARY, SURVIVOR)
ORIGINAL_NAMES = ("Default", "Arx-" + ORDINARY)
HTML = b'''<!doctype html><script>
const seed = new URLSearchParams(location.search).get('seed');
if (seed) { localStorage.setItem('identity', seed); document.cookie = 'identity=' + seed + '; path=/; Max-Age=3600; SameSite=Lax'; }
const cookie = document.cookie.split('; ').find(x => x.startsWith('identity='));
document.title = (localStorage.getItem('identity') || 'empty') + '|' + (cookie ? cookie.split('=')[1] : 'empty');
</script>'''


def prepare(root, application, port):
    if not root.name.startswith("retirement-smoke-") or not 1 <= port <= 65535:
        raise ValueError("Invalid retirement fixture")
    root.chmod(0o700)
    (root / "profile").mkdir(mode=0o700)
    descriptor = os.open(root / ".arx-retirement-smoke", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as output:
        output.write(SENTINEL)
    exclusive_json(root / "fixture.json", {
        "version": 1, "application": application.resolve().as_uri(),
        "baseURL": f"http://127.0.0.1:{port}/identity",
    })


def kernel_boot_session():
    result = subprocess.run(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
                            check=True, capture_output=True, text=True)
    value = result.stdout.strip().lower()
    if str(UUID(value)) != value or UUID(value).int == 0:
        raise ValueError("Authoritative kernel boot-session identity unavailable")
    return value  # Compare only; never print or persist the boot identifier.


def read_json(path, limit=128 * 1024, *, private=True):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
                or info.st_mode & (0o077 if private else 0o022) or not 0 < info.st_size <= limit):
            raise ValueError("Invalid private retirement fixture record")
        data = source.read(limit + 1)
        if len(data) > limit:
            raise ValueError("Oversized retirement fixture record")
        return json.loads(data)


def directory_identity(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError("Unowned or replaced retirement fixture directory")
    return [info.st_dev, info.st_ino]


def normalized_uuid(value):
    if not isinstance(value, str):
        raise ValueError("Missing retirement identity")
    return str(UUID(value))


def verify_installation(profile):
    """The installation identity bound to this exact owned root; returns its installation ID."""
    identity = read_json(profile / ".arx-installation-v1")
    actual_root = directory_identity(profile)
    # Version 2 stores the volume UUID instead of st_dev, which changes across reboots (ec51ffbe).
    if (identity.get("version") != 2 or normalized_uuid(identity.get("legacyProfileID")) != LEGACY
            or identity.get("rootPath") != str(profile)
            or UUID(normalized_uuid(identity.get("volume"))).int == 0
            or identity.get("inode") != actual_root[1]):
        raise ValueError("Installation identity is not bound to this exact owned root")
    return normalized_uuid(identity.get("installationID"))


def verify_clear_phase(root, application, pid, process):
    """The migration assistant cleared all three fixture profiles through retirement and imported."""
    phase = CLEAR_PHASES[0]
    if type(pid) is not int or pid <= 1:
        raise ValueError("Invalid clear fixture process")
    marker = f"ARX_RETIREMENT_{phase.upper()}_SMOKE_SUCCESS"
    if (process.returncode or marker not in process.stdout.splitlines()
            or "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN" not in process.stderr.splitlines()):
        raise ValueError("Clear fixture lacked native mock-Keychain/phase evidence")
    result = read_json(root / f"result-{phase}.json")
    completion = read_json(root / f"completion-{phase}.json")
    if (result.get("version") != 1 or result.get("status") != "passed"
            or result.get("phase") != phase or result.get("pid") != pid
            or result.get("profile") != str(root / "profile")
            or result.get("progress") != "awaitingStartup" or result.get("importCompleted") is not True
            or not is_same_application(result.get("application"), application)
            or completion.get("status") != "cleanExit" or completion.get("phase") != phase
            or completion.get("pid") != pid
            or not is_same_application(completion.get("application"), application)):
        raise ValueError("Clear fixture receipt or clean-exit identity failed")
    requests = [normalized_uuid(value) for value in result.get("requests", [])]
    if len(requests) != len(CLEAR_TARGETS) or len(set(requests)) != len(requests):
        raise ValueError("Clear fixture retirement requests are missing or repeated")
    profile = root / "profile"
    installation = verify_installation(profile)
    intents = read_json(profile / ".arx-profile-retirement-intents-v1")
    values = intents.get("values", [])
    if (intents.get("version") != 1 or normalized_uuid(intents.get("installationID")) != installation
            or sorted(normalized_uuid(value.get("profileID")) for value in values) != sorted(CLEAR_TARGETS)
            or sorted(normalized_uuid(value.get("requestID")) for value in values) != sorted(requests)
            or any(value.get("acknowledged") is not True for value in values)):
        raise ValueError("Each cleared profile needs its own acknowledged durable consent")
    workspace = read_json(profile / "arx-workspace.json", private=False)["organization"]
    profiles = [normalized_uuid(value["id"]) for value in workspace["profiles"]]
    if (not profiles or set(profiles) & set(CLEAR_TARGETS)
            or profiles != [normalized_uuid(value) for value in result.get("profiles", [])]
            or normalized_uuid(workspace["legacyProfileID"]) != LEGACY
            or not set(CLEAR_TARGETS) <= set(map(normalized_uuid, workspace["retiredProfileIDs"]))):
        raise ValueError("Cleared profiles were restored, or the saved workspace differs from the app's")
    journal = (profile / ".arx-profile-erasure-v1").lstat()
    if not stat.S_ISREG(journal.st_mode) or journal.st_uid != os.getuid() or journal.st_nlink != 1 or journal.st_mode & 0o077:
        raise ValueError("Native durable retirement journal missing")
    # Retirement only queues erasure; nothing moves until the next start.
    if any(os.path.lexists(profile / (".arx-erasing-" + request)) for request in requests):
        raise ValueError("Clearing erased or moved storage before restart")
    return {"requests": requests, "installation": installation, "profiles": profiles}


def verify_phase(root, application, phase, pid, process, *, prior=None, original=None, quarantined=None):
    if phase not in PHASES or type(pid) is not int or pid <= 1:
        raise ValueError("Invalid retirement fixture phase/process")
    marker = f"ARX_RETIREMENT_{phase.upper()}_SMOKE_SUCCESS"
    if (process.returncode or marker not in process.stdout.splitlines()
            or "ARX_ENGINE_SMOKE_MOCK_KEYCHAIN" not in process.stderr.splitlines()):
        raise ValueError("Retirement fixture lacked native mock-Keychain/phase evidence")
    result = read_json(root / f"result-{phase}.json")
    completion = read_json(root / f"completion-{phase}.json")
    expected_progress = "awaitingStartup" if phase == "queue" else "restartRequired"
    if (result.get("version") != 1 or result.get("status") != "passed"
            or result.get("phase") != phase or result.get("pid") != pid
            or result.get("profile") != str(root / "profile")
            or result.get("progress") != expected_progress
            or not is_same_application(result.get("application"), application)
            or completion.get("status") != "cleanExit" or completion.get("phase") != phase
            or completion.get("pid") != pid
            or not is_same_application(completion.get("application"), application)
            or any(result.get(key) is not True for key in (
                "survivorStorage", "retiredAdmissionDenied", "settingsDoesNotClaimErased"))):
        raise ValueError("Retirement fixture receipt or clean-exit identity failed")
    requests = [normalized_uuid(value) for value in result.get("requests", [])]
    if len(requests) != 2 or len(set(requests)) != 2 or (prior and requests != prior["requests"]):
        raise ValueError("Retirement request identities changed across startup")
    profile = root / "profile"
    installation = verify_installation(profile)
    if prior and installation != prior["installation"]:
        raise ValueError("Installation identity changed across restart")
    intents = read_json(profile / ".arx-profile-retirement-intents-v1")
    values = intents.get("values", [])
    if (intents.get("version") != 1 or normalized_uuid(intents.get("installationID")) != installation
            or len(values) != 2 or [normalized_uuid(value.get("profileID")) for value in values] != list(TARGETS)
            or [normalized_uuid(value.get("requestID")) for value in values] != requests
            or any(value.get("acknowledged") is not True or type(value.get("expectedRevision")) is not int
                   or value["expectedRevision"] <= 0 or value.get("attemptRevision", 0) < value["expectedRevision"]
                   for value in values)):
        raise ValueError("Private durable consent/acknowledgment is missing")
    revisions = [value["expectedRevision"] for value in values]
    if prior and revisions != prior["revisions"]:
        raise ValueError("Original consent revision changed across startup")
    workspace = read_json(profile / "arx-workspace.json", private=False)["organization"]
    if ([normalized_uuid(value["id"]) for value in workspace["profiles"]] != [SURVIVOR]
            or normalized_uuid(workspace["legacyProfileID"]) != LEGACY
            or set(map(normalized_uuid, workspace["retiredProfileIDs"])) != set(TARGETS)):
        raise ValueError("Retired metadata was restored or Default ownership was reassigned")
    # The native journal is binary and is interpreted by the real public snapshot,
    # not by a second test-only parser. Independently verify it exists privately.
    journal = (profile / ".arx-profile-erasure-v1").lstat()
    if not stat.S_ISREG(journal.st_mode) or journal.st_uid != os.getuid() or journal.st_nlink != 1 or journal.st_mode & 0o077:
        raise ValueError("Native durable retirement journal missing")
    if phase == "queue":
        original = [directory_identity(profile / name) for name in ORIGINAL_NAMES]
        if any(os.path.lexists(profile / (".arx-erasing-" + request)) for request in requests):
            raise ValueError("Queue erased or moved storage before restart")
    else:
        if not original:
            raise ValueError("Missing pre-quarantine inode proof")
        for name in ORIGINAL_NAMES:
            if os.path.lexists(profile / name):
                raise ValueError("Startup recreated a retired original path")
        current = [directory_identity(profile / (".arx-erasing-" + request)) for request in requests]
        if current != original or (quarantined is not None and current != quarantined):
            raise ValueError("Quarantine inode changed or same-boot storage was removed")
        quarantined = current
    return {"requests": requests, "revisions": revisions, "installation": installation,
            "original": original, "quarantined": quarantined}
