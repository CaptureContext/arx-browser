"""Widevine is answered without a CDM, and a failed CDM reports protected media (DEV-1144)."""

from pathlib import Path
import tempfile
import unittest

from Scripts.engine import widevine_answer_overlay as overlay


def prepare(root):
    for relative, old, _ in overlay.patches():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write(old + "\n")


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


class WidevineAnswerOverlayTests(unittest.TestCase):
    def test_apply_is_repeatable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            first = snapshot(root)
            overlay.apply(root)
            self.assertEqual(first, snapshot(root))

    def test_the_feature_is_declared_and_on_by_default(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            header = (root / overlay.SWITCHES_HEADER).read_text()
            source = (root / overlay.SWITCHES_SOURCE).read_text()
            self.assertIn("MEDIA_EXPORT BASE_DECLARE_FEATURE(kArxWidevineAnswer);", header)
            self.assertIn("BASE_FEATURE(kArxWidevineAnswer, base::FEATURE_ENABLED_BY_DEFAULT);", source)

    def test_widevine_is_answered_and_a_real_cdm_is_never_used(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            source = (root / overlay.KEY_SYSTEMS).read_text()
            self.assertIn('#include "media/cdm/supported_audio_codecs.h"', source)
            # Defined before its caller, inside ENABLE_WIDEVINE.
            self.assertLess(source.index("media::KeySystemCapability ArxWidevineCapabilityWithoutCdm()"),
                            source.index("void OnKeySystemSupportUpdated("))
            guard = source.index("if (base::FeatureList::IsEnabled(media::kArxWidevineAnswer)) {")
            self.assertLess(guard, source.index("for (const auto& [key_system, capability] : key_system_capabilities)"))
            # A Widevine capability the browser reports (a CDM on disk) is skipped, never added.
            self.assertNotIn("AddWidevine(capability, can_persist_data, &key_systems);", source)
            self.assertIn("never a real Widevine CDM", source)
            # Temporary sessions only.
            self.assertIn("capability.session_types = {CdmSessionType::kTemporary};", source)

    def test_a_missing_library_cdm_reports_protected_media(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            overlay.apply(root)
            source = (root / overlay.INTERFACE_PROXY).read_text()
            self.assertIn('#include "chrome/browser/arx/protected_media_hooks.h"  // nogncheck', source)
            missing = source.index("  if (!factory) {\n")
            self.assertLess(missing, source.index("arx::ReportProtectedMediaFailure(&render_frame_host());"))
            # Widevine never gets a factory, even with a CDM on disk.
            self.assertIn('cdm_config.key_system == "com.widevine.alpha"\n                      ? nullptr', source)

    def test_every_changed_anchor_fails_closed(self):
        for index, (relative, old, _) in enumerate(overlay.patches()):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                path = root / relative
                path.write_text(path.read_text().replace(old, "changed upstream\n"))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    overlay.apply(root)


if __name__ == "__main__":
    unittest.main()
