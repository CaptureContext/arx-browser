namespace {
constexpr unsigned kArxMaximumFormUnits = 32768;
constexpr unsigned kArxMaximumOptionUnits = 4096;
constexpr unsigned kArxMaximumOptions = 512;
constexpr unsigned kArxMaximumOptionVisits = 1024;

class ArxFormDigest final {
 public:
  ArxFormDigest() : digest_(kHashAlgorithmSha256) {
    StringPart(String("Arx.FormBaseline.v1"), 64);
  }
  bool Number(uint64_t value) {
    std::array<uint8_t, 8> bytes;
    for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = value >> (i * 8);
    return valid_ = valid_ && digest_.Update(bytes);
  }
  bool StringPart(const String& value, unsigned maximum) {
    // String's cached length is checked before scanning or UTF conversion.
    if (value.length() > maximum) return valid_ = false;
    if (!Number(value.length())) return false;
    std::array<uint8_t, 512> bytes;
    for (unsigned offset = 0; offset < value.length();) {
      size_t size = 0;
      while (offset < value.length() && size < bytes.size()) {
        const UChar character = value[offset++];
        bytes[size++] = character & 0xff;
        bytes[size++] = character >> 8;
      }
      if (!digest_.Update(base::span(bytes).first(size))) return valid_ = false;
    }
    return true;
  }
  bool Finish(std::array<uint8_t, 32>& output) {
    DigestValue result;
    if (!valid_ || !digest_.Finish(result) || result.size() != output.size()) return false;
    std::copy(result.begin(), result.end(), output.begin());
    return true;
  }
 private:
  Digestor digest_;
  bool valid_ = true;
};

bool ArxSafeFormAncestry(const WebElement& target) {
  WebNode ancestor = target;
  for (unsigned depth = 0; ancestor; ++depth) {
    if (depth >= 512) return false;
    const auto* input = DynamicTo<HTMLInputElement>(ancestor.ConstUnwrap<Node>());
    if (input && (input->HasBeenPasswordField() || input->FormControlType() ==
          mojom::blink::FormControlType::kInputPassword || input->FormControlType() ==
          mojom::blink::FormControlType::kInputFile)) return false;
    if (ancestor.IsContentEditable()) return false;
    ancestor = ancestor.ParentOrShadowHostNode();
  }
  return true;
}

bool ArxFormTargetVisible(const WebElement& target, Element& element) {
  if (!element.GetLayoutObject() ||
      element.GetLayoutObject()->AbsoluteBoundingBoxRect().IsEmpty())
    return false;
  WebNode ancestor = target;
  for (unsigned depth = 0; ancestor; ++depth) {
    if (depth >= 512) return false;
    const auto wrapper = ancestor.DynamicTo<WebElement>();
    const auto* style = wrapper ? wrapper.ConstUnwrap<Element>()->GetComputedStyle() : nullptr;
    if (style && (style->Visibility() != EVisibility::kVisible || style->Opacity() <= 0 ||
                  style->IsInert() || style->UsedPointerEvents() == EPointerEvents::kNone ||
                  style->ContentVisibility() == EContentVisibility::kHidden))
      return false;
    ancestor = ancestor.ParentOrShadowHostNode();
  }
  return true;
}

ArxFormBaselineStatus ArxSelectBaseline(HTMLSelectElement& select,
                                       ArxFormDigest& digest) {
  if (select.IsMultiple() || select.IsAppearanceBase()) return ArxFormBaselineStatus::kUnsupported;
  // Bound traversal before GetOptionList/GetListItems/value() can scan or
  // allocate an arbitrary author-controlled tree. Traditional options only.
  unsigned visits = 0, options = 0, text_units = 0;
  for (Node* node = NodeTraversal::FirstWithin(select); node;
       node = NodeTraversal::Next(*node, &select)) {
    if (++visits > kArxMaximumOptionVisits) return ArxFormBaselineStatus::kLimit;
    if (auto* text = DynamicTo<Text>(node)) {
      const auto length = text->length();
      if (length > kArxMaximumFormUnits - text_units) return ArxFormBaselineStatus::kLimit;
      text_units += length;
    } else if (IsA<HTMLOptionElement>(node)) {
      if (++options > kArxMaximumOptions) return ArxFormBaselineStatus::kLimit;
    } else if (!IsA<HTMLOptGroupElement>(node) && node->getNodeType() != Node::kCommentNode) {
      return ArxFormBaselineStatus::kUnsupported;
    }
  }
  digest.Number(options);
  unsigned value_units = 0;
  for (auto& option : select.GetOptionList()) {
    const String value = option.value();
    if (value.length() > kArxMaximumOptionUnits ||
        value.length() > kArxMaximumFormUnits - value_units)
      return ArxFormBaselineStatus::kLimit;
    value_units += value.length();
    digest.Number(option.IsDisabledFormControl());
    digest.Number(option.Selected());
    digest.Number(option.FastHasAttribute(html_names::kHiddenAttr));
    if (!digest.StringPart(value, kArxMaximumOptionUnits)) return ArxFormBaselineStatus::kInvalid;
  }
  return ArxFormBaselineStatus::kAvailable;
}
}  // namespace

ArxFormBaselineStatus CaptureFormBaselineForArxInspection(
    const WebElement& target, ArxFormBaseline* output) {
  if (!target || !output || !ArxSafeFormAncestry(target))
    return ArxFormBaselineStatus::kUnsupported;
  const auto* control = DynamicTo<HTMLFormControlElement>(target.ConstUnwrap<Node>());
  if (!control) return ArxFormBaselineStatus::kUnsupported;
  ArxFormBaseline state;
  TextControlElement* text = nullptr;
  HTMLSelectElement* select = nullptr;
  if (const auto* input = DynamicTo<HTMLInputElement>(control)) {
    const auto type = input->FormControlType();
    if (type != mojom::blink::FormControlType::kInputText &&
        type != mojom::blink::FormControlType::kInputSearch)
      return ArxFormBaselineStatus::kUnsupported;
    state.kind = type == mojom::blink::FormControlType::kInputText ? 1 : 2;
    state.maximum_length = input->maxLength();
    text = const_cast<HTMLInputElement*>(input);
  } else if (const auto* textarea = DynamicTo<HTMLTextAreaElement>(control)) {
    state.kind = 3;
    state.maximum_length = textarea->maxLength();
    text = const_cast<HTMLTextAreaElement*>(textarea);
  } else if (const auto* selection = DynamicTo<HTMLSelectElement>(control)) {
    state.kind = 4;
    select = const_cast<HTMLSelectElement*>(selection);
  } else {
    return ArxFormBaselineStatus::kUnsupported;
  }
  state.readonly = control->IsReadOnly();
  state.disabled = control->IsDisabledFormControl();
  ArxFormDigest digest;
  digest.Number(state.kind);
  digest.Number(state.maximum_length);
  digest.Number(state.readonly);
  digest.Number(state.disabled);
  if (text) {
    const String value = text->Value();
    if (value.length() > kArxMaximumFormUnits) return ArxFormBaselineStatus::kLimit;
    state.value_length = value.length();
    // Cached or bounded UA-editor selection; never change the focused element.
    state.selection_start = text->selectionStart();
    state.selection_end = text->selectionEnd();
    digest.Number(state.selection_start);
    digest.Number(state.selection_end);
    digest.StringPart(text->selectionDirection(), 16);
    digest.StringPart(value, kArxMaximumFormUnits);
  } else {
    const auto status = ArxSelectBaseline(*select, digest);
    if (status != ArxFormBaselineStatus::kAvailable) return status;
  }
  if (!digest.Finish(state.digest)) return ArxFormBaselineStatus::kInvalid;
  *output = state;
  return ArxFormBaselineStatus::kAvailable;
}

ArxFormActionResult PerformFormActionForArxInspection(
    const WebElement& target, const WebDocument& expected_document,
    uint64_t expected_version, int32_t expected_node,
    const ArxFormBaseline& baseline, ArxFormActionKind action,
    const WebString& payload, bool (*is_current)(void*), void* context) {
  if (!target || !expected_document || !is_current) return ArxFormActionResult::kStale;
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
  if (!current()) return ArxFormActionResult::kStale;
  const auto disallowed = target.InteractionDisallowedReason(/*check_aria=*/true);
  if (!current()) return ArxFormActionResult::kStale;
  document.UpdateStyleAndLayoutTreeForElement(element, DocumentUpdateReason::kInput);
  if (!current()) return ArxFormActionResult::kStale;
  if (!ArxFormTargetVisible(target, *element)) return ArxFormActionResult::kNotInteractable;
  ArxFormBaseline now;
  const auto status = CaptureFormBaselineForArxInspection(target, &now);
  if (!current()) return ArxFormActionResult::kStale;
  // Any eligible property change invalidates the original baseline, even if
  // the requested value now happens to equal the website's replacement value.
  if (status != ArxFormBaselineStatus::kAvailable || now != baseline)
    return ArxFormActionResult::kStale;
  if (disallowed.has_value() || now.disabled || now.readonly) return ArxFormActionResult::kNotInteractable;
  const String value = payload;
  if (value.length() > kArxMaximumFormUnits) return ArxFormActionResult::kLimit;
  for (unsigned i = 0; i < value.length(); ++i) {
    if (!value[i] || (action == ArxFormActionKind::kReplaceText &&
        (value[i] == '\r' || (now.kind != 3 && value[i] == '\n'))))
      return ArxFormActionResult::kInvalidValue;
  }
  if (action == ArxFormActionKind::kReplaceText) {
    if (now.kind == 4) return ArxFormActionResult::kUnsupported;
    if (now.maximum_length >= 0 && value.length() > static_cast<unsigned>(now.maximum_length))
      return ArxFormActionResult::kInvalidValue;
    auto* text = To<TextControlElement>(element);
    const bool unchanged = text->Value() == value;
    if (!current()) return ArxFormActionResult::kStale;
    if (unchanged) return ArxFormActionResult::kUnchanged;
    // Do not use autofill/paste/focused-frame editing. This exact retained
    // control receives the value and its native input/change event sequence.
    text->SetValue(value, TextFieldEventBehavior::kDispatchInputAndChangeEvent,
                   TextControlSetValueSelection::kDoNotSet);
    return ArxFormActionResult::kDispatched;
  }
  if (action != ArxFormActionKind::kSelectValue || now.kind != 4)
    return ArxFormActionResult::kUnsupported;
  if (value.length() > kArxMaximumOptionUnits) return ArxFormActionResult::kLimit;
  auto* select = To<HTMLSelectElement>(element);
  HTMLOptionElement* match = nullptr;
  for (auto& option : select->GetOptionList()) {
    if (option.value() != value) continue;
    if (match) return ArxFormActionResult::kAmbiguousOption;
    match = &option;
  }
  if (!match) return ArxFormActionResult::kOptionNotFound;
  if (match->IsDisabledFormControl() || match->FastHasAttribute(html_names::kHiddenAttr) ||
      (match->NearestAncestorOptgroup() &&
       match->NearestAncestorOptgroup()->FastHasAttribute(html_names::kHiddenAttr)))
    return ArxFormActionResult::kNotInteractable;
  // Menu-list options can have lazy style while their popup is closed. Resolve
  // only the selected candidate and its optgroup; never open or focus the menu.
  match->EnsureComputedStyle();
  if (auto* group = match->NearestAncestorOptgroup()) group->EnsureComputedStyle();
  if (!current()) return ArxFormActionResult::kStale;
  document.UpdateStyleAndLayoutTreeForElement(element, DocumentUpdateReason::kInput);
  if (!current()) return ArxFormActionResult::kStale;
  const auto hidden = [](Element& item) {
    const auto* style = item.GetComputedStyle();
    return !style || style->Display() == EDisplay::kNone ||
        style->Visibility() != EVisibility::kVisible || style->Opacity() <= 0;
  };
  bool option_hidden = hidden(*match);
  if (auto* group = match->NearestAncestorOptgroup()) option_hidden |= hidden(*group);
  if (!current() || match->OwnerSelectElement() != select) return ArxFormActionResult::kStale;
  ArxFormBaseline final_baseline;
  const auto final_status = CaptureFormBaselineForArxInspection(target, &final_baseline);
  if (!current() || final_status != ArxFormBaselineStatus::kAvailable || final_baseline != baseline)
    return ArxFormActionResult::kStale;
  // No lifecycle/style resolution follows these final cached checks. Option
  // style work can invalidate control/ancestor geometry without a DOM mutation.
  if (option_hidden || !ArxFormTargetVisible(target, *element))
    return ArxFormActionResult::kNotInteractable;
  const bool unchanged = match->Selected();
  if (unchanged) return ArxFormActionResult::kUnchanged;
  select->SelectOptionByElement(match, /*send_events=*/true, WebAutofillState::kNotFilled);
  return ArxFormActionResult::kDispatched;
}

