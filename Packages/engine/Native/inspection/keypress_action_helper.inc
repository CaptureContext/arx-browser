namespace {
struct ArxKeyDefinition {
  int dom_key = 0;
  int virtual_key = 0;
  UChar text[3] = {};
  bool character = false;
};
bool ArxDefineKey(const String& key, ArxKeyDefinition* output) {
  // No modifiers, physical key/code claims, auto-repeat, composition, shortcuts,
  // Tab/focus navigation or Escape/dialog behavior is inferred from this key.
  struct Named { const char* name; int dom; int code; };
  const Named named[] = {
    {"Backspace", ui::DomKey::BACKSPACE, ui::VKEY_BACK},
    {"Delete", ui::DomKey::DEL, ui::VKEY_DELETE},
    {"ArrowLeft", ui::DomKey::ARROW_LEFT, ui::VKEY_LEFT},
    {"ArrowRight", ui::DomKey::ARROW_RIGHT, ui::VKEY_RIGHT},
    {"ArrowUp", ui::DomKey::ARROW_UP, ui::VKEY_UP},
    {"ArrowDown", ui::DomKey::ARROW_DOWN, ui::VKEY_DOWN},
    {"Home", ui::DomKey::HOME, ui::VKEY_HOME},
    {"End", ui::DomKey::END, ui::VKEY_END},
    {"Enter", ui::DomKey::ENTER, ui::VKEY_RETURN},
  };
  for (const auto& value : named) {
    if (key != value.name) continue;
    output->dom_key = value.dom;
    output->virtual_key = value.code;
    if (value.code == ui::VKEY_RETURN) output->text[0] = '\r';
    return true;
  }
  // Exactly one Unicode scalar, never a control, line separator or surrogate.
  if (key.empty() || key.length() > 2) return false;
  uint32_t scalar = key[0];
  if (key.length() == 2) {
    if (scalar < 0xd800 || scalar > 0xdbff || key[1] < 0xdc00 || key[1] > 0xdfff) return false;
    scalar = 0x10000 + ((scalar - 0xd800) << 10) + key[1] - 0xdc00;
  } else if (scalar >= 0xd800 && scalar <= 0xdfff) return false;
  if (scalar < 0x20 || (scalar >= 0x7f && scalar <= 0x9f) ||
      scalar == 0x2028 || scalar == 0x2029 ||
      (scalar & 0xffff) >= 0xfffe) return false;
  output->dom_key = ui::DomKey::FromCharacter(scalar);
  output->character = true;
  for (unsigned i = 0; i < key.length(); ++i) output->text[i] = key[i];
  // keyCode/code are deliberately not guessed from a keyboard layout.
  return true;
}
}  // namespace

ArxFormBaselineStatus CaptureKeypressBaselineForArxInspection(
    const WebElement& target, ArxKeypressBaseline* output) {
  if (!target || !output) return ArxFormBaselineStatus::kUnsupported;
  auto* control = const_cast<TextControlElement*>(DynamicTo<TextControlElement>(target.ConstUnwrap<Node>()));
  if (!control) return ArxFormBaselineStatus::kUnsupported;
  Document& document = control->GetDocument();
  LocalFrame* frame = document.GetFrame();
  if (!frame || document.InDesignMode() || IsSpatialNavigationEnabled(frame) || document.FocusedElement() != control ||
      frame->GetInputMethodController().HasComposition() ||
      frame->GetInputMethodController().GetActiveEditContext() ||
      control->FastHasAttribute(html_names::kListAttr)) return ArxFormBaselineStatus::kUnsupported;
  ArxKeypressBaseline value;
  const auto status = CaptureFormBaselineForArxInspection(target, &value.control);
  if (status != ArxFormBaselineStatus::kAvailable) return status;
  if (value.control.kind < 1 || value.control.kind > 3 || value.control.readonly || value.control.disabled)
    return ArxFormBaselineStatus::kUnsupported;
  WebNode ancestor = target;
  for (unsigned depth = 0; ancestor; ++depth) {
    if (depth >= 512) return ArxFormBaselineStatus::kUnsupported;
    const auto wrapper = ancestor.DynamicTo<WebElement>();
    if (wrapper && wrapper.ConstUnwrap<Element>()->FastHasAttribute(html_names::kFocusgroupAttr))
      return ArxFormBaselineStatus::kUnsupported;
    ancestor = ancestor.ParentOrShadowHostNode();
  }
  const auto& selection = frame->Selection().GetSelectionInDomTree();
  if (selection.IsNone() || EnclosingTextControl(selection.Anchor()) != control ||
      EnclosingTextControl(selection.Focus()) != control) return ArxFormBaselineStatus::kUnsupported;
  const auto anchor = selection.Anchor(), focus = selection.Focus();
  value.anchor_node = WebNode(anchor.AnchorNode()).GetDomNodeId();
  value.focus_node = WebNode(focus.AnchorNode()).GetDomNodeId();
  value.anchor_type = static_cast<uint32_t>(anchor.AnchorType());
  value.focus_type = static_cast<uint32_t>(focus.AnchorType());
  value.anchor_offset = anchor.IsOffsetInAnchor() ? anchor.OffsetInContainerNode() : 0;
  value.focus_offset = focus.IsOffsetInAnchor() ? focus.OffsetInContainerNode() : 0;
  value.affinity = static_cast<uint32_t>(selection.Affinity());
  value.directional = frame->Selection().IsDirectional();
  *output = value;
  return ArxFormBaselineStatus::kAvailable;
}

ArxKeypressResult PerformKeypressForArxInspection(
    const WebElement& target, const WebDocument& expected_document,
    uint64_t expected_version, int32_t expected_node,
    const ArxKeypressBaseline& baseline, const WebString& payload,
    bool (*is_current)(void*), void* context) {
  if (!target || !expected_document || !is_current) return ArxKeypressResult::kStale;
  if (ArxKeypressGuard::Busy()) return ArxKeypressResult::kBusy;
  ArxKeyDefinition key;
  const String key_text = payload;
  if (!ArxDefineKey(key_text, &key)) return ArxKeypressResult::kInvalidKey;
  auto* element = const_cast<Element*>(target.ConstUnwrap<Element>());
  Document& document = element->GetDocument();
  LocalFrame* frame = document.GetFrame();
  const auto identity = [&]() {
    return frame && document.IsActive() && document.GetFrame() == frame &&
        frame->GetDocument() == &document && target.GetDocument() == expected_document &&
        element->isConnected() && WebNode::FromDomNodeId(expected_node) == target && is_current(context);
  };
  const auto bound = [&]() {
    if (!identity() || document.DomTreeVersion() != expected_version) return false;
    ArxKeypressBaseline now;
    return CaptureKeypressBaselineForArxInspection(target, &now) == ArxFormBaselineStatus::kAvailable && now == baseline;
  };
  if (!bound()) return ArxKeypressResult::kStale;
  const auto disallowed = target.InteractionDisallowedReason(/*check_aria=*/true);
  document.UpdateStyleAndLayoutTreeForElement(element, DocumentUpdateReason::kInput);
  if (!bound()) return ArxKeypressResult::kStale;
  if (disallowed.has_value() || !element->GetLayoutObject() ||
      element->GetLayoutObject()->AbsoluteBoundingBoxRect().IsEmpty()) return ArxKeypressResult::kNotInteractable;
  // Same visibility/protected-ancestry policy as form replacement.
  WebNode ancestor = target;
  for (unsigned depth = 0; ancestor; ++depth) {
    if (depth >= 512) return ArxKeypressResult::kNotInteractable;
    const auto wrapper = ancestor.DynamicTo<WebElement>();
    const auto* style = wrapper ? wrapper.ConstUnwrap<Element>()->GetComputedStyle() : nullptr;
    if (style && (style->Visibility() != EVisibility::kVisible || style->Opacity() <= 0 ||
                  style->IsInert() || style->UsedPointerEvents() == EPointerEvents::kNone ||
                  style->ContentVisibility() == EContentVisibility::kHidden)) return ArxKeypressResult::kNotInteractable;
    ancestor = ancestor.ParentOrShadowHostNode();
  }
  struct Binding { const decltype(bound)* check; } binding{&bound};
  ArxKeypressGuard guard([](void* pointer) { return (*static_cast<Binding*>(pointer)->check)(); }, &binding);
  if (!guard.installed() || !bound()) return ArxKeypressResult::kStale;
  const auto dispatch = [&](WebInputEvent::Type type, bool suppress_default) {
    WebKeyboardEvent native(type, WebInputEvent::kNoModifiers, base::TimeTicks::Now());
    native.dom_key = key.dom_key;
    native.windows_key_code = key.virtual_key;
    for (unsigned i = 0; i < 3; ++i) native.text[i] = native.unmodified_text[i] = key.text[i];
    auto* event = KeyboardEvent::Create(native, frame->DomWindow());
    event->SetTrusted(true);
    event->SetTarget(element);
    // Supported keys have no requested keyup default. Keep the exact original
    // target; never refetch a newly focused node or synthesize user activation.
    if (suppress_default) event->SetDefaultHandled();
    guard.SetEvent(event);
    return element->DispatchEvent(*event);
  };
  const auto down = dispatch(WebInputEvent::Type::kRawKeyDown, false);
  if (guard.suppressed()) return ArxKeypressResult::kPossiblyDispatched;
  // Event handlers are allowed arbitrary script side effects. Once dispatch
  // begins, a stale callback cannot turn the result into not-dispatched.
  if (!identity() || document.FocusedElement() != element) return ArxKeypressResult::kPossiblyDispatched;
  const bool character_continuation = down == DispatchEventResult::kNotCanceled ||
      (down == DispatchEventResult::kCanceledByDefaultEventHandler && guard.fallback_handled());
  if ((key.character || key.virtual_key == ui::VKEY_RETURN) && character_continuation) {
    if (!bound()) return ArxKeypressResult::kPossiblyDispatched;
    dispatch(WebInputEvent::Type::kChar, false);
    if (guard.suppressed()) return ArxKeypressResult::kPossiblyDispatched;
  }
  if (!identity() || document.FocusedElement() != element) return ArxKeypressResult::kPossiblyDispatched;
  dispatch(WebInputEvent::Type::kKeyUp, true);
  return ArxKeypressResult::kDispatched;
}
