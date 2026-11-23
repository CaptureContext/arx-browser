#include "document_recording_peers.h"
#include "document_recording_seams.h"
using Budget = cc::ArxCaptureRecordingBudget;
static Budget::Clock::time_point now;
static Budget::Clock::time_point Now() { return now; }

int main() {
  cc::RecordPaintCanvas canvas;
  // Pending setup and outside-scope ordinary paint must remain unaffected.
  {
    Budget budget(0, 0, 0, 10, Now);
    canvas.push<cc::AdmittedOp>();
    assert(cc::retained_ops == 1 && budget.status() == Budget::Status::kSuccess);
    {
      Budget::PaintingScope scope;
      canvas.push<cc::AdmittedOp>();
      assert(cc::retained_ops == 1 && cc::constructed_ops == 1);
      assert(budget.status() == Budget::Status::kLimit);
      // Rejection is sticky and never constructs an alternate expensive op.
      canvas.push<cc::UnsupportedOp>();
      assert(cc::constructed_ops == 1 && budget.status() == Budget::Status::kLimit);
    }
    canvas.push<cc::AdmittedOp>();
    assert(cc::retained_ops == 2);
  }
  {
    Budget budget(100000, 1, 100, 10, Now); Budget::PaintingScope scope;
    cc::RecordPaintCanvas state_canvas;
    state_canvas.save(); // admitted
    state_canvas.save(); // denied, logical save depth still increments
    state_canvas.restore(); state_canvas.restore();
    assert(state_canvas.save_count_ == 1 && budget.status() == Budget::Status::kLimit);
  }
  blink::DisplayItemClient client;
  blink::DrawingDisplayItem item(1);
  {
    Budget budget(0, 10, 100, 10, Now); Budget::PaintingScope scope;
    blink::PaintController controller;
    controller.CreateAndAppend<blink::DrawingDisplayItem>(client);
    assert(controller.artifact.list.items.empty() && controller.marked == 0 && controller.processed == 0);
    auto subsequence = controller.BeginSubsequence(client);
    assert(subsequence == blink::kNotFound && controller.new_subsequences_.tree.empty());
    controller.EndSubsequence(subsequence); // must not index a denied marker
  }
  {
    Budget budget(0, 10, 100, 10, Now); Budget::PaintingScope scope;
    blink::PaintChunker chunker;
    assert(!chunker.IncrementDisplayItemIndex(client, item));
    assert(chunker.chunks_.empty() && chunker.marked == 0); // no back() on failure
  }
  {
    Budget budget(100000, 10, 100, 10, Now); Budget::PaintingScope scope;
    blink::PaintController controller;
    controller.CreateAndAppend<blink::ForeignLayerDisplayItem>(client);
    assert(controller.artifact.list.items.empty() && budget.status() == Budget::Status::kUnsupported);
    assert(budget.unsupported_reason() == Budget::UnsupportedReason::kForeignLayer);
    Budget::Unsupported(Budget::UnsupportedReason::kOperation, 123);
    assert(budget.unsupported_reason() == Budget::UnsupportedReason::kForeignLayer);
    assert(budget.unsupported_detail() == 0); // preserve the first rejection
  }
  // Actual op admission sees nested payload metadata before constructors.
  for (int kind = 0; kind < 5; ++kind) {
    Budget budget(100000, 10, 16, 10, Now); Budget::PaintingScope scope;
    int before = cc::constructed_ops;
    if (kind == 0) { cc::PaintRecord record; record.bytes = 100001; canvas.push<cc::AdmittedOp>(record); }
    if (kind == 1) { SkPath path; path.bytes = UINT64_MAX; canvas.push<cc::AdmittedOp>(path); }
    if (kind == 2) { cc::PaintImage image; image.width = 3; image.height = 3; image.bytes = 1; canvas.push<cc::AdmittedOp>(image); }
    if (kind == 3) { auto blob = std::make_shared<SkTextBlob>(); blob->glyphs = {100001}; canvas.push<cc::AdmittedOp>(blob); }
    if (kind == 4) { cc::PaintFlags flags; flags.shader = true; canvas.push<cc::AdmittedOp>(&flags); }
    assert(cc::constructed_ops == before && budget.status() != Budget::Status::kSuccess);
  }
  // A linear gradient is recorded and charged; a radial one is refused before construction.
  {
    Budget budget(100000, 10, 16, 10, Now); Budget::PaintingScope scope;
    int before = cc::constructed_ops;
    cc::PaintFlags flags; flags.shader = true; flags.shader_value.type = cc::PaintShader::Type::kLinearGradient;
    canvas.push<cc::AdmittedOp>(&flags);
    assert(cc::constructed_ops == before + 1 && budget.status() == Budget::Status::kSuccess);
    flags.shader_value.type = cc::PaintShader::Type::kRadialGradient;
    canvas.push<cc::AdmittedOp>(&flags);
    assert(cc::constructed_ops == before + 1 && budget.status() == Budget::Status::kUnsupported);
  }
  {
    Budget budget(100000, 10, 100, 10, Now); Budget::PaintingScope scope;
    now += std::chrono::milliseconds(10);
    int before = cc::constructed_ops; canvas.push<cc::AdmittedOp>();
    assert(cc::constructed_ops == before && budget.status() == Budget::Status::kTimeout);
  }
  {
    Budget budget(100000, 100000, 100, 10, Now); Budget::PaintingScope scope;
    for (int index = 0; index < 4096; ++index) assert(Budget::Layout(0, 1, 64));
    assert(!Budget::Layout(0, 1, 64));
  }
  {
    Budget budget(100000, 100000, 100, 10, Now); Budget::PaintingScope scope;
    assert(!Budget::Layout(0, 0, 65));
  }
  {
    Budget budget(100000, 100000, 100, 10, Now); Budget::PaintingScope scope;
    assert(!Budget::Layout(100001, 0, 0));
  }
  // The scope unwinds even after denied entries. Fresh ordinary repaint still
  // creates items/chunks/ops without the previous capture's failure or counters.
  blink::PaintController controller;
  controller.CreateAndAppend<blink::DrawingDisplayItem>(client);
  assert(controller.artifact.list.items.size() == 1 && controller.processed == 1);
  blink::PaintChunker chunker;
  assert(chunker.IncrementDisplayItemIndex(client, item));
  assert(chunker.chunks_.size() == 1 && chunker.chunks_.back().end_index == 1);
  int before = cc::retained_ops; canvas.push<cc::AdmittedOp>(); assert(cc::retained_ops == before + 1);
}
