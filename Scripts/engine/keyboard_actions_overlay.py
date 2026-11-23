"""Pinned explicit-reference typing and key chords over the guarded keypress hooks."""

from .config import PACKAGE

INCLUDES = '''#include "third_party/blink/public/web/arx_keyboard_actions.h"

#include <optional>

#include "third_party/blink/public/common/input/web_keyboard_event.h"
#include "third_party/blink/public/web/arx_form_actions.h"
#include "third_party/blink/public/web/arx_keypress_actions.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_element.h"
#include "third_party/blink/renderer/core/dom/document.h"
#include "third_party/blink/renderer/core/dom/element.h"
#include "third_party/blink/renderer/core/dom/focus_params.h"
#include "third_party/blink/renderer/core/editing/editing_utilities.h"
#include "third_party/blink/renderer/core/editing/frame_selection.h"
#include "third_party/blink/renderer/core/editing/position.h"
#include "third_party/blink/renderer/core/editing/selection_template.h"
#include "third_party/blink/renderer/core/editing/set_selection_options.h"
#include "third_party/blink/renderer/core/events/keyboard_event.h"
#include "third_party/blink/renderer/core/frame/local_dom_window.h"
#include "third_party/blink/renderer/core/frame/local_frame.h"
#include "third_party/blink/renderer/core/html/forms/html_input_element.h"
#include "third_party/blink/renderer/core/html/forms/html_text_area_element.h"
#include "third_party/blink/renderer/core/html/forms/text_control_element.h"
#include "third_party/blink/renderer/core/input/arx_keypress_guard.h"
#include "third_party/blink/renderer/core/layout/layout_object.h"
#include "third_party/blink/renderer/platform/heap/persistent.h"
#include "third_party/blink/renderer/platform/wtf/text/wtf_string.h"
#include "third_party/blink/renderer/platform/wtf/vector.h"
#include "third_party/icu/source/common/unicode/utf16.h"
#include "ui/events/keycodes/dom/dom_key.h"
#include "ui/events/keycodes/keyboard_codes.h"

'''


def patches():
    # Upstream anchors only, so no other overlay's inserted text is split.
    return [
        ("third_party/blink/renderer/core/input/build.gni", '  "mouse_event_manager.cc",',
         '  "arx_keyboard_actions.cc",\n  "mouse_event_manager.cc",'),
        ("third_party/blink/public/BUILD.gn", '    "web/web_view.h",',
         '    "web/arx_keyboard_actions.h",\n    "web/web_view.h",'),
    ]


def write_sources(source):
    """Whole files, rewritten on every application, so edits never double-apply."""
    directory = source / "third_party/blink/renderer/core/input"
    (directory / "arx_keyboard_actions.cc").write_text(
        INCLUDES + (PACKAGE / "Native/inspection/keyboard_action_impl.inc").read_text())
    public = source / "third_party/blink/public/web/arx_keyboard_actions.h"
    public.write_text((PACKAGE / "Native/inspection/keyboard_action_contract.h").read_text())
