import subprocess
import tempfile
import unittest
from pathlib import Path

from Scripts.engine import document_capture_prototype as prototype
from Scripts.engine import document_recording_overlay as recording
from Scripts.engine import document_raster_overlay as raster


class DocumentRasterBudgetTests(unittest.TestCase):
    def test_actual_preallocation_policy_with_sanitizers(self):
        source = r'''
#include <cassert>
#include <climits>
#include <initializer_list>
#include "raster_surface_budget.h"
using arx::document::RasterSurfaceBudget;
int main() {
  uint64_t bytes = 0;
  RasterSurfaceBudget maximum(8192, 2048);
  assert(maximum.Acquire(8192, 2048, &bytes) && bytes == 64 * 1024 * 1024);
  assert(maximum.Acquire(8192, 2048, &bytes));
  assert(!maximum.Acquire(1, 1, &bytes));
  assert(maximum.live_bytes() == 128 * 1024 * 1024);
  assert(maximum.Release(64 * 1024 * 1024));
  assert(maximum.Release(64 * 1024 * 1024));
  assert(!maximum.Acquire(1, 1, &bytes));  // sticky failure after release
  assert(maximum.live_bytes() == 0);
  RasterSurfaceBudget reused(8, 8, 256);
  assert(reused.Acquire(8, 8, &bytes));
  for (int i = 0; i < 100; ++i) {
    assert(reused.Acquire(8, 8, &bytes));
    assert(reused.Release(bytes));
  }
  assert(reused.live_bytes() == 256 && reused.peak_bytes() == 512);
  assert(reused.Release(256) && reused.live_bytes() == 0);
  RasterSurfaceBudget depth(1, 1);
  for (int i = 0; i < 9; ++i) assert(depth.Acquire(1, 1, &bytes));
  assert(!depth.Acquire(1, 1, &bytes));
  for (int i = 0; i < 9; ++i) assert(depth.Release(4));
  assert(!depth.Release(4));
  for (int size : {-1, 0, 8193, INT_MAX}) {
    RasterSurfaceBudget invalid(size, size);
    assert(!invalid.Acquire(size, size, &bytes));
    assert(invalid.live_bytes() == 0);
  }
  RasterSurfaceBudget wrong_base(8, 8);
  assert(!wrong_base.Acquire(1, 1, &bytes));
  RasterSurfaceBudget wrong_layer(8, 8);
  assert(wrong_layer.Acquire(8, 8, &bytes));
  assert(!wrong_layer.Acquire(9, 1, &bytes));
  RasterSurfaceBudget invalid_cap(8, 8, UINT64_MAX);
  assert(!invalid_cap.Acquire(8, 8, &bytes));
}
'''
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            cpp = temp / "policy.cc"
            cpp.write_text(source)
            binary = temp / "policy"
            result = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                "-fsanitize=address,undefined", "-I", str(prototype.PROTOTYPE),
                str(cpp), "-o", str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True)

    def test_previous_alpha_rejection_overlay_migrates_idempotently(self):
        relative = "cc/paint/record_paint_canvas.cc"
        anchor, current = next((old, new) for path, old, new in recording.patches()
                               if path == relative and old == "namespace cc {\n")
        previous = current.replace("case PaintOpType::kSaveLayerAlpha: ", "")
        for emitted in [previous, previous.replace(anchor, current, 1)]:
            with self.subTest(duplicate=emitted != previous), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                for path, old, new in recording.patches():
                    if (path, old.splitlines()[0]) not in recording._DIAGNOSTICS_FREE_BLOCKS:
                        continue
                    file = root / path
                    file.parent.mkdir(parents=True, exist_ok=True)
                    with file.open("a") as stream:
                        stream.write((emitted if path == relative else new) + "\n")
                recording.migrate_recording_diagnostics(root)
                self.assertEqual((root / relative).read_text().count(current), 1)
                recording.migrate_recording_diagnostics(root)
                self.assertEqual((root / relative).read_text().count(current), 1)

    def test_actual_create_bitmap_ordinary_branch_preserves_scale_clip_and_failure(self):
        fixtures = Path(__file__).parent / "fixtures"
        source = (fixtures / "document_raster_create_bitmap.cc").read_text()
        # Apply the actual production function patches, then compile that body.
        for _, old, new in raster.patches():
            if old in source:
                self.assertEqual(source.count(old), 1)
                source = source.replace(old, new)
        self.assertIn("std::shared_ptr<arx::document::RasterState> arx_state", source)
        self.assertIn("if (arx_state)", source)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cpp = root / "ordinary.cc"
            cpp.write_text((fixtures / "document_raster_ordinary_peers.h").read_text() + source + r"""
int main() {
  auto picture=std::make_shared<SkPicture>();
  auto normal=CreateBitmap(nullptr,picture,{5,7,40,60},2.f,nullptr);
  assert(normal && normal->width==40 && normal->height==60);
  assert(allocations==1 && ordinary_draws==1 && capture_draws==0);
  assert(actual_matrix.scale_x==2 && actual_matrix.scale_y==2);
  assert(actual_matrix.translate_x==-5 && actual_matrix.translate_y==-7);
  allocation_allowed=false;
  assert(!CreateBitmap(nullptr,picture,{0,0,10,10},1.f,nullptr));
  assert(ordinary_draws==1 && capture_draws==0);
  auto capture=std::make_shared<arx::document::RasterState>(8,8);
  assert(CreateBitmap(nullptr,picture,{0,0,8,8},1.f,capture));
  assert(capture_draws==1 && ordinary_draws==1 && allocations==2);
  assert(!CreateBitmap(nullptr,picture,{1,0,8,8},1.f,capture));
  assert(capture->failed && capture_draws==1 && allocations==2);
}
""")
            result = subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
                "-Wno-unused-parameter", "-fsanitize=address,undefined",
                str(cpp), "-o", str(root / "ordinary"),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "ordinary")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        separated = next(new for _, old, new in raster.patches() if "frame_it->second.skp" in old)
        self.assertIn("scale_factor, nullptr)", separated)
