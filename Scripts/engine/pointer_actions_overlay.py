"""Pinned explicit-reference pointer input: hover, clicks and in-renderer drags."""

from .config import PACKAGE

CAPTURE = '#include "third_party/blink/renderer/core/input/arx_pointer_drag.h"\n'

CAPTURE_HEADER = '''#ifndef THIRD_PARTY_BLINK_RENDERER_CORE_INPUT_ARX_POINTER_DRAG_H_
#define THIRD_PARTY_BLINK_RENDERER_CORE_INPUT_ARX_POINTER_DRAG_H_

#include "third_party/blink/public/common/page/drag_operation.h"
#include "third_party/blink/renderer/core/core_export.h"

namespace blink {
class WebDragData;
// True when an explicit Arx pointer action on this thread took the drag; the
// widget then must not start a platform drag session.
CORE_EXPORT bool ArxCapturePointerDrag(const WebDragData&, DragOperationsMask);
}  // namespace blink
#endif
'''

INCLUDES = '''#include "third_party/blink/public/web/arx_pointer_actions.h"

#include <cmath>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "third_party/blink/public/common/input/web_coalesced_input_event.h"
#include "third_party/blink/public/common/input/web_mouse_event.h"
#include "third_party/blink/public/platform/web_drag_data.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_element.h"
#include "third_party/blink/renderer/core/dom/document.h"
#include "third_party/blink/renderer/core/dom/element.h"
#include "third_party/blink/renderer/core/frame/local_frame.h"
#include "third_party/blink/renderer/core/frame/local_frame_view.h"
#include "third_party/blink/renderer/core/frame/web_frame_widget_impl.h"
#include "third_party/blink/renderer/core/frame/web_local_frame_impl.h"
#include "third_party/blink/renderer/core/html/forms/html_input_element.h"
#include "third_party/blink/renderer/core/html/forms/html_label_element.h"
#include "third_party/blink/renderer/core/html/forms/html_select_element.h"
#include "third_party/blink/renderer/core/input/arx_pointer_drag.h"
#include "third_party/blink/renderer/core/layout/hit_test_location.h"
#include "third_party/blink/renderer/core/layout/hit_test_request.h"
#include "third_party/blink/renderer/core/layout/hit_test_result.h"
#include "third_party/blink/renderer/platform/heap/persistent.h"
#include "ui/latency/latency_info.h"

'''


def patches():
    widget = "third_party/blink/renderer/core/frame/web_frame_widget_impl.cc"
    return [
        (widget, '#include "third_party/blink/renderer/core/frame/web_frame_widget_impl.h"',
         '#include "third_party/blink/renderer/core/frame/web_frame_widget_impl.h"\n' + CAPTURE),
        # An explicit pointer drag completes inside the renderer; the browser
        # never starts a platform drag session for it.
        (widget, "  doing_drag_and_drop_ = true;\n  if (drag_and_drop_disabled_) {",
         "  doing_drag_and_drop_ = true;\n"
         "  if (ArxCapturePointerDrag(drag_data, operations_allowed)) return;\n"
         "  if (drag_and_drop_disabled_) {"),
        # An upstream anchor after the keypress block, which stays intact.
        ("third_party/blink/renderer/core/input/build.gni", '  "keyboard_event_manager.h",',
         '  "keyboard_event_manager.h",\n  "arx_pointer_actions.cc",\n  "arx_pointer_drag.h",'),
        ("third_party/blink/public/BUILD.gn", '    "web/web_widget.h",',
         '    "web/web_widget.h",\n    "web/arx_pointer_actions.h",'),
    ]


def write_sources(source):
    """Whole files, rewritten on every application, so edits never double-apply."""
    directory = source / "third_party/blink/renderer/core/input"
    (directory / "arx_pointer_drag.h").write_text(CAPTURE_HEADER)
    (directory / "arx_pointer_actions.cc").write_text(
        INCLUDES + (PACKAGE / "Native/inspection/pointer_action_impl.inc").read_text())
    public = source / "third_party/blink/public/web/arx_pointer_actions.h"
    public.write_text((PACKAGE / "Native/inspection/pointer_action_contract.h").read_text())
