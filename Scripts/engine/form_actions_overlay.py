"""Pinned, direct form setters with atomic reference and control-state checks."""

from .config import PACKAGE


def patches():
    relative = "third_party/blink/renderer/core/exported/web_form_control_element.cc"
    includes = """#include "third_party/blink/public/web/web_form_control_element.h"
#include "third_party/blink/public/web/arx_form_actions.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/renderer/core/dom/document.h"
#include "third_party/blink/renderer/core/dom/node_traversal.h"
#include "third_party/blink/renderer/core/dom/text.h"
#include "third_party/blink/renderer/core/frame/local_frame.h"
#include "third_party/blink/renderer/core/html/forms/html_option_element.h"
#include "third_party/blink/renderer/core/html/forms/html_opt_group_element.h"
#include "third_party/blink/renderer/core/layout/layout_object.h"
#include "third_party/blink/renderer/platform/crypto.h"
"""
    return [
        (relative, '#include "third_party/blink/public/web/web_form_control_element.h"', includes),
        (relative, "void WebFormControlElement::SetValue(const WebString& value, bool send_events) {",
         (PACKAGE / "Native/inspection/form_action_helper.inc").read_text()
         + "void WebFormControlElement::SetValue(const WebString& value, bool send_events) {"),
        ("third_party/blink/public/BUILD.gn", '    "web/web_form_control_element.h",',
         '    "web/web_form_control_element.h",\n    "web/arx_form_actions.h",'),
    ]
