"""The security-component smoke's checks on a profile (DEV-874); no network or app needed."""

import json
from pathlib import Path
import struct
import tempfile
import unittest

from Scripts import component_updates_smoke as smoke


def crl_set(header):
    body = json.dumps(header).encode()
    return struct.pack("<H", len(body)) + body + b"\x00" * 36


def install(profile, directory, version, filename, content=b"{}"):
    path = profile / directory / version
    path.mkdir(parents=True, exist_ok=True)
    (path / "manifest.json").write_text(json.dumps({"version": version}))
    (path / filename).write_bytes(content)


def healthy(profile, not_after=2_000_000_000):
    install(profile, "CertificateRevocation", "10012", "crl-set",
            crl_set({"Version": 0, "ContentType": "CRLSet", "Sequence": 10012, "NotAfter": not_after}))
    install(profile, "PKIMetadata", "3051", "manifest.json")
    install(profile, "SSLErrorAssistant", "7", "manifest.json")
    (profile / "Local State").write_text(json.dumps({"updateclientdata": {"apps": {
        component: {"pv": "1"} for component in smoke.COMPONENTS}}}))


class ComponentUpdatesSmokeTests(unittest.TestCase):
    def test_a_profile_with_all_three_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            healthy(profile)
            self.assertEqual(smoke.problems(profile, build_time=1_900_000_000), [])

    def test_a_fresh_profile_names_each_missing_component(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            # Helium's consent-gated updater left these empty (DEV-874).
            (profile / "CertificateRevocation").mkdir()
            (profile / "WidevineCdm").mkdir()
            self.assertEqual(smoke.problems(profile, build_time=0), [
                "CertificateRevocation was not downloaded",
                "PKIMetadata was not downloaded",
                "SSLErrorAssistant was not downloaded",
            ])

    def test_a_crl_set_older_than_the_build_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            healthy(profile, not_after=1_000)
            self.assertEqual(smoke.problems(profile, build_time=2_000),
                             ["the CRLSet (sequence 10012) expired before the engine was built"])

    def test_other_components_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory)
            healthy(profile)
            install(profile, "WidevineCdm", "4.10.2891.0", "manifest.json")
            state = json.loads((profile / "Local State").read_text())
            state["updateclientdata"]["apps"]["oimompecagnajdejgnnjijobebaeigek"] = {}
            (profile / "Local State").write_text(json.dumps(state))
            self.assertEqual(smoke.problems(profile, build_time=0), [
                "other components were installed: WidevineCdm",
                "update checks named other components: oimompecagnajdejgnnjijobebaeigek",
            ])

    def test_the_newest_complete_version_wins(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for version in ["9.9", "9.10", "10"]:
                (root / version).mkdir()
                (root / version / "manifest.json").write_text("{}")
            (root / "11").mkdir()  # Still unpacking: no manifest yet.
            (root / "latest").mkdir()
            self.assertEqual(smoke.newest_version(root).name, "10")

    def test_a_file_that_isnt_a_crl_set_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "crl-set"
            path.write_bytes(crl_set({"ContentType": "Other", "Sequence": 1}))
            with self.assertRaisesRegex(ValueError, "isn't a CRLSet"):
                smoke.crl_set_header(path)
            path.write_bytes(b"\xff\xff{}")
            with self.assertRaisesRegex(ValueError, "ends inside its header"):
                smoke.crl_set_header(path)

    def test_ids_match_the_engine_allowlist(self):
        header = (Path(__file__).parents[2] / "Packages/engine/Native/component_updates.h").read_text()
        for component in smoke.COMPONENTS:
            self.assertIn(f'"{component}"', header)


if __name__ == "__main__":
    unittest.main()
