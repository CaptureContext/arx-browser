"""Run allocator registration only in disposable native subprocesses."""

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from Scripts.core.paths import ROOT


class AllocatorBootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="arx-allocator-test-")
        root = Path(cls.directory.name)
        cls.binary = root / "bootstrap"
        source = ROOT / "Packages/engine/Sources/ChromiumBootstrap"
        cls.source = source
        subprocess.run([
            "xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
            "-I", str(source / "include"), "-c", str(source / "ChromiumBootstrap.c"),
            "-o", str(root / "probe.o"),
        ], check=True, capture_output=True, text=True, timeout=60)
        subprocess.run([
            "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
            "-Wno-unused-parameter", "-mmacosx-version-min=27.0",
            "-I", str(source / "include"), "-I", str(source / "Upstream"),
            "-I", str(source / "Config"), str(root / "probe.o"),
            str(source / "ChromiumAllocatorBootstrap.cc"),
            str(source / "Upstream/base/allocator/early_zone_registration_apple.cc"),
            str(ROOT / "Scripts/tests/fixtures/allocator_bootstrap.cc"), "-o", str(cls.binary),
        ], check=True, capture_output=True, text=True, timeout=60)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_fixture(self, mode, smoke=False):
        environment = os.environ.copy()
        environment.pop("ARX_ENGINE_SMOKE_TITLE", None)
        if smoke:
            environment["ARX_ENGINE_SMOKE_TITLE"] = "disposable allocator fixture"
        result = subprocess.run(
            [str(self.binary), mode], env=environment,
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_exact_upstream_pin_and_content_are_retained(self):
        upstream = self.source / "Upstream"
        manifest = json.loads((upstream / "source-manifest.json").read_text())
        lock = json.loads((ROOT / "Packages/engine/engine.lock.json").read_text())
        self.assertEqual(manifest["chromium"], lock["chromium"])
        self.assertEqual(manifest["helium_macos_revision"], lock["helium_macos"]["revision"])
        self.assertEqual(manifest["helium_revision"], lock["helium"]["revision"])
        for item in manifest["files"]:
            self.assertEqual(hashlib.sha256((upstream / item["path"]).read_bytes()).hexdigest(), item["sha256"])
        self.assertIn("Redistribution and use", (upstream / "LICENSE").read_text())

    def test_registration_preserves_allocations_and_is_idempotent(self):
        ordinary = self.run_fixture("prepare")
        self.assertEqual(ordinary.stderr, "")
        smoke = self.run_fixture("prepare", smoke=True)
        self.assertEqual(smoke.stderr, "ARX_BOOTSTRAP_REGISTERED\n")
        self.assertNotIn("FRAMEWORK_VERIFIED", smoke.stderr)

    def test_known_unsafe_states_fail_without_registration(self):
        for mode in ["multi-threaded", "wrong-thread", "already-registered"]:
            with self.subTest(mode=mode):
                result = self.run_fixture(mode, smoke=True)
                self.assertNotIn("ARX_BOOTSTRAP_REGISTERED", result.stderr)
                self.assertNotIn("ARX_BOOTSTRAP_FRAMEWORK_VERIFIED", result.stderr)
                if mode == "multi-threaded":
                    self.assertEqual(result.stderr, "Arx startup stopped: Allocator startup refused because the process already has multiple threads.\n")


if __name__ == "__main__":
    unittest.main()
