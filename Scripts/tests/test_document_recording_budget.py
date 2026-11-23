"""Exercise capture-only upstream admission seams before allocation/retention."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from Scripts.engine import document_capture_prototype as prototype
from Scripts.engine import document_recording_overlay as overlay


class DocumentRecordingBudgetTests(unittest.TestCase):
    def test_previous_and_partial_diagnostic_overlays_upgrade_to_one_current_block(self):
        for mode in ("previous", "partially-updated"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                expected = {}
                for relative, anchor, current in overlay.patches():
                    legacy = overlay._DIAGNOSTICS_FREE_BLOCKS.get((relative, anchor.splitlines()[0]))
                    if legacy is None:
                        continue
                    original = legacy
                    if mode == "partially-updated" and anchor in legacy:
                        original = legacy.replace(anchor, current, 1)
                        if relative.endswith("web_local_frame_impl.cc"):
                            # Real failed update: old PREPAINT precedes the new
                            # PREPAINT, both before the original builder anchor.
                            self.assertTrue(legacy.endswith(anchor))
                            original = legacy.removesuffix(anchor) + current
                            self.assertEqual(original.count("PaintingScope capture_recording_scope;"), 2)
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with path.open("a") as output:
                        output.write(original + "\n")
                    expected[path] = expected.get(path, "") + current + "\n"
                self.assertEqual(sum(content.count("namespace cc") for content in expected.values()), 1)
                overlay.migrate_recording_diagnostics(root)
                self.assertEqual(expected, {path: path.read_text() for path in expected})
                overlay.migrate_recording_diagnostics(root)
                self.assertEqual(expected, {path: path.read_text() for path in expected})

    def test_shaderless_flags_admission_migrates_once_to_gradient_admission(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            # A tree already patched with every current block, except the old flags admission.
            for relative, anchor, block in overlay.patches():
                if overlay._DIAGNOSTICS_FREE_BLOCKS.get((relative, anchor.splitlines()[0])) is None:
                    continue
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a") as output:
                    output.write(block + "\n")
            canvas = root / "cc/paint/record_paint_canvas.cc"
            current = overlay.OP_ADMISSION
            previous = current.replace(overlay._current_flags(), overlay._SHADERLESS_FLAGS)
            self.assertNotEqual(previous, current)
            patched = canvas.read_text()
            canvas.write_text(patched.replace(current, previous, 1))
            overlay.migrate_recording_diagnostics(root)
            self.assertEqual(canvas.read_text(), patched)
            overlay.migrate_recording_diagnostics(root)
            self.assertEqual(canvas.read_text().count("PaintShader::Type::kLinearGradient"), 1)
            # Both blocks at once is ambiguous and changes nothing.
            canvas.write_text(patched.replace(current, previous + current, 1))
            with self.assertRaises(ValueError):
                overlay.migrate_recording_diagnostics(root)

    def test_diagnostic_migration_rejects_ambiguous_or_changed_blocks_without_writes(self):
        for mode in ("ambiguous", "changed"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                originals = {}
                for relative, anchor, current in overlay.patches():
                    legacy = overlay._DIAGNOSTICS_FREE_BLOCKS.get((relative, anchor.splitlines()[0]))
                    if legacy is None:
                        continue
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with path.open("a") as output:
                        output.write(legacy + "\n")
                path = root / "third_party/blink/renderer/core/frame/web_local_frame_impl.cc"
                if mode == "ambiguous":
                    path.write_text(path.read_text() * 2)
                else:
                    path.write_text("changed upstream capture builder\n")
                originals = {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
                with self.assertRaisesRegex(ValueError, "Ambiguous|anchor changed"):
                    overlay.migrate_recording_diagnostics(root)
                self.assertEqual(originals, {p: p.read_bytes() for p in originals})

    def test_actual_canvas_item_chunk_and_subsequence_seams_unwind_after_exhaustion(self):
        fixtures = Path(__file__).parent / "fixtures"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("document_resource_peers.h", "document_recording_peers.h", "document_recording_budget.cc"):
                shutil.copy2(fixtures / name, root / name)
            shutil.copy2(prototype.PROTOTYPE / "cc/arx_capture_recording_budget.h", root)
            source = (fixtures / "document_recording_seams.h").read_text()
            required = {"void RecordPaintCanvas::push", "void CreateAndAppend", "if (WillCreateNewChunk())",
                        "BeginSubsequence", "EndSubsequence", "EnsureCurrentChunk(item.GetId()"}
            observed = set()
            for _, old, new in overlay.patches():
                if old in source:
                    self.assertEqual(source.count(old), 1, old)
                    source = source.replace(old, new)
                    observed |= {name for name in required if name in old}
            self.assertEqual(observed, required)
            source = source.replace("// OP_ADMISSION", "")
            (root / "document_recording_seams.h").write_text(source)
            compiled = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                "-Wno-unused-function", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                "-I", str(root), str(root / "document_recording_budget.cc"), "-o", str(root / "recording"),
            ], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(root / "recording")], capture_output=True, text=True)
            self.assertEqual(executed.returncode, 0, executed.stderr)

    def test_scope_is_after_lifecycle_and_failure_precedes_end_recording_or_chunk_indexing(self):
        patches = overlay.patches()
        builder = next(new for _, old, new in patches if "PaintRecordBuilder builder;" in old)
        self.assertLess(builder.index("PaintingScope"), builder.index("PaintRecordBuilder builder;"))
        self.assertIn("NextInPreOrder(root)", builder)
        self.assertIn("depth > 64", builder)
        painted = next(new for _, old, new in patches if "PaintOutsideOfLifecycle(builder.Context()" in old)
        self.assertIn("if (!cc::ArxCaptureRecordingBudget::Good()) return false;", painted)
        final = next(new for _, old, new in patches if "canvas->drawPicture(builder.EndRecording" in old)
        self.assertIn("return cc::ArxCaptureRecordingBudget::Good();", final)
        for signature, (_, body) in overlay.CHUNK_FUNCTIONS.items():
            self.assertIn("if (!cc::ArxCaptureRecordingBudget::Good()) return", body, signature)
        # Generated/source order and exact pinned syntax are separately checked;
        # this suite executes admission prefixes with deterministic allocation peers.
