"""Exercise prototype resource rejection without activating a Chromium build."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.engine import document_capture_prototype as prototype
from Scripts.engine.config import SOURCE


class DocumentCapturePrototypeTests(unittest.TestCase):
    def test_recording_budget_rejects_before_retaining_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "budget"
            harness = Path(__file__).parent / "fixtures/document_capture_budget.cc"
            subprocess.run(
                ["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                 "-I", str(prototype.PROTOTYPE), str(harness), "-o", str(executable)],
                check=True, capture_output=True, text=True,
            )
            subprocess.run([str(executable)], check=True, capture_output=True, text=True)

    def test_actual_resource_admission_before_readback_with_sanitizers(self):
        import shutil
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            include = root / "include"
            alias = include / "components/paint_preview/arx"
            alias.mkdir(parents=True)
            for name in ("record_admission.h", "resource_budget.h", "budget.h"):
                shutil.copy2(prototype.PROTOTYPE / name, alias / name)
            peers = Path(__file__).parent / "fixtures/document_resource_peers.h"
            shutil.copy2(peers, include / peers.name)
            for name in ("base/time/time.h", "cc/paint/paint_record.h", "cc/paint/paint_image.h",
                         "cc/paint/paint_op.h", "cc/paint/paint_op_buffer_iterator.h", "cc/paint/paint_shader.h",
                         "third_party/skia/include/core/SkTextBlob.h", "third_party/skia/include/core/SkTypeface.h",
                         "components/paint_preview/arx/document_capture.mojom.h"):
                target = include / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('#include "document_resource_peers.h"\n')
            executable = root / "admission"
            compiled = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                "-fsanitize=address,undefined", "-I", str(include),
                str(prototype.PROTOTYPE / "record_admission.cc"),
                str(peers.with_name("document_resource_admission.cc")), "-o", str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(executed.returncode, 0, executed.stderr)

    def test_actual_png_encoder_caps_each_write_and_stops_between_rows(self):
        import shutil
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            include = root / "include"
            alias = include / "components/paint_preview/arx"
            alias.mkdir(parents=True)
            for name in ("png_encoding.h", "bounded_stream.h", "budget.h"):
                shutil.copy2(prototype.PROTOTYPE / name, alias / name)
            fixtures = Path(__file__).parent / "fixtures"
            for name in ("document_resource_peers.h", "document_encoding_peers.h"):
                shutil.copy2(fixtures / name, include / name)
            for name in ("base/time/time.h", "third_party/skia/include/core/SkBitmap.h",
                         "third_party/skia/include/core/SkStream.h", "third_party/skia/include/encode/SkEncoder.h",
                         "third_party/skia/include/encode/SkPngRustEncoder.h",
                         "components/paint_preview/arx/document_capture.mojom.h"):
                target = include / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('#include <cassert>\n#include "document_encoding_peers.h"\n')
            executable = root / "png"
            compiled = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                "-fsanitize=address,undefined", "-I", str(include),
                str(prototype.PROTOTYPE / "png_encoding.cc"),
                str(fixtures / "document_png_encoding.cc"), "-o", str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(executed.returncode, 0, executed.stderr)

    def test_overlay_refuses_shared_runtime_checkout(self):
        with self.assertRaisesRegex(ValueError, "shared engine source"):
            prototype.apply(SOURCE)

    def test_pinned_overlay_is_repeatable_and_rejects_changed_anchors(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / prototype.MARKER).write_text(prototype.MARKER_CONTENT)
            for relative, old, _ in prototype.patches():
                path = source / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as output:
                    output.write(old + "\n")
            prototype.apply(source)
            first = {str(p.relative_to(source)): p.read_bytes()
                     for p in source.rglob("*") if p.is_file()}
            prototype.apply(source)
            self.assertEqual(first, {str(p.relative_to(source)): p.read_bytes()
                                     for p in source.rglob("*") if p.is_file()})

            relative, _, _ = prototype.patches()[0]
            (source / relative).write_text("changed upstream declaration\n")
            with self.assertRaisesRegex(ValueError, "anchor changed"):
                prototype.apply(source)

    def test_overlay_refuses_unmarked_source_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "marked isolated"):
                prototype.apply(Path(temporary))

    def test_prototype_is_not_activated_by_shipping_overlay(self):
        overlay = Path(prototype.__file__).with_name("overlay.py").read_text()
        self.assertNotIn("document_capture_prototype", overlay)
        self.assertNotIn("DocumentCapture", overlay)


if __name__ == "__main__":
    unittest.main()
