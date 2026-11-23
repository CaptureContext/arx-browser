"""Prototype-only playback admission before Paint Preview image conversion."""


def patches():
    return [
        ("components/paint_preview/renderer/paint_preview_recorder_utils.h",
         "                                              const gfx::Rect& bounds);",
         "                                              const gfx::Rect& bounds,\n"
         "    const base::RepeatingCallback<bool(const cc::PaintOp&)>& should_continue = {});"),
        ("components/paint_preview/renderer/paint_preview_recorder_utils.cc",
         "  explicit OpConverterAndTracker(PaintPreviewTracker* tracker)\n      : tracker_(tracker) {}",
         "  explicit OpConverterAndTracker(PaintPreviewTracker* tracker,\n"
         "      const base::RepeatingCallback<bool(const cc::PaintOp&)>& should_continue)\n"
         "      : tracker_(tracker), should_continue_(should_continue) {}\n"
         "  bool failed() const { return failed_; }"),
        ("components/paint_preview/renderer/paint_preview_recorder_utils.cc",
         "    converted_op_.emplace<std::monostate>();",
         "    converted_op_.emplace<std::monostate>();\n"
         "    if (failed_ || (should_continue_ && !should_continue_.Run(op))) {\n"
         "      failed_ = true;\n"
         "      return nullptr;\n"
         "    }"),
        ("components/paint_preview/renderer/paint_preview_recorder_utils.cc",
         "  auto sk_image = paint_image.GetSwSkImage();",
         "  auto sk_image = paint_image.GetSwSkImage();\n"
         "  if (!sk_image) return paint_image;"),
        ("components/paint_preview/renderer/paint_preview_recorder_utils.cc",
         "          return &std::get<cc::DrawImageOp>(converted_op_);",
         "          if (should_continue_ &&\n"
         "              std::get<cc::DrawImageOp>(converted_op_).image.IsTextureBacked()) {\n"
         "            failed_ = true;\n"
         "            return nullptr;\n"
         "          }\n"
         "          return &std::get<cc::DrawImageOp>(converted_op_);"),
        ("components/paint_preview/renderer/paint_preview_recorder_utils.cc",
         "          return &std::get<cc::DrawImageRectOp>(converted_op_);",
         "          if (should_continue_ &&\n"
         "              std::get<cc::DrawImageRectOp>(converted_op_).image.IsTextureBacked()) {\n"
         "            failed_ = true;\n"
         "            return nullptr;\n"
         "          }\n"
         "          return &std::get<cc::DrawImageRectOp>(converted_op_);"),
        ("components/paint_preview/renderer/paint_preview_recorder_utils.cc",
         "  raw_ptr<PaintPreviewTracker> tracker_;",
         "  raw_ptr<PaintPreviewTracker> tracker_;\n"
         "  base::RepeatingCallback<bool(const cc::PaintOp&)> should_continue_;\n"
         "  bool failed_ = false;"),
        ("components/paint_preview/renderer/paint_preview_recorder_utils.cc",
         "                                              const gfx::Rect& bounds) {",
         "                                              const gfx::Rect& bounds,\n"
         "    const base::RepeatingCallback<bool(const cc::PaintOp&)>& should_continue) {"),
        ("components/paint_preview/renderer/paint_preview_recorder_utils.cc",
         "  OpConverterAndTracker converter_and_tracker(tracker);",
         "  OpConverterAndTracker converter_and_tracker(tracker, should_continue);"),
        ("components/paint_preview/renderer/paint_preview_recorder_utils.cc",
         "  if (!skp || skp->cullRect().width() == 0 || skp->cullRect().height() == 0)",
         "  if (converter_and_tracker.failed() || !skp ||\n"
         "      skp->cullRect().width() == 0 || skp->cullRect().height() == 0)"),
    ]
