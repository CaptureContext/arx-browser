"""Pinned, read-only document revision access and opt-in renderer inspection."""

import shutil

from .config import PACKAGE
from . import form_actions_overlay, scroll_actions_overlay, keypress_actions_overlay, pointer_actions_overlay, keyboard_actions_overlay, form_state_actions_overlay
from .overlay import replace_once

DOCUMENT_HEADER = '''#ifndef THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_INSPECTION_H_
#define THIRD_PARTY_BLINK_PUBLIC_WEB_ARX_INSPECTION_H_

#include <cstdint>
#include "third_party/blink/public/platform/web_common.h"

namespace blink {
class WebDocument;
class WebElement;
enum class ArxReferenceClickResult { kStale, kNotInteractable, kDispatched };
// Same-task validation after all lifecycle work, immediately before dispatch.
// The callback must only validate retained authority; it must not run script.
BLINK_EXPORT ArxReferenceClickResult ClickReferenceForArxInspection(
    const WebElement& element, const WebDocument& document,
    uint64_t expected_version, int32_t expected_node,
    bool (*is_current)(void*), void* context);
// Conservative synchronous DOM mutation identity. Read on the renderer thread.
BLINK_EXPORT uint64_t DomTreeVersionForArxInspection(const WebDocument& document);
}  // namespace blink
#endif
'''


CLICK_HELPER = '''ArxReferenceClickResult ClickReferenceForArxInspection(
    const WebElement& target, const WebDocument& expected_document,
    uint64_t expected_version, int32_t expected_node,
    bool (*is_current)(void*), void* context) {
  if (!target || !expected_document || !is_current)
    return ArxReferenceClickResult::kStale;
  auto* element = const_cast<Element*>(target.ConstUnwrap<Element>());
  Document& document = element->GetDocument();
  LocalFrame* frame = document.GetFrame();
  const auto current = [&]() {
    return frame && document.IsActive() && document.GetFrame() == frame &&
        frame->GetDocument() == &document && target.GetDocument() == expected_document &&
        document.DomTreeVersion() == expected_version && element->isConnected() &&
        WebNode::FromDomNodeId(expected_node) == target && is_current(context) &&
        document.DomTreeVersion() == expected_version;
  };
  if (!current()) return ArxReferenceClickResult::kStale;
  const auto disallowed = target.InteractionDisallowedReason(/*check_aria=*/true);
  if (!current()) return ArxReferenceClickResult::kStale;
  if (disallowed.has_value()) return ArxReferenceClickResult::kNotInteractable;
  document.UpdateStyleAndLayoutTreeForElement(element, DocumentUpdateReason::kInput);
  if (!current()) return ArxReferenceClickResult::kStale;
  if (!element->GetLayoutObject() ||
      element->GetLayoutObject()->AbsoluteBoundingBoxRect().IsEmpty())
    return ArxReferenceClickResult::kNotInteractable;
  // Hidden/transparent ancestors and content-visibility locks are rejected,
  // including ancestors across author and UA shadow boundaries.
  WebNode ancestor = target;
  for (size_t depth = 0; ancestor; ++depth) {
    if (depth >= 512) return ArxReferenceClickResult::kNotInteractable;
    const auto wrapper = ancestor.DynamicTo<WebElement>();
    const auto* style = wrapper ? wrapper.ConstUnwrap<Element>()->GetComputedStyle() : nullptr;
    if (style && (style->Visibility() != EVisibility::kVisible ||
                  style->Opacity() <= 0 || style->IsInert() ||
                  style->UsedPointerEvents() == EPointerEvents::kNone ||
                  style->ContentVisibility() == EContentVisibility::kHidden))
      return ArxReferenceClickResult::kNotInteractable;
    ancestor = ancestor.ParentOrShadowHostNode();
  }
  // No layout, script, IPC, focus, or transient activation between this final
  // ownership/version check and the first dispatched accessibility event.
  if (!current()) return ArxReferenceClickResult::kStale;
  element->DispatchSimulatedClick(nullptr, SimulatedClickCreationScope::kFromAccessibility);
  return ArxReferenceClickResult::kDispatched;
}

'''

def patches():
    return [
        (
            "third_party/blink/renderer/core/exported/web_element.cc",
            '#include "third_party/blink/public/web/web_element.h"',
            '#include "third_party/blink/public/web/web_element.h"\n'
            '#include "third_party/blink/public/web/web_document.h"\n'
            '#include "third_party/blink/public/web/arx_inspection.h"',
        ),
        (
            "third_party/blink/renderer/core/exported/web_element.cc",
            "void WebElement::PasteText(const WebString& text,",
            CLICK_HELPER + "void WebElement::PasteText(const WebString& text,",
        ),
        (
            "third_party/blink/public/BUILD.gn",
            '    "web/web_document.h",',
            '    "web/web_document.h",\n    "web/arx_inspection.h",',
        ),
        (
            "third_party/blink/renderer/core/exported/web_document.cc",
            '#include "third_party/blink/public/web/web_document.h"',
            '#include "third_party/blink/public/web/web_document.h"\n'
            '#include "third_party/blink/public/web/arx_inspection.h"',
        ),
        (
            "third_party/blink/renderer/core/exported/web_document.cc",
            "const DocumentToken& WebDocument::Token() const {",
            "uint64_t DomTreeVersionForArxInspection(const WebDocument& document) {\n"
            "  return document.ConstUnwrap<Document>()->DomTreeVersion();\n"
            "}\n\nconst DocumentToken& WebDocument::Token() const {",
        ),
        (
            "chrome/renderer/chrome_content_renderer_client.cc",
            '#include "chrome/renderer/chrome_content_renderer_client.h"',
            '#include "chrome/renderer/chrome_content_renderer_client.h"\n'
            '#if BUILDFLAG(IS_MAC)\n'
            '#include "components/arx_inspection/inspector.h"\n'
            '#endif',
        ),
        (
            "chrome/renderer/chrome_content_renderer_client.cc",
            "void ChromeContentRendererClient::RenderFrameCreated(\n"
            "    content::RenderFrame* render_frame) {",
            "void ChromeContentRendererClient::RenderFrameCreated(\n"
            "    content::RenderFrame* render_frame) {\n"
            "#if BUILDFLAG(IS_MAC)\n"
            "  new arx::inspection::Inspector(render_frame);\n"
            "#endif",
        ),
        (
            "chrome/renderer/BUILD.gn",
            '  deps = [\n    ":process_state",',
            '  deps = [\n    "//components/arx_inspection:renderer",\n'
            '    ":process_state",',
        ),
    ] + form_actions_overlay.patches() + scroll_actions_overlay.patches() + keypress_actions_overlay.patches() + (
        pointer_actions_overlay.patches() + keyboard_actions_overlay.patches()
        + form_state_actions_overlay.patches())


def apply(source):
    keypress_actions_overlay.upgrade_previous(source)
    for relative, old, new in patches():
        replace_once(source / relative, old, new)
    header = source / "third_party/blink/public/web/arx_inspection.h"
    header.parent.mkdir(parents=True, exist_ok=True)
    header.write_text(DOCUMENT_HEADER)
    (header.parent / "arx_form_actions.h").write_text(
        (PACKAGE / "Native/inspection/form_action_contract.h").read_text())
    (header.parent / "arx_scroll_actions.h").write_text(
        (PACKAGE / "Native/inspection/scroll_action_contract.h").read_text())
    keypress_actions_overlay.write_guard(source)
    pointer_actions_overlay.write_sources(source)
    keyboard_actions_overlay.write_sources(source)
    form_state_actions_overlay.write_sources(source)
    destination = source / "components/arx_inspection"
    destination.mkdir(parents=True, exist_ok=True)
    for path in (PACKAGE / "Native/inspection").iterdir():
        if path.suffix in {".h", ".cc", ".mojom", ".gn"}:
            shutil.copy2(path, destination / path.name)
