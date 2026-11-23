"""make cloudkit-schema: write CloudKit/arx.ckdb from the synced tables, or compare it with a container environment (DEV-1209).

Without arguments it runs WorkspaceSync's `CloudKitSchemaTests` in record mode, which adds every synced
table and column of the current migrations to the file and keeps what it already had: CloudKit never
removes a deployed field. `--compare development|production` exports that environment's schema with
`cktool` and lists the record types and fields the file has and the environment lacks; it needs a
CloudKit management token saved with `xcrun cktool save-token` and DEVELOPMENT_TEAM in .env.
"""

import argparse
import os
import re
import tempfile
from pathlib import Path

from .core.paths import ROOT
from .core.process import run
from .test import environment
from .tools.swift import command as swift


SCHEMA = ROOT / "CloudKit/arx.ckdb"
CONTAINER = "iCloud.dev.capturecontext.arx"
RECORD_TYPE = re.compile(r"^\s*RECORD TYPE (\S+) \($")


def parse(text):
    """Record type name to {field: type} from a `.ckdb` schema, as `cktool export-schema` writes it."""
    types = {}
    current = None
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped == "DEFINE SCHEMA":
            continue
        match = RECORD_TYPE.match(line)
        if match:
            current = types.setdefault(match.group(1), {})
        elif stripped == ");":
            current = None
        elif current is not None and not stripped.startswith("GRANT "):
            name, _, kind = stripped.rstrip(",").partition(" ")
            current[name] = kind.strip()
    return types


def missing(expected, actual):
    """What `expected` has and `actual` lacks or types differently, one line each."""
    problems = []
    for name, fields in sorted(expected.items()):
        if name not in actual:
            problems.append(f"record type {name} is missing")
            continue
        for field, kind in sorted(fields.items()):
            found = actual[name].get(field)
            if found is None:
                problems.append(f"{name}.{field} is missing")
            elif found != kind:
                problems.append(f"{name}.{field} is {found}, not {kind}")
    return problems


def record():
    test_environment = environment()
    test_environment["ARX_RECORD_CLOUDKIT_SCHEMA"] = "1"
    run(
        swift(ROOT / "Packages/services", "test", "--filter", "CloudKitSchemaTests/everySyncedTableAndColumnIsInTheSchemaFile"),
        env=test_environment,
    )
    print(f"Wrote {SCHEMA.relative_to(ROOT)}. Import it into Development with:", flush=True)
    print(f"  xcrun cktool import-schema --team-id $DEVELOPMENT_TEAM --container-id {CONTAINER} --environment development --file {SCHEMA.relative_to(ROOT)}", flush=True)


def compare(environment_name):
    team = os.environ.get("DEVELOPMENT_TEAM", "").strip()
    if not team:
        raise ValueError("Set DEVELOPMENT_TEAM in .env to read the container's schema.")
    with tempfile.TemporaryDirectory() as directory:
        exported = Path(directory) / f"{environment_name}.ckdb"
        run([
            "xcrun", "cktool", "export-schema",
            "--team-id", team, "--container-id", CONTAINER,
            "--environment", environment_name, "--output-file", str(exported),
        ])
        problems = missing(parse(SCHEMA.read_text()), parse(exported.read_text()))
    if problems:
        raise ValueError(
            f"{environment_name.capitalize()} lacks what CloudKit/arx.ckdb has; a Release Arx syncing against it "
            "has its saves refused (DEVELOPMENT.md › iCloud schema):\n  " + "\n  ".join(problems)
        )
    print(f"{environment_name.capitalize()} has every record type and field in CloudKit/arx.ckdb.", flush=True)


def main(arguments=()):
    options = argparse.ArgumentParser(prog="make cloudkit-schema")
    options.add_argument("--compare", choices=("development", "production"), help="compare the file with that environment's schema")
    parsed = options.parse_args(list(arguments))
    if parsed.compare:
        compare(parsed.compare)
    else:
        record()
