"""Per-tab volume (DEV-800): the audio service's group gain and its browser entry."""

from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

from Scripts.engine import audio_volume_overlay, overlay
from Scripts.engine.config import SOURCE

FIXTURES = Path(__file__).parent / "fixtures/audio-volume-overlay"


def prepare(root, origin=FIXTURES):
    for path in FIXTURES.rglob("*"):
        if path.is_file():
            relative = path.relative_to(FIXTURES)
            (root / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(origin / relative, root / relative)


def append_anchors(root):
    """Adds each anchor to whatever the files already hold, for the combined overlay test."""
    for path in FIXTURES.rglob("*"):
        if path.is_file():
            target = root / path.relative_to(FIXTURES)
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("a") as stream:
                stream.write(path.read_text())


def anchors():
    """Every (file, anchor) the overlay patches, in order."""
    calls = []
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        prepare(root)
        with mock.patch.object(overlay, "replace_once", lambda path, old, new: calls.append((path.relative_to(root), old))):
            audio_volume_overlay.apply(root)
    return calls


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


class AudioVolumeOverlayTests(unittest.TestCase):
    def test_applies_once_and_scales_only_local_playout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            audio_volume_overlay.apply(root)
            first = snapshot(root)
            audio_volume_overlay.apply(root)
            self.assertEqual(first, snapshot(root))

            controller = (root / "services/audio/output_controller.cc").read_text()
            # The stream's creation and every later SetVolume carry the group's volume.
            self.assertEqual(controller.count("stream_->SetVolume(volume_ * group_volume_);"), 2)
            self.assertNotIn("stream_->SetVolume(volume_);", controller)
            self.assertIn("void OutputController::SetGroupVolume(double volume) {", controller)
            self.assertIn("std::clamp(volume, 0.0, 1.0)", controller)

            mojom = (root / "media/mojo/mojom/audio_stream_factory.mojom").read_text()
            self.assertIn("interface LocalVolume {\n  SetVolume(double volume);\n};", mojom)
            self.assertIn("BindVolume(pending_associated_receiver<LocalVolume> receiver,", mojom)

            # Every AudioStreamFactory implements the new method.
            for name in ["services/audio/stream_factory.h",
                         "services/audio/public/cpp/fake_stream_factory.h",
                         "chrome/browser/speech/extension_api/tts_audio_output_stream_factory.h",
                         "content/browser/media/forwarding_audio_stream_factory_unittest.cc",
                         "content/browser/media/audio_loopback_stream_broker_unittest.cc"]:
                with self.subTest(name=name):
                    self.assertEqual((root / name).read_text().count("  void BindVolume("), 1)

            factory = (root / "services/audio/stream_factory.cc").read_text()
            self.assertIn("void StreamFactory::BindVolume(", factory)
            self.assertIn("void StreamFactory::DestroyVolume(", factory)
            self.assertIn('BindVolume is rejected', (root / "chrome/browser/speech/extension_api/tts_audio_output_stream_factory.cc").read_text())

            # The service copies arrive whole and are built.
            for name in ["arx_local_volume.h", "arx_local_volume.cc"]:
                self.assertTrue((root / "services/audio" / name).is_file())
            build = (root / "services/audio/BUILD.gn").read_text()
            self.assertIn('"arx_local_volume.cc",\n    "arx_local_volume.h",\n    "local_muter.cc",', build)

            # The browser binds the volume again whenever it reconnects to the service.
            forwarding = (root / "content/browser/media/forwarding_audio_stream_factory.cc").read_text()
            self.assertIn("      muter_->Connect(remote_factory_.get());\n    }\n    ConnectVolume();", forwarding)
            self.assertIn("double ForwardingAudioStreamFactory::GetVolume() const {", forwarding)

            web_contents = (root / "content/public/browser/web_contents.h").read_text()
            self.assertIn("virtual void SetAudioVolume(double volume) {}", web_contents)
            impl = (root / "content/browser/web_contents/web_contents_impl.cc").read_text()
            self.assertIn("GetAudioStreamFactory()->SetVolume(std::clamp(volume, 0.0, 1.0));", impl)

    def test_service_volume_validates_and_restores_full_volume(self):
        source = (overlay.PACKAGE / "Native/audio_volume/arx_local_volume.cc").read_text()
        self.assertIn('if (!std::isfinite(volume) || volume < 0 || volume > 1) {', source)
        self.assertIn('receivers_.ReportBadMessage("Invalid group volume");', source)
        self.assertIn("base::BindRepeating(&ApplyGroupVolume, 1.0)", source)
        self.assertIn("source->SetGroupVolume(volume_);", source)

    def test_each_changed_anchor_fails_closed(self):
        for relative, anchor in anchors():
            with self.subTest(file=str(relative), anchor=anchor[:70]), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                path = root / relative
                path.write_text(path.read_text().replace(anchor, "changed pinned upstream anchor", 1))
                with self.assertRaisesRegex(ValueError, "overlay anchor changed"):
                    audio_volume_overlay.apply(root)

    @unittest.skipUnless((SOURCE / "services/audio/output_controller.cc").is_file(), "no prepared Chromium tree")
    def test_anchors_match_the_prepared_chromium_tree(self):
        # The prepared tree already carries this overlay after a build that applied it.
        if "group_volume_" in (SOURCE / "services/audio/output_controller.cc").read_text():
            self.skipTest("the prepared tree already has the overlay")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root, origin=SOURCE)
            audio_volume_overlay.apply(root)
            audio_volume_overlay.apply(root)


if __name__ == "__main__":
    unittest.main()
