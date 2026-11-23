"""Find or download the manifest's engine archive, verify it, then restore it (DEV-1282).

The lookup order is in cache.py. A download goes to .build/engine-archives/, needs no
credentials, follows the release asset's redirects, and is checked against the manifest's size
and SHA-256 before anything is unpacked. Nothing in the archive is executed.
"""

import hashlib
import os
import tempfile
import urllib.error
import urllib.parse
import urllib.request

from . import cache

SCHEMES = {"https", "file"}
CHUNK = 1 << 20


class MissingAsset(ValueError):
    """The manifest's URL has no archive: the release asset isn't published yet."""


def missing(url, destination):
    return MissingAsset(
        f"The engine archive isn't published at {url}. Build it here with make engine-build and "
        f"make engine-cache, or get {destination.name} for this engine from whoever built it, "
        f"put it at {destination} and run make engine-fetch again; it is checked against "
        "the manifest first. Artifacts/Engine/README.md says how a release asset is published."
    )


def download(data):
    """Download the manifest's URL into the local archive folder and verify it there."""
    url = data.get("url")
    if not url:
        raise ValueError("The engine manifest has no download URL. Run make engine-cache to record one.")
    if urllib.parse.urlsplit(url).scheme not in SCHEMES:
        raise ValueError(f"Refusing to download the engine from {url}: only https and file URLs are allowed.")
    destination = cache.local_archive()
    destination.parent.mkdir(parents=True, exist_ok=True)
    # No credentials: release assets of a public repository are open to anyone. urllib follows
    # the redirect to GitHub's object storage.
    request = urllib.request.Request(url, headers={"User-Agent": "arx-engine-fetch"})
    try:
        response = urllib.request.urlopen(request, timeout=60)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise missing(url, destination) from error
        raise ValueError(f"Downloading the engine from {url} failed: HTTP {error.code} {error.reason}") from error
    except urllib.error.URLError as error:
        if isinstance(error.reason, FileNotFoundError):
            raise missing(url, destination) from error
        raise ValueError(f"Downloading the engine from {url} failed: {error.reason}") from error
    print(f"Downloading the engine from {url}")
    expected = data["bytes"]
    with response:
        length = response.headers.get("Content-Length")
        if length is not None and length.isdigit() and int(length) != expected:
            raise ValueError(f"The engine at {url} has {length} bytes, the manifest expects {expected} (size mismatch)")
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".download-", delete=False) as output:
            partial = output.name
        try:
            digest = hashlib.sha256()
            size = 0
            with open(partial, "wb") as output:
                while chunk := response.read(CHUNK):
                    size += len(chunk)
                    if size > expected:
                        break
                    digest.update(chunk)
                    output.write(chunk)
            if size != expected:
                more = "more than" if size > expected else str(size)
                raise ValueError(f"The engine at {url} has {more} bytes, the manifest expects {expected} (size mismatch)")
            if digest.hexdigest() != data["sha256"]:
                raise ValueError(f"The engine at {url} doesn't match the manifest's SHA-256 (checksum mismatch)")
            os.replace(partial, destination)
        finally:
            if os.path.exists(partial):
                os.remove(partial)
    return destination


def main():
    # Reject a stale manifest or unsupported architecture before any network operation.
    data = cache.metadata()
    if cache.restored_available():
        print(f"Engine already restored: {cache.restored_directory()}")
        return
    archive, problems = cache.locate(data)
    for reason in problems:
        print(f"Skipped: {reason}")
    if archive is None:
        archive = download(data)
    print(f"Verified engine archive: {archive}")
    cache.unpack(archive, data)
