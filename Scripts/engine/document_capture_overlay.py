"""Stage the disabled full-document path and explicit owned native fixture."""

from pathlib import Path
import shutil

from .document_capture_prototype import PROTOTYPE, patches
from .overlay import replace_once


def apply(source: Path):
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
