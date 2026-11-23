"""Pinned atomic explicit-reference nearest-container scroll helper."""

from .config import PACKAGE


def patches():
    relative = "third_party/blink/renderer/core/exported/web_element.cc"
    return [
        (relative, '#include <optional>',
         '#include <optional>\n#include <cmath>\n'
         '#include "third_party/blink/public/web/arx_scroll_actions.h"\n'
         '#include "third_party/blink/renderer/core/layout/layout_view.h"\n'
         '#include "third_party/blink/renderer/core/html/forms/html_input_element.h"\n'
         '#include "third_party/blink/renderer/core/paint/paint_layer_scrollable_area.h"\n'),
        (relative, "bool WebElement::SetScrollOffset(const gfx::Vector2dF& offset) {",
         (PACKAGE / "Native/inspection/scroll_action_helper.inc").read_text()
         + "bool WebElement::SetScrollOffset(const gfx::Vector2dF& offset) {"),
        ("third_party/blink/public/BUILD.gn", '    "web/web_element.h",',
         '    "web/web_element.h",\n    "web/arx_scroll_actions.h",'),
    ]
