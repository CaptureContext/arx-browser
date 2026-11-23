"""Prepare opt-in source copies for the unexposed full-document experiment.

This module is intentionally absent from engine.overlay and artifact inputs.
Never apply it to the shared configured engine checkout during prototype work.
"""

from pathlib import Path
import shutil

from .config import PACKAGE, SOURCE
from .overlay import replace_once
from .document_capture_budget_overlay import patches as budget_patches


PROTOTYPE = PACKAGE / "Prototypes/DocumentCapture"
MARKER = ".arx-document-capture-prototype"
MARKER_CONTENT = "isolated-source-copy\n"


def patches():
    from .document_recording_overlay import patches as recording_patches
    from .document_raster_overlay import patches as raster_patches
    return [
        (
            "third_party/blink/public/web/web_local_frame.h",
            "  virtual gfx::Size DocumentSize() const = 0;",
            "  virtual gfx::Size DocumentSize() const = 0;\n"
            "  // Arx prototype: exact snapped layout rect, including negative overflow.\n"
            "  virtual gfx::Rect DocumentRectForArxCapture() const = 0;",
        ),
        (
            "third_party/blink/renderer/core/frame/web_local_frame_impl.h",
            "  gfx::Size DocumentSize() const override;",
            "  gfx::Size DocumentSize() const override;\n"
            "  gfx::Rect DocumentRectForArxCapture() const override;",
        ),
        (
            "third_party/blink/renderer/core/frame/web_local_frame_impl.cc",
            "bool WebLocalFrameImpl::HasVisibleContent() const {",
            "gfx::Rect WebLocalFrameImpl::DocumentRectForArxCapture() const {\n"
            "  if (!GetFrameView() || !GetFrameView()->GetLayoutView())\n"
            "    return gfx::Rect();\n"
            "  return ToPixelSnappedRect(GetFrameView()->GetLayoutView()->DocumentRect());\n"
            "}\n\n"
            "bool WebLocalFrameImpl::HasVisibleContent() const {",
        ),
        (
            "chrome/renderer/chrome_content_renderer_client.cc",
            "#include \"components/paint_preview/renderer/paint_preview_recorder_impl.h\"",
            "#include \"components/paint_preview/renderer/paint_preview_recorder_impl.h\"\n"
            "#if BUILDFLAG(IS_MAC)\n"
            "#include \"components/paint_preview/arx/document_recorder.h\"\n"
            "#endif",
        ),
        (
            "chrome/renderer/chrome_content_renderer_client.cc",
            "  new paint_preview::PaintPreviewRecorderImpl(render_frame);",
            "  new paint_preview::PaintPreviewRecorderImpl(render_frame);\n"
            "#if BUILDFLAG(IS_MAC)\n"
            "  new arx::document::DocumentRecorder(render_frame);\n"
            "#endif",
        ),
        (
            "chrome/renderer/BUILD.gn",
            '    deps += [ "//components/paint_preview/renderer" ]',
            '    deps += [ "//components/paint_preview/renderer" ]\n'
            '    if (is_mac) {\n'
            '      deps += [ "//components/paint_preview/arx:renderer" ]\n'
            '    }',
        ),
    ] + budget_patches() + recording_patches() + raster_patches()


def apply(source: Path):
    source = source.resolve()
    if source == SOURCE.resolve():
        raise ValueError("Prototype cannot mutate the configured shared engine source")
    marker = source / MARKER
    if not marker.is_file() or marker.read_text() != MARKER_CONTENT:
        raise ValueError("Prototype requires a marked isolated source copy")
    from .document_recording_overlay import migrate_recording_diagnostics
    migrate_recording_diagnostics(source)
    for relative, old, new in patches():
        replace_once(source / relative, old, new)
    shutil.copy2(PROTOTYPE / "cc/arx_capture_recording_budget.h", source / "cc/paint/arx_capture_recording_budget.h")
    utility = source / "components/services/paint_preview_compositor"
    for name in ["raster_allocator", "raster_surface_budget"]:
        shutil.copy2(PROTOTYPE / (name + ".h"), utility / ("arx_" + name + ".h"))
    destination = source / "components/paint_preview/arx"
    destination.mkdir(parents=True, exist_ok=True)
    for path in PROTOTYPE.iterdir():
        if path.suffix in {".h", ".cc", ".mojom", ".gn"}:
            shutil.copy2(path, destination / path.name)
