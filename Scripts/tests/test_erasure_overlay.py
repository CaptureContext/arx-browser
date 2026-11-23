"""Validate every strict-singleton/profile-guard anchor in temporary text fixtures."""
from pathlib import Path
import tempfile
import unittest

from Scripts.engine import erasure_overlay
from Scripts.engine.config import PACKAGE


def prepare(root):
    for relative, old, _ in erasure_overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


class ErasureOverlayTests(unittest.TestCase):
    def test_repeatable_and_each_changed_anchor_fails_closed(self):
        patches = list(erasure_overlay.patches())
        for index, (relative, old, _) in enumerate(patches):
            with self.subTest(anchor=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                path = root / relative
                path.write_text(path.read_text().replace(old, "changed upstream anchor", 1))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    erasure_overlay.apply(root)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            erasure_overlay.apply(root)
            first = {str(path): path.read_bytes() for path in root.rglob("*") if path.is_file()}
            erasure_overlay.apply(root)
            self.assertEqual(first, {str(path): path.read_bytes() for path in root.rglob("*") if path.is_file()})

    def test_strict_acquisition_does_not_enter_recovery_or_notification(self):
        replacements = "\n".join(new for _, _, new in erasure_overlay.patches())
        strict = replacements.split("ProcessSingleton::StrictCreationResult ProcessSingleton::CreateWithoutRecovery() {", 1)[1].split("\n}", 1)[0]
        self.assertIn("const bool created = Create()", strict)
        self.assertNotIn("Notify", strict)
        self.assertNotIn("Kill", strict)
        self.assertIn("if (deny_lock_recovery_)", replacements)
        self.assertIn("strict_lock_conflict_ = true", replacements)
        self.assertIn("deny_lock_recovery_ = false", strict)

    def test_native_startup_pumps_ui_and_seals_deletion_before_profiles(self):
        bridge = (PACKAGE / "Native/profile_erasure/bridge.cc").read_text()
        startup = bridge.split("void BeforeProfiles() {", 1)[1].split("void BeforeShutdown()", 1)[0]
        self.assertIn("manager->user_data_dir() != state.root", startup)
        self.assertIn("manager->GetLoadedProfiles().empty()", startup)
        self.assertIn("WasCreatedWithoutRecovery()", startup)
        self.assertLess(startup.index("->RequirePriorCleanBoundary()"), startup.index("->BeginRun("))
        self.assertIn("base::RunLoop::Type::kNestableTasksAllowed", startup)
        self.assertIn("PostTaskAndReplyWithResult", startup)
        self.assertNotIn("->Execute()", startup)
        self.assertLess(startup.index("->ResumeQuarantinedAfterBoot()"), startup.index("->StageForNextBoot()"))
        self.assertLess(startup.index("->StageForNextBoot()"), startup.index("->FinishStartup()"))
        self.assertLess(startup.index("->FinishStartup()"), startup.index("Current().active ="))
        engine = (PACKAGE / "Native/engine_bridge.mm").read_text()
        # Erasure's startup hook runs first; DEV-880's session keeper follows it.
        hook = engine.split("void PreProfileInit() override {", 1)[1].split("\n  }\n", 1)[0]
        self.assertTrue(hook.lstrip().startswith("erasure::BeforeProfiles();"))
        self.assertLess(hook.index("erasure::BeforeProfiles();"), hook.index("SetArxSessionKeeper("))
        self.assertIn('erasure::Enabled() ? erasure::kBootstrapProfile : "Default"', engine)
        ordinary = engine.split("int RunWithOptions(", 1)[1].split("int RunWithProfileRetirement(", 1)[0]
        self.assertNotIn("erasure::Configure(", ordinary)
        # Retirement is explicit; ordinary runs cannot configure it accidentally.
        header = (PACKAGE / "Sources/ChromiumBridge/include/ChromiumBridge.h").read_text()
        self.assertIn("run_with_profile_retirement", header)
        self.assertIn("queue_profile_retirement", header)

    def test_fingerprint_includes_the_erasure_overlay(self):
        source = (PACKAGE.parents[1] / "Scripts/engine/artifact.py").read_text()
        self.assertIn('"Scripts/engine/erasure_overlay.py"', source)
