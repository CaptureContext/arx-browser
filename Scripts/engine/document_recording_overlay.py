"""Capture-only admission before transient Blink/cc record container retention."""


def patches():
    budget = '#include "cc/paint/arx_capture_recording_budget.h"\n'
    canvas = "cc/paint/record_paint_canvas.cc"
    controller = "third_party/blink/renderer/platform/graphics/paint/paint_controller"
    chunks = "third_party/blink/renderer/platform/graphics/paint/paint_chunker.cc"
    blink = "third_party/blink/renderer/core/frame/web_local_frame_impl.cc"
    changes = [
        ("cc/paint/BUILD.gn", '    "clear_for_opaque_raster.cc",',
         '    "arx_capture_recording_budget.h",\n    "clear_for_opaque_raster.cc",'),
        (canvas, '#include "cc/paint/record_paint_canvas.h"',
         '#include "cc/paint/record_paint_canvas.h"\n' + budget + '#include "third_party/skia/include/core/SkTextBlob.h"'),
        (canvas, "namespace cc {\n", "namespace cc {\n" + OP_ADMISSION),
        (canvas, "void RecordPaintCanvas::push(Args&&... args) {",
         "void RecordPaintCanvas::push(Args&&... args) {\n"
         "  if (!ArxAdmitCaptureOp<T>(args...)) return;"),
        (controller + ".h", '#include "cc/input/hit_test_opaqueness.h"',
         '#include "cc/input/hit_test_opaqueness.h"\n' + budget),
        (controller + ".h", "namespace blink {\n", "namespace blink {\nclass ForeignLayerDisplayItem;\n"),
        (controller + ".h", "  void CreateAndAppend(const DisplayItemClient& client, Args&&... args) {",
         "  void CreateAndAppend(const DisplayItemClient& client, Args&&... args) {\n"
         "    if constexpr (std::is_same_v<DisplayItemClass, ForeignLayerDisplayItem>) {\n"
         "      if (cc::ArxCaptureRecordingBudget::Active()) { cc::ArxCaptureRecordingBudget::Unsupported(cc::ArxCaptureRecordingBudget::UnsupportedReason::kForeignLayer); return; }\n"
         "    }\n"
         "    if (!cc::ArxCaptureRecordingBudget::Entry(sizeof(DisplayItemClass) + sizeof(ScrollbarDisplayItem))) return;"),
        (controller + ".cc", "  // Reserve capacity.\n", "  // Capture's transient initial vector capacity is charged before reserve.\n"
         "  if (!cc::ArxCaptureRecordingBudget::Entry(4096)) return;\n\n  // Reserve capacity.\n"),
        (controller + ".cc", "wtf_size_t PaintController::BeginSubsequence(const DisplayItemClient& client) {",
         "wtf_size_t PaintController::BeginSubsequence(const DisplayItemClient& client) {\n"
         "  if (!cc::ArxCaptureRecordingBudget::Entry(sizeof(SubsequenceMarkers))) return kNotFound;"),
        (controller + ".cc", "void PaintController::EndSubsequence(wtf_size_t subsequence_index) {",
         "void PaintController::EndSubsequence(wtf_size_t subsequence_index) {\n"
         "  if (cc::ArxCaptureRecordingBudget::Active() && subsequence_index == kNotFound) return;"),
        (chunks, '#include "third_party/blink/renderer/platform/graphics/paint/paint_chunker.h"',
         '#include "third_party/blink/renderer/platform/graphics/paint/paint_chunker.h"\n' + budget),
        (chunks, "void PaintChunker::AppendByMoving(PaintChunk&& chunk) {",
         "void PaintChunker::AppendByMoving(PaintChunk&& chunk) {\n"
         "  if (cc::ArxCaptureRecordingBudget::Active()) { cc::ArxCaptureRecordingBudget::Unsupported(cc::ArxCaptureRecordingBudget::UnsupportedReason::kMoveChunk); return; }"),
        (chunks, "  if (WillCreateNewChunk()) {\n    if (!next_chunk_id_) {",
         "  if (WillCreateNewChunk()) {\n"
         "    if (!cc::ArxCaptureRecordingBudget::Entry(sizeof(PaintChunk))) return false;\n"
         "    if (!next_chunk_id_) {"),
        (chunks, "  bool created_new_chunk = EnsureCurrentChunk(item.GetId(), client);",
         "  bool created_new_chunk = EnsureCurrentChunk(item.GetId(), client);\n"
         "  if (!cc::ArxCaptureRecordingBudget::Good()) return false;"),
        (chunks, "  if (touch_action != TouchAction::kAuto) {",
         "  if (touch_action != TouchAction::kAuto) {\n"
         "    if (!cc::ArxCaptureRecordingBudget::Entry(sizeof(TouchActionRect))) return false;"),
        (chunks, "  if (blocking_wheel) {", "  if (blocking_wheel) {\n"
         "    if (!cc::ArxCaptureRecordingBudget::Entry(sizeof(gfx::Rect))) return false;"),
        (chunks, "  // We should have painted the selection when calling this method.",
         "  if (!cc::ArxCaptureRecordingBudget::Entry(sizeof(LayerSelectionData))) return;\n"
         "  // We should have painted the selection when calling this method."),
        (chunks, "void PaintChunker::RecordAnySelectionWasPainted() {",
         "void PaintChunker::RecordAnySelectionWasPainted() {\n"
         "  if (!cc::ArxCaptureRecordingBudget::Entry(sizeof(LayerSelectionData))) return;"),
        (blink, '#include "third_party/blink/renderer/platform/graphics/paint/paint_record_builder.h"',
         '#include "third_party/blink/renderer/platform/graphics/paint/paint_record_builder.h"\n' + budget +
         '#include "third_party/blink/renderer/core/layout/layout_text.h"'),
        (blink, "    PaintRecordBuilder builder;\n    builder.Context().SetPaintPreviewTracker", PREPAINT +
         "    PaintRecordBuilder builder;\n    builder.Context().SetPaintPreviewTracker"),
        (blink, "    frame_view->PaintOutsideOfLifecycle(builder.Context(), flags,\n                                        CullRect(bounds));",
         "    frame_view->PaintOutsideOfLifecycle(builder.Context(), flags,\n                                        CullRect(bounds));\n"
         "    if (!cc::ArxCaptureRecordingBudget::Good()) return false;"),
        (blink, "    canvas->drawPicture(builder.EndRecording(property_tree_state.Unalias()));\n    return true;",
         "    canvas->drawPicture(builder.EndRecording(property_tree_state.Unalias()));\n"
         "    return cc::ArxCaptureRecordingBudget::Good();"),
    ]
    # Every EnsureCurrentChunk caller that subsequently indexes back() must stop
    # after denied chunk creation. Region/tracked metadata is not admitted yet.
    for signature in CHUNK_FUNCTIONS:
        # Whole-function-specific anchors avoid repeated generic replacements.
        old, new = CHUNK_FUNCTIONS[signature]
        changes.append((chunks, old, new))
    return changes


OP_ADMISSION = r'''
namespace {
template <typename T> bool ArxCaptureArgument(const T&) { return true; }
bool ArxCaptureArgument(const PaintFlags& flags) {
  // Solid and linear-gradient shaders (macOS classic scrollbar tracks, CSS
  // linear-gradient) are plain Skia gradients. Image, record, SkSL and other
  // gradient shaders stay unsupported; each admitted shader is charged 4 KiB.
  const bool shader = flags.HasShader() &&
      flags.getShader()->shader_type() != PaintShader::Type::kColor &&
      flags.getShader()->shader_type() != PaintShader::Type::kLinearGradient;
  if (shader || flags.getImageFilter() || flags.getPathEffect() || flags.getColorFilter() ||
      flags.getLooper())
    return ArxCaptureRecordingBudget::Unsupported(
        ArxCaptureRecordingBudget::UnsupportedReason::kFlags,
        shader | (!!flags.getImageFilter() << 1) | (!!flags.getPathEffect() << 2) |
        (!!flags.getColorFilter() << 3) | (!!flags.getLooper() << 4));
  return !flags.HasShader() || ArxCaptureRecordingBudget::Reference(4096);
}
bool ArxCaptureArgument(const PaintFlags* flags) { return !flags || ArxCaptureArgument(*flags); }
[[maybe_unused]] bool ArxCaptureArgument(PaintFlags* flags) { return !flags || ArxCaptureArgument(*flags); }
bool ArxCaptureArgument(const SkPath& path) {
  return ArxCaptureRecordingBudget::Reference(path.approximateBytesUsed());
}
bool ArxCaptureArgument(const PaintRecord& record) {
  return ArxCaptureRecordingBudget::Reference(record.bytes_used(), record.total_op_count());
}
bool ArxCaptureArgument(const PaintImage& image) {
  if (image.IsDeferredPaintRecord() || image.IsLazyGenerated() || image.ShouldAnimate() || image.HasGainmapInfo())
    return ArxCaptureRecordingBudget::Unsupported(ArxCaptureRecordingBudget::UnsupportedReason::kImageKind,
        image.IsDeferredPaintRecord() | (image.IsLazyGenerated() << 1) |
        (image.ShouldAnimate() << 2) | (image.HasGainmapInfo() << 3));
  const auto info = image.GetSkImageInfo();
  if (info.colorType() == kUnknown_SkColorType)
    return ArxCaptureRecordingBudget::Unsupported(ArxCaptureRecordingBudget::UnsupportedReason::kImageColor);
  return ArxCaptureRecordingBudget::Image(info.width(), info.height(), info.bytesPerPixel());
}
bool ArxCaptureArgument(const sk_sp<SkTextBlob>& blob) {
  if (!blob) return ArxCaptureRecordingBudget::Unsupported(ArxCaptureRecordingBudget::UnsupportedReason::kTextBlob);
  SkTextBlob::Iter iterator(*blob);
  SkTextBlob::Iter::Run run;
  while (iterator.next(&run)) {
    if (run.fGlyphCount < 0 || run.fGlyphCount > 100000) {
      // Overflow-free conservative blob positions/glyph/font-metadata charge.
      return ArxCaptureRecordingBudget::Reference(UINT64_MAX);
    }
    if (!ArxCaptureRecordingBudget::Reference(4096 + static_cast<uint64_t>(run.fGlyphCount) * 64, 1)) return false;
  }
  return true;
}
template <typename T, typename... Args>
bool ArxAdmitCaptureOp(const Args&... args) {
  if (!ArxCaptureRecordingBudget::Active()) return true;
  ArxCaptureRecordingBudget::Operation(static_cast<uint32_t>(T::kType));
  switch (T::kType) {
    case PaintOpType::kClipPath: case PaintOpType::kClipRect: case PaintOpType::kClipRRect:
    case PaintOpType::kConcat: case PaintOpType::kDrawArc: case PaintOpType::kDrawArcLite:
    case PaintOpType::kDrawColor: case PaintOpType::kDrawDRRect: case PaintOpType::kDrawIRect:
    case PaintOpType::kDrawImage: case PaintOpType::kDrawImageRect: case PaintOpType::kDrawLine:
    case PaintOpType::kDrawLineLite: case PaintOpType::kDrawOval: case PaintOpType::kDrawPath:
    case PaintOpType::kDrawRecord: case PaintOpType::kDrawRect: case PaintOpType::kDrawRRect:
    case PaintOpType::kDrawTextBlob: case PaintOpType::kNoop: case PaintOpType::kRestore:
    case PaintOpType::kRotate: case PaintOpType::kSave: case PaintOpType::kSaveLayerAlpha: case PaintOpType::kScale:
    case PaintOpType::kSetMatrix: case PaintOpType::kSetNodeId: case PaintOpType::kTranslate:
      break;
    default: return ArxCaptureRecordingBudget::Unsupported(
        ArxCaptureRecordingBudget::UnsupportedReason::kOperation, static_cast<uint32_t>(T::kType));
  }
  return ArxCaptureRecordingBudget::Entry(sizeof(T) + sizeof(PaintOpBuffer) + sizeof(RecordPaintCanvas)) && (ArxCaptureArgument(args) && ...);
}
}  // namespace
'''

PREPAINT = r'''    // Activate only after lifecycle printing work; all following builders are
    // transient, so denied retention cannot invalidate persistent page caches.
    cc::ArxCaptureRecordingBudget::PaintingScope capture_recording_scope;
    if (cc::ArxCaptureRecordingBudget::Active()) {
      const LayoutObject* root = GetFrame()->GetDocument()->GetLayoutView();
      for (const LayoutObject* object = root; object; object = object->NextInPreOrder(root)) {
        uint64_t depth = 0;
        for (const LayoutObject* parent = object; parent && parent != root; parent = parent->Parent()) {
          if (++depth > 64) { cc::ArxCaptureRecordingBudget::Layout(0, 0, depth); return false; }
        }
        const auto& style = object->Style();
        if (object->IsCanvas() || object->IsVideo() || object->IsEmbeddedObject() ||
            style.HasFilter() || style.HasBackdropFilter() || style.HasCurrentCompositableAnimation()) {
          cc::ArxCaptureRecordingBudget::Unsupported(
              cc::ArxCaptureRecordingBudget::UnsupportedReason::kLayoutContent,
              object->IsCanvas() | (object->IsVideo() << 1) | (object->IsEmbeddedObject() << 2) |
              (style.HasFilter() << 3) | (style.HasBackdropFilter() << 4) |
              (style.HasCurrentCompositableAnimation() << 5)); return false;
        }
        const auto text_length = object->IsText() && !object->IsBR()
            ? To<LayoutText>(object)->OriginalTextLength() : 0;
        if (!cc::ArxCaptureRecordingBudget::Layout(text_length, object->FragmentList().size(), depth)) return false;
      }
    }
'''

# Filled from exact pinned function bodies below, then maintained as explicit
# narrow source anchors. No regex edits to Chromium sources at application time.
CHUNK_FUNCTIONS = {}

CHUNK_FUNCTIONS['bool PaintChunker::AddHitTestDataToCurrentChunk('] = (
    r"""bool PaintChunker::AddHitTestDataToCurrentChunk(
    const PaintChunk::Id& id,
    const DisplayItemClient& client,
    const gfx::Rect& rect,
    TouchAction touch_action,
    bool blocking_wheel,
    cc::HitTestOpaqueness hit_test_opaqueness) {
  CheckNotFinished();
  bool created_new_chunk = EnsureCurrentChunk(id, client);""",
    r"""bool PaintChunker::AddHitTestDataToCurrentChunk(
    const PaintChunk::Id& id,
    const DisplayItemClient& client,
    const gfx::Rect& rect,
    TouchAction touch_action,
    bool blocking_wheel,
    cc::HitTestOpaqueness hit_test_opaqueness) {
  CheckNotFinished();
  if (!cc::ArxCaptureRecordingBudget::Entry(sizeof(HitTestData))) return false;
  bool created_new_chunk = EnsureCurrentChunk(id, client);
  if (!cc::ArxCaptureRecordingBudget::Good()) return false;""",
)

CHUNK_FUNCTIONS['bool PaintChunker::AddRegionCaptureDataToCurrentChunk('] = (
    r"""bool PaintChunker::AddRegionCaptureDataToCurrentChunk(
    const PaintChunk::Id& id,
    const DisplayItemClient& client,
    const RegionCaptureCropId& crop_id,
    const gfx::Rect& rect) {
  CheckNotFinished();
  DCHECK(!crop_id->is_zero());
  bool created_new_chunk = EnsureCurrentChunk(id, client);""",
    r"""bool PaintChunker::AddRegionCaptureDataToCurrentChunk(
    const PaintChunk::Id& id,
    const DisplayItemClient& client,
    const RegionCaptureCropId& crop_id,
    const gfx::Rect& rect) {
  if (cc::ArxCaptureRecordingBudget::Active()) { cc::ArxCaptureRecordingBudget::Unsupported(cc::ArxCaptureRecordingBudget::UnsupportedReason::kRegionCapture); return false; }
  CheckNotFinished();
  DCHECK(!crop_id->is_zero());
  bool created_new_chunk = EnsureCurrentChunk(id, client);
  if (!cc::ArxCaptureRecordingBudget::Good()) return false;""",
)

CHUNK_FUNCTIONS['bool PaintChunker::AddTrackedElementDataToCurrentChunk('] = (
    r"""bool PaintChunker::AddTrackedElementDataToCurrentChunk(
    const PaintChunk::Id& id,
    const DisplayItemClient& client,
    const gfx::Rect& element_paint_rect,
    const TrackedElementSubRects& tracked_element_sub_rects) {
  CheckNotFinished();
  bool created_new_chunk = EnsureCurrentChunk(id, client);""",
    r"""bool PaintChunker::AddTrackedElementDataToCurrentChunk(
    const PaintChunk::Id& id,
    const DisplayItemClient& client,
    const gfx::Rect& element_paint_rect,
    const TrackedElementSubRects& tracked_element_sub_rects) {
  if (cc::ArxCaptureRecordingBudget::Active()) { cc::ArxCaptureRecordingBudget::Unsupported(cc::ArxCaptureRecordingBudget::UnsupportedReason::kTrackedElement); return false; }
  CheckNotFinished();
  bool created_new_chunk = EnsureCurrentChunk(id, client);
  if (!cc::ArxCaptureRecordingBudget::Good()) return false;""",
)

CHUNK_FUNCTIONS['void PaintChunker::CreateScrollHitTestChunk('] = (
    r"""void PaintChunker::CreateScrollHitTestChunk(
    const PaintChunk::Id& id,
    const DisplayItemClient& client,
    const TransformPaintPropertyNode* scroll_translation,
    const gfx::Rect& scroll_hit_test_rect,
    cc::HitTestOpaqueness hit_test_opaqueness) {
#if DCHECK_IS_ON()
  CheckNotFinished();
  if (id.type == DisplayItem::Type::kResizerScrollHitTest ||
      id.type == DisplayItem::Type::kWebPluginHitTest ||
      id.type == DisplayItem::Type::kScrollbarHitTest) {
    // Resizer, plugin, and scrollbar hit tests are only used to prevent
    // composited scrolling and should not have a scroll offset node.
    DCHECK(!scroll_translation);
  } else if (id.type == DisplayItem::Type::kScrollHitTest) {
    // We might not have a scroll_translation node.  This indicates that
    // (due to complex pointer-events cases) we need to do main thread
    // scroll hit testing for this scroller.
    if (scroll_translation) {
      // The scroll offset transform node should have an associated scroll node.
      DCHECK(scroll_translation->ScrollNode());
    }
  } else {
    NOTREACHED();
  }
#endif

  SetWillForceNewChunk();
  bool created_new_chunk = EnsureCurrentChunk(id, client);""",
    r"""void PaintChunker::CreateScrollHitTestChunk(
    const PaintChunk::Id& id,
    const DisplayItemClient& client,
    const TransformPaintPropertyNode* scroll_translation,
    const gfx::Rect& scroll_hit_test_rect,
    cc::HitTestOpaqueness hit_test_opaqueness) {
#if DCHECK_IS_ON()
  CheckNotFinished();
  if (id.type == DisplayItem::Type::kResizerScrollHitTest ||
      id.type == DisplayItem::Type::kWebPluginHitTest ||
      id.type == DisplayItem::Type::kScrollbarHitTest) {
    // Resizer, plugin, and scrollbar hit tests are only used to prevent
    // composited scrolling and should not have a scroll offset node.
    DCHECK(!scroll_translation);
  } else if (id.type == DisplayItem::Type::kScrollHitTest) {
    // We might not have a scroll_translation node.  This indicates that
    // (due to complex pointer-events cases) we need to do main thread
    // scroll hit testing for this scroller.
    if (scroll_translation) {
      // The scroll offset transform node should have an associated scroll node.
      DCHECK(scroll_translation->ScrollNode());
    }
  } else {
    NOTREACHED();
  }
#endif

  SetWillForceNewChunk();
  if (!cc::ArxCaptureRecordingBudget::Entry(sizeof(HitTestData))) return;
  bool created_new_chunk = EnsureCurrentChunk(id, client);
  if (!cc::ArxCaptureRecordingBudget::Good()) return;""",
)


# Exact emitted blocks from the diagnostics-free recording overlay. An update
# can encounter those blocks directly, or the new insertion followed by the old
# insertion when replace_once already matched the still-present original anchor.
# Normalize only these known representations before applying current patches.
_DIAGNOSTICS_FREE_BLOCKS = {
    ('cc/paint/record_paint_canvas.cc', 'namespace cc {'): r"""namespace cc {

namespace {
template <typename T> bool ArxCaptureArgument(const T&) { return true; }
bool ArxCaptureArgument(const PaintFlags& flags) {
  return (!flags.HasShader() && !flags.getImageFilter() && !flags.getPathEffect() &&
          !flags.getColorFilter() && !flags.getLooper()) || ArxCaptureRecordingBudget::Unsupported();
}
bool ArxCaptureArgument(const PaintFlags* flags) { return !flags || ArxCaptureArgument(*flags); }
[[maybe_unused]] bool ArxCaptureArgument(PaintFlags* flags) { return !flags || ArxCaptureArgument(*flags); }
bool ArxCaptureArgument(const SkPath& path) {
  return ArxCaptureRecordingBudget::Reference(path.approximateBytesUsed());
}
bool ArxCaptureArgument(const PaintRecord& record) {
  return ArxCaptureRecordingBudget::Reference(record.bytes_used(), record.total_op_count());
}
bool ArxCaptureArgument(const PaintImage& image) {
  if (image.IsDeferredPaintRecord() || image.IsLazyGenerated() || image.ShouldAnimate() || image.HasGainmapInfo())
    return ArxCaptureRecordingBudget::Unsupported();
  const auto info = image.GetSkImageInfo();
  if (info.colorType() == kUnknown_SkColorType) return ArxCaptureRecordingBudget::Unsupported();
  return ArxCaptureRecordingBudget::Image(info.width(), info.height(), info.bytesPerPixel());
}
bool ArxCaptureArgument(const sk_sp<SkTextBlob>& blob) {
  if (!blob) return ArxCaptureRecordingBudget::Unsupported();
  SkTextBlob::Iter iterator(*blob);
  SkTextBlob::Iter::Run run;
  while (iterator.next(&run)) {
    if (run.fGlyphCount < 0 || run.fGlyphCount > 100000) {
      // Overflow-free conservative blob positions/glyph/font-metadata charge.
      return ArxCaptureRecordingBudget::Reference(UINT64_MAX);
    }
    if (!ArxCaptureRecordingBudget::Reference(4096 + static_cast<uint64_t>(run.fGlyphCount) * 64, 1)) return false;
  }
  return true;
}
template <typename T, typename... Args>
bool ArxAdmitCaptureOp(const Args&... args) {
  if (!ArxCaptureRecordingBudget::Active()) return true;
  switch (T::kType) {
    case PaintOpType::kClipPath: case PaintOpType::kClipRect: case PaintOpType::kClipRRect:
    case PaintOpType::kConcat: case PaintOpType::kDrawArc: case PaintOpType::kDrawArcLite:
    case PaintOpType::kDrawColor: case PaintOpType::kDrawDRRect: case PaintOpType::kDrawIRect:
    case PaintOpType::kDrawImage: case PaintOpType::kDrawImageRect: case PaintOpType::kDrawLine:
    case PaintOpType::kDrawLineLite: case PaintOpType::kDrawOval: case PaintOpType::kDrawPath:
    case PaintOpType::kDrawRecord: case PaintOpType::kDrawRect: case PaintOpType::kDrawRRect:
    case PaintOpType::kDrawTextBlob: case PaintOpType::kNoop: case PaintOpType::kRestore:
    case PaintOpType::kRotate: case PaintOpType::kSave: case PaintOpType::kScale:
    case PaintOpType::kSetMatrix: case PaintOpType::kSetNodeId: case PaintOpType::kTranslate:
      break;
    default: return ArxCaptureRecordingBudget::Unsupported();
  }
  return ArxCaptureRecordingBudget::Entry(sizeof(T) + sizeof(PaintOpBuffer) + sizeof(RecordPaintCanvas)) && (ArxCaptureArgument(args) && ...);
}
}  // namespace
""",
    ('third_party/blink/renderer/platform/graphics/paint/paint_controller.h', '  void CreateAndAppend(const DisplayItemClient& client, Args&&... args) {'): r"""  void CreateAndAppend(const DisplayItemClient& client, Args&&... args) {
    if constexpr (std::is_same_v<DisplayItemClass, ForeignLayerDisplayItem>) {
      if (cc::ArxCaptureRecordingBudget::Active()) { cc::ArxCaptureRecordingBudget::Unsupported(); return; }
    }
    if (!cc::ArxCaptureRecordingBudget::Entry(sizeof(DisplayItemClass) + sizeof(ScrollbarDisplayItem))) return;""",
    ('third_party/blink/renderer/platform/graphics/paint/paint_chunker.cc', 'void PaintChunker::AppendByMoving(PaintChunk&& chunk) {'): r"""void PaintChunker::AppendByMoving(PaintChunk&& chunk) {
  if (cc::ArxCaptureRecordingBudget::Active()) { cc::ArxCaptureRecordingBudget::Unsupported(); return; }""",
    ('third_party/blink/renderer/core/frame/web_local_frame_impl.cc', '    PaintRecordBuilder builder;'): r"""    // Activate only after lifecycle printing work; all following builders are
    // transient, so denied retention cannot invalidate persistent page caches.
    cc::ArxCaptureRecordingBudget::PaintingScope capture_recording_scope;
    if (cc::ArxCaptureRecordingBudget::Active()) {
      const LayoutObject* root = GetFrame()->GetDocument()->GetLayoutView();
      for (const LayoutObject* object = root; object; object = object->NextInPreOrder(root)) {
        uint64_t depth = 0;
        for (const LayoutObject* parent = object; parent && parent != root; parent = parent->Parent()) {
          if (++depth > 64) { cc::ArxCaptureRecordingBudget::Layout(0, 0, depth); return false; }
        }
        const auto& style = object->StyleRef();
        if (object->IsCanvas() || object->IsVideo() || object->IsEmbeddedObject() ||
            style.HasFilter() || style.HasBackdropFilter() || style.HasCurrentCompositableAnimation()) {
          cc::ArxCaptureRecordingBudget::Unsupported(); return false;
        }
        const auto text_length = object->IsText() && !object->IsBR()
            ? To<LayoutText>(object)->OriginalTextLength() : 0;
        if (!cc::ArxCaptureRecordingBudget::Layout(text_length, object->FragmentList().size(), depth)) return false;
      }
    }
    PaintRecordBuilder builder;
    builder.Context().SetPaintPreviewTracker""",
    ('third_party/blink/renderer/platform/graphics/paint/paint_chunker.cc', 'bool PaintChunker::AddRegionCaptureDataToCurrentChunk('): r"""bool PaintChunker::AddRegionCaptureDataToCurrentChunk(
    const PaintChunk::Id& id,
    const DisplayItemClient& client,
    const RegionCaptureCropId& crop_id,
    const gfx::Rect& rect) {
  if (cc::ArxCaptureRecordingBudget::Active()) { cc::ArxCaptureRecordingBudget::Unsupported(); return false; }
  CheckNotFinished();
  DCHECK(!crop_id->is_zero());
  bool created_new_chunk = EnsureCurrentChunk(id, client);
  if (!cc::ArxCaptureRecordingBudget::Good()) return false;""",
    ('third_party/blink/renderer/platform/graphics/paint/paint_chunker.cc', 'bool PaintChunker::AddTrackedElementDataToCurrentChunk('): r"""bool PaintChunker::AddTrackedElementDataToCurrentChunk(
    const PaintChunk::Id& id,
    const DisplayItemClient& client,
    const gfx::Rect& element_paint_rect,
    const TrackedElementSubRects& tracked_element_sub_rects) {
  if (cc::ArxCaptureRecordingBudget::Active()) { cc::ArxCaptureRecordingBudget::Unsupported(); return false; }
  CheckNotFinished();
  bool created_new_chunk = EnsureCurrentChunk(id, client);
  if (!cc::ArxCaptureRecordingBudget::Good()) return false;""",
}


# The flags admission before gradient shaders were admitted. A tree patched with
# it is migrated in place, so the current block is never inserted a second time.
_SHADERLESS_FLAGS = """bool ArxCaptureArgument(const PaintFlags& flags) {
  return (!flags.HasShader() && !flags.getImageFilter() && !flags.getPathEffect() &&
          !flags.getColorFilter() && !flags.getLooper()) || ArxCaptureRecordingBudget::Unsupported(
              ArxCaptureRecordingBudget::UnsupportedReason::kFlags,
              flags.HasShader() | (!!flags.getImageFilter() << 1) | (!!flags.getPathEffect() << 2) |
              (!!flags.getColorFilter() << 3) | (!!flags.getLooper() << 4));
}"""


def _current_flags():
    start = OP_ADMISSION.index("bool ArxCaptureArgument(const PaintFlags& flags) {")
    return OP_ADMISSION[start:OP_ADMISSION.index("\n}\n", start) + 2]


def migrate_recording_diagnostics(source):
    changes = {}
    canvas = source / "cc/paint/record_paint_canvas.cc"
    if canvas.exists():
        content = canvas.read_text()
        if _SHADERLESS_FLAGS in content:
            if content.count(_SHADERLESS_FLAGS) != 1 or _current_flags() in content:
                raise ValueError(f"Ambiguous capture shader migration: {canvas}")
            changes[canvas] = content.replace(_SHADERLESS_FLAGS, _current_flags(), 1)
    for relative, anchor, current in patches():
        legacy = _DIAGNOSTICS_FREE_BLOCKS.get((relative, anchor.splitlines()[0]))
        if legacy is None:
            continue
        path = source / relative
        content = changes.get(path, path.read_text())
        if relative == "cc/paint/record_paint_canvas.cc" and anchor == "namespace cc {\n":
            previous = current.replace("case PaintOpType::kSaveLayerAlpha: ", "")
            duplicate_previous = previous.replace(anchor, current, 1)
            if duplicate_previous in content:
                if content.count(duplicate_previous) != 1:
                    raise ValueError(f"Ambiguous capture layer migration: {path}")
                content = content.replace(duplicate_previous, current, 1)
            elif previous in content:
                if content.count(previous) != 1 or current in content:
                    raise ValueError(f"Ambiguous capture layer migration: {path}")
                content = content.replace(previous, current, 1)
        duplicate = legacy.replace(anchor, current, 1) if anchor in legacy else None
        if duplicate and duplicate != current and duplicate in content:
            if content.count(duplicate) != 1:
                raise ValueError(f"Ambiguous capture diagnostic migration: {path}")
            content = content.replace(duplicate, current, 1)
        elif legacy in content:
            if content.count(legacy) != 1 or current in content:
                raise ValueError(f"Ambiguous capture diagnostic migration: {path}")
            content = content.replace(legacy, current, 1)
        elif current in content:
            if content.count(current) != 1:
                raise ValueError(f"Ambiguous capture diagnostic migration: {path}")
        elif content.count(anchor) != 1:
            raise ValueError(f"Overlay anchor changed in {path}: {anchor[:80]!r}")
        changes[path] = content
    # Validate every known block first, then write only modified files.
    for path, content in changes.items():
        if path.read_text() != content:
            path.write_text(content)
