"""Compile exact native gesture policy and staged queue/ACK seam with sanitizers."""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest

from Scripts.engine import gesture_overlay
from Scripts.engine.overlay import PACKAGE

FIXTURES = Path(__file__).parent / "fixtures"


def prepare(root):
    for name, text in json.loads((FIXTURES / "gesture-overlay.json").read_text()).items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def compile_fixture(source, executable):
    result = subprocess.run([
        "xcrun", "clang++", "-std=c++20", "-Wall", "-Werror",
        "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
        "-I" + str(PACKAGE / "Native"), str(source), "-o", str(executable),
    ], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise AssertionError(result.stdout + result.stderr)


class GestureOwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.executable = Path(cls.directory.name) / "gesture-ownership"
        compile_fixture(FIXTURES / "gesture_ownership.cc", cls.executable)

    def test_native_admission_and_one_use_release(self):
        for scenario in ["unissued", "complete-once", "consumed", "css", "browser-filter",
                         "old-gesture", "epoch", "foreign-page", "reversal", "inversion",
                         "vertical", "edge-reservation", "boundary", "cancel",
                         "invalid-motion", "partial", "late-css", "out-of-order-css",
                         "later-consumer", "edge-scrubber", "edge-reversal",
                         "edge-containment-after-reveal", "edge-retreat", "history-list", "selection",
                         "unfocused-start", "scroll-start", "scroll-travel"]:
            with self.subTest(scenario=scenario):
                result = subprocess.run([str(self.executable), scenario],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_staged_overlay_is_repeatable_and_preserves_existing_responder(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            gesture_overlay.apply(root)
            first = {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}
            gesture_overlay.apply(root)
            self.assertEqual(first, {p.relative_to(root): p.read_bytes()
                                     for p in root.rglob("*") if p.is_file()})
            chrome = (root / "chrome/browser/renderer_host/chrome_render_widget_host_view_mac_delegate.mm").read_text()
            self.assertNotIn("setResponderDelegate", chrome)
            self.assertIn("objc_precise_lifetime", chrome)
            self.assertIn("swiping_control->ShouldAllowHistorySwiping()", chrome)
            self.assertIn("return [_historySwiper handleEvent:event];", chrome)
            self.assertIn("if (owner->BlocksChromeHistory()) {", chrome)
            self.assertIn("event.phase == NSEventPhaseBegan", chrome)
            normal = Path(gesture_overlay.__file__).with_name("overlay.py").read_text()
            self.assertIn("gesture_overlay", normal)

    def test_changed_pinned_anchor_is_rejected(self):
        originals = json.loads((FIXTURES / "gesture-overlay.json").read_text())
        for name in originals:
            with self.subTest(path=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prepare(root)
                (root / name).write_text("changed upstream source")
                with self.assertRaisesRegex(ValueError, "anchor changed"):
                    gesture_overlay.apply(root)

    def test_production_queue_keeps_first_proof_and_ack_uses_its_own_css(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare(root)
            gesture_overlay.apply(root)
            event = (root / "components/input/event_with_latency_info.h").read_text()
            queue = event[event.index("template <typename T>"):event.index("typedef EventWithLatencyInfo")]
            router = (root / "components/input/input_router_impl.cc").read_text()
            ack = router[router.index("  // The reply closure retains"):router.index("  // |gesture_event_queue_| will forward to OnGestureEventAck")]
            move = (root / "components/input/gesture_event_queue.cc").read_text()
            source = root / "queue.cc"
            source.write_text((FIXTURES / "gesture_queue.cc").read_text()
                              .replace("// PRODUCTION_QUEUE", queue)
                              .replace("// PRODUCTION_ACK", ack)
                              .replace("// PRODUCTION_MOVE", move))
            executable = root / "queue"
            compile_fixture(source, executable)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
