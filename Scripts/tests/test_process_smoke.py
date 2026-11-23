"""Keep runtime sandbox evidence scoped to actual packaged app child processes."""

import tempfile
import unittest
from pathlib import Path

from Scripts.core.process_smoke import ProcessProbe


class ProcessSmokeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / "Arx Smoke.app"
        self.prefix = self.app / "Contents/Frameworks/Arx Framework.framework/Versions/156/Helpers"
        self.helper = self.prefix / "Arx Helper.app/Contents/MacOS/Arx Helper"
        self.helper.parent.mkdir(parents=True)
        self.helper.touch()
        self.paths = {pid: self.helper for pid in range(101, 105)}

    def probe(self, check_sandbox=lambda _: 1):
        return ProcessProbe(self.app, check_sandbox, self.paths.get)

    def child(self, pid, flags, parent=100):
        return f"{pid} {parent} {self.helper} {flags}"

    def roles(self):
        return "\n".join([
            self.child(101, "--type=renderer"),
            self.child(102, "--type=gpu-process"),
            self.child(103, "--type=utility --utility-sub-type=network.mojom.NetworkService"),
        ])

    def test_requires_distinct_packaged_renderer_gpu_and_network_evidence(self):
        probe = self.probe()
        probe.observe(100, self.roles())
        self.assertIn("ARX_PROCESS_ISOLATION_SMOKE_SUCCESS", probe.verify())
        self.assertEqual(set(probe.sandboxed), {"renderer", "gpu", "network"})

    def test_other_parents_and_unknown_utilities_do_not_supply_evidence(self):
        checked = []
        probe = self.probe(lambda pid: checked.append(pid) or 1)
        probe.observe(100, "\n".join([
            self.child(101, "--type=renderer", parent=999),
            self.child(102, "--type=utility --utility-sub-type=other.Service"),
            self.child(103, "--type=renderer-extra"),
            "malformed output",
        ]))
        self.assertEqual(checked, [])
        with self.assertRaisesRegex(ValueError, "No sandboxed packaged helpers"):
            probe.verify()

    def test_unknown_and_unsandboxed_results_never_pass(self):
        for result in [-1, 0, 2]:
            with self.subTest(result=result):
                probe = self.probe(lambda _: result)
                probe.observe(100, self.roles())
                with self.assertRaisesRegex(ValueError, "No sandboxed packaged helpers"):
                    probe.verify()

    def test_startup_observation_can_become_sandboxed(self):
        result = 0
        probe = self.probe(lambda _: result)
        probe.observe(100, self.roles())
        self.assertFalse(probe.sandboxed)
        result = 1
        probe.observe(100, self.roles())
        self.assertIn("SUCCESS", probe.verify())

    def test_no_sandbox_fails_even_after_good_observations(self):
        probe = self.probe()
        probe.observe(100, self.roles() + "\n" + self.child(104, "--type=renderer --no-sandbox"))
        with self.assertRaisesRegex(ValueError, "disabled sandboxing"):
            probe.verify()

    def test_chromium_sandbox_bypass_switch_forms_reject_later_child(self):
        for flags in [
            "--type=renderer --no-sandbox=1",
            "-type=renderer -no-sandbox",
            "--type=renderer --no-sandbox=false",
            "--type=gpu-process --disable-gpu-sandbox",
            "-type=gpu-process -disable-gpu-sandbox=0",
            "--type=utility --utility-sub-type=network.mojom.NetworkService --service-sandbox-type=none",
            "-type=utility -utility-sub-type=network.mojom.NetworkService -service-sandbox-type=none",
        ]:
            with self.subTest(flags=flags):
                probe = self.probe(lambda pid: 0 if pid == 104 else 1)
                probe.observe(100, self.roles())
                probe.observe(100, self.child(104, flags))
                with self.assertRaisesRegex(ValueError, "disabled sandboxing"):
                    probe.verify()

    def test_similar_switch_names_do_not_count_as_bypasses(self):
        probe = self.probe()
        probe.observe(100, self.roles() + "\n" + self.child(
            104, "--type=renderer --no-sandbox-extra --disable-gpu-sandbox-extra"
        ))
        self.assertIn("SUCCESS", probe.verify())

    def test_duplicate_role_switches_cannot_reuse_earlier_good_evidence(self):
        for flags in [
            "--type=renderer --type=gpu-process",
            "--type=renderer -type=gpu-process",
            "--type=utility --utility-sub-type=network.mojom.NetworkService --utility-sub-type=other.Service",
        ]:
            with self.subTest(flags=flags):
                probe = self.probe()
                probe.observe(100, self.roles())
                probe.observe(100, self.child(104, flags))
                with self.assertRaisesRegex(ValueError, "ambiguous Chromium role switches"):
                    probe.verify()

    def test_external_executable_cannot_impersonate_packaged_helper_in_argv(self):
        external = self.root / "Other Helper"
        external.touch()
        self.paths[104] = external
        probe = self.probe()
        probe.observe(100, self.roles() + "\n" + self.child(104, "--type=renderer"))
        with self.assertRaisesRegex(ValueError, "not loaded from the packaged framework"):
            probe.verify()

    def test_resolved_file_identity_accepts_symlinks_without_trusting_argv(self):
        alias = self.root / "Helper Alias"
        alias.symlink_to(self.helper)
        self.paths[101] = alias
        probe = self.probe()
        listing = self.roles().replace(str(self.helper), "different spelling of argv[0]")
        probe.observe(100, listing)
        self.assertIn("SUCCESS", probe.verify())

    def test_exited_or_unavailable_child_cannot_supply_evidence(self):
        checked = []
        for path in [None, self.root / "No longer present"]:
            with self.subTest(path=path):
                self.paths[101] = path
                probe = self.probe(lambda pid: checked.append(pid) or 1)
                probe.observe(100, self.roles())
                self.assertNotIn(101, checked)
                with self.assertRaisesRegex(ValueError, "No sandboxed packaged helpers.*renderer"):
                    probe.verify()

    def test_missing_bundle_helpers_fail_before_process_observation(self):
        with self.assertRaisesRegex(ValueError, "No packaged Chromium helper"):
            ProcessProbe(self.root / "Empty.app", lambda _: 1, self.paths.get)


if __name__ == "__main__":
    unittest.main()
