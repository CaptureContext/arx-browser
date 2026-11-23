ArxScrollResult ScrollReferenceForArxInspection(
    const WebElement& target, const WebDocument& expected_document,
    uint64_t expected_version, int32_t expected_node, ArxScrollAxis axis,
    double delta_css_pixels, bool (*is_current)(void*), void* context) {
  if ((axis != ArxScrollAxis::kHorizontal && axis != ArxScrollAxis::kVertical) ||
      !std::isfinite(delta_css_pixels) || std::abs(delta_css_pixels) > 8192)
    return ArxScrollResult::kInvalidDelta;
  if (!target || !expected_document || !is_current) return ArxScrollResult::kStale;
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
  if (!current()) return ArxScrollResult::kStale;
  document.UpdateStyleAndLayoutForNode(element, DocumentUpdateReason::kScroll);
  if (!current()) return ArxScrollResult::kStale;
  const auto* control = DynamicTo<HTMLFormControlElement>(element);
  if ((control && control->IsDisabledFormControl()) ||
      HasPresentationalRole(*element) || !element->GetLayoutObject() ||
      element->GetLayoutObject()->AbsoluteBoundingBoxRect().IsEmpty())
    return ArxScrollResult::kNotInteractable;

  // All lifecycle work is complete. Re-read every decision from current native
  // state; WebNode::IsContentEditable and InteractionDisallowedReason would
  // flush style again. Cached UsedUserModify covers editable shadow ancestors
  // without introducing another lifecycle gap.
  WebNode ancestor = target;
  for (unsigned depth = 0; ancestor; ++depth) {
    if (depth >= 512) return ArxScrollResult::kLimit;
    const auto* input = DynamicTo<HTMLInputElement>(ancestor.ConstUnwrap<Node>());
    if (input && (input->HasBeenPasswordField() || input->FormControlType() ==
        mojom::blink::FormControlType::kInputPassword || input->FormControlType() ==
        mojom::blink::FormControlType::kInputFile)) return ArxScrollResult::kNotInteractable;
    const auto wrapper = ancestor.DynamicTo<WebElement>();
    const auto* native_ancestor = wrapper ? wrapper.ConstUnwrap<Element>() : nullptr;
    if (native_ancestor && (AriaBoolAttr(*native_ancestor, html_names::kAriaDisabledAttr) ||
                            AriaBoolAttr(*native_ancestor, html_names::kAriaHiddenAttr)))
      return ArxScrollResult::kNotInteractable;
    const auto* style = native_ancestor ? native_ancestor->GetComputedStyle() : nullptr;
    if (style && (style->UsedUserModify() != EUserModify::kReadOnly ||
                  style->Visibility() != EVisibility::kVisible || style->Opacity() <= 0 ||
                  style->IsInert() || style->UsedPointerEvents() == EPointerEvents::kNone ||
                  style->ContentVisibility() == EContentVisibility::kHidden))
      return ArxScrollResult::kNotInteractable;
    ancestor = ancestor.ParentOrShadowHostNode();
  }

  const auto orientation = axis == ArxScrollAxis::kHorizontal
      ? kHorizontalScrollbar : kVerticalScrollbar;
  // Match Chromium's containing-block scroll chain, including positioned and
  // slotted layout. An edge never selects a different outer container.
  LayoutBox* box = element->GetLayoutObject()->EnclosingBox();
  ScrollableArea* area = nullptr;
  for (unsigned depth = 0; box; box = box->ContainingBlock(), ++depth) {
    if (depth >= 512) return ArxScrollResult::kLimit;
    if (&box->GetDocument() != &document) return ArxScrollResult::kStale;
    auto* candidate = box->GetScrollableArea();
    if (candidate &&
        candidate->UserInputScrollable(orientation) &&
        candidate->MaximumScrollOffset(orientation) > candidate->MinimumScrollOffset(orientation)) {
      area = candidate;
      break;
    }
  }
  if (!current()) return ArxScrollResult::kStale;
  if (!area) return ArxScrollResult::kNoContainer;
  const auto& style = box->Style();
  if (style.Visibility() != EVisibility::kVisible || style.Opacity() <= 0 ||
      style.IsInert() || style.UsedPointerEvents() == EPointerEvents::kNone ||
      style.ContentVisibility() == EContentVisibility::kHidden)
    return ArxScrollResult::kNotInteractable;

  const double zoom = IsA<LayoutView>(box) ? frame->LayoutZoomFactor() : style.EffectiveZoom();
  const double minimum = area->MinimumScrollOffset(orientation);
  const double maximum = area->MaximumScrollOffset(orientation);
  ScrollOffset offset = area->GetScrollOffset();
  const double original = axis == ArxScrollAxis::kHorizontal ? offset.x() : offset.y();
  const double requested = original + delta_css_pixels * zoom;
  if (!std::isfinite(zoom) || zoom <= 0 || !std::isfinite(minimum) ||
      !std::isfinite(maximum) || !std::isfinite(original) || !std::isfinite(requested))
    return ArxScrollResult::kInvalidDelta;
  const float destination = std::clamp(requested, minimum, maximum);
  if (!current()) return ArxScrollResult::kStale;
  // Do not invoke the primitive for a no-op: it can interrupt an animator or
  // change scroll-marker state even when no visible movement is required.
  if (destination == original) return ArxScrollResult::kUnchanged;
  if (axis == ArxScrollAxis::kHorizontal) offset.set_x(destination);
  else offset.set_y(destination);
  area->SetScrollOffset(offset, mojom::blink::ScrollType::kProgrammatic,
                        cc::ScrollSourceType::kRelativeScroll, mojom::blink::ScrollBehavior::kInstant);
  // Native offset application may enqueue website scroll handlers. Do not
  // inspect the DOM or claim website completion after issuing the request.
  return ArxScrollResult::kDispatched;
}

