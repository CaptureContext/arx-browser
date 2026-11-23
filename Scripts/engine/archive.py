"""Package the completed local framework as a release asset (DEV-1282).

The archive goes to the ignored .build/engine-archives/<source fingerprint>/, where
make engine-fetch finds it, and the tracked manifest records its size, SHA-256 and release URL.
Nothing is uploaded: the gh command that publishes it is printed.
"""

import gzip
import json
import shlex
import tarfile
import tempfile
from pathlib import Path

from ..core.paths import ROOT
from ..core.process import run
from . import artifact, cache
from .config import LOCK, SOURCE, WORK


def normalized(member):
    member.uid = member.gid = 0
    member.uname = member.gname = ""
    member.mtime = 0
    member.pax_headers = {}
    return member


def main():
    framework = artifact.require()
    cache.validate_framework(framework)
    identity = artifact.identity()
    executable = framework / "Versions" / LOCK["chromium"] / "Arx Framework"
    architecture = run(["lipo", "-archs", str(executable)], capture=True).strip().split()
    if architecture != [identity["architecture"]]:
        raise ValueError(f"Framework architectures {architecture} do not match {identity['architecture']}")
    args = SOURCE / "out/Default/args.gn"
    build = {"xcode": run(["xcodebuild", "-version"], capture=True).strip(),
             "gn_args_sha256": cache.checksum(args)}
    _, manifest = cache.paths()
    archive = cache.local_archive()
    archive.parent.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="archive-", dir=WORK) as temporary:
        packed = Path(temporary) / archive.name
        with packed.open("wb") as output:
            with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as bundle:
                    bundle.add(framework, arcname=LOCK["framework"], filter=normalized)
        if identity != artifact.identity() or not artifact.available():
            raise ValueError("Engine sources changed during packaging; rebuild before exporting.")
        data = {"schema": 1, "identity": identity, "chromium": LOCK["chromium"],
                "framework": LOCK["framework"], "archive": archive.name,
                "sha256": cache.checksum(packed), "bytes": packed.stat().st_size,
                "minimum_macos": "27.0", "build": build,
                "url": cache.release_url(identity, archive.name)}
        packed.replace(archive)
        manifest.write_text(json.dumps(data, indent=2) + "\n")
    print(f"Packaged {archive}: {data['bytes'] / 1024 / 1024:.1f} MiB")
    print(f"Commit {manifest.relative_to(ROOT)}. To publish the archive as a release asset, run:")
    print(publish_command(identity, archive))


def publish_command(identity, archive):
    """The gh command that uploads the archive to the engine archives' repository."""
    tag = cache.release_tag(identity)
    repository = cache.RELEASES_REPOSITORY
    title = f"Arx engine {LOCK['chromium']} ({identity['sources'][:16]})"
    notes = f"Prebuilt Arx engine for source fingerprint {identity['sources']}. Fetched by make engine-fetch."
    path = shlex.quote(str(archive))
    create = (f"gh release create {tag} {path} --repo {repository} "
              f"--title {shlex.quote(title)} --notes {shlex.quote(notes)}")
    upload = f"gh release upload {tag} {path} --repo {repository}"
    return f"{create}\nIf the release exists already (another architecture's asset), add this one instead:\n{upload}"
