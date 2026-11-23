"""Pinned explicit-reference checked state and multiple-select values."""

from .config import PACKAGE

INCLUDES = '''#include "third_party/blink/public/web/arx_form_state_actions.h"

#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_element.h"
#include "third_party/blink/renderer/core/dom/document.h"
#include "third_party/blink/renderer/core/dom/element.h"
#include "third_party/blink/renderer/core/frame/local_frame.h"
#include "third_party/blink/renderer/core/html/forms/html_input_element.h"
#include "third_party/blink/renderer/core/html/forms/html_option_element.h"
#include "third_party/blink/renderer/core/html/forms/html_select_element.h"
#include "third_party/blink/renderer/core/layout/layout_object.h"
#include "third_party/blink/renderer/platform/heap/collection_support/heap_vector.h"
#include "third_party/blink/renderer/platform/heap/persistent.h"
#include "third_party/blink/renderer/platform/wtf/hash_map.h"
#include "third_party/blink/renderer/platform/wtf/hash_set.h"
#include "third_party/blink/renderer/platform/wtf/text/wtf_string.h"

'''


def patches():
    # Upstream anchors only, so no other overlay's inserted text is split.
    return [
        ("third_party/blink/renderer/core/input/build.gni", '  "pointer_event_manager.cc",',
         '  "arx_form_state_actions.cc",\n  "pointer_event_manager.cc",'),
        ("third_party/blink/public/BUILD.gn", '    "web/web_view_client.h",',
         '    "web/arx_form_state_actions.h",\n    "web/web_view_client.h",'),
    ]


def write_sources(source):
    """Whole files, rewritten on every application, so edits never double-apply."""
    directory = source / "third_party/blink/renderer/core/input"
    (directory / "arx_form_state_actions.cc").write_text(
        INCLUDES + (PACKAGE / "Native/inspection/form_state_action_impl.inc").read_text())
    public = source / "third_party/blink/public/web/arx_form_state_actions.h"
    public.write_text((PACKAGE / "Native/inspection/form_state_action_contract.h").read_text())
