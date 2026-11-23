namespace blink {
namespace {
bool ArxFormStatePassword(const Node* node) {
  for (unsigned depth = 0; node; ++depth) {
    if (depth >= 1024) return true;
    if (const auto* input = DynamicTo<HTMLInputElement>(node);
        input && (input->FormControlType() == mojom::blink::FormControlType::kInputPassword ||
                  input->HasBeenPasswordField())) return true;
    node = node->ParentOrShadowHostNode();
  }
  return false;
}

// Same-task authority before any setter: identity, the snapshot's DOM
// version, eligibility and a laid-out, interactable control.
template <typename Control>
ArxFormStateResult ArxFormStatePrepare(const WebElement& handle, const WebDocument& expected,
                                       uint64_t version, int32_t node,
                                       bool (*is_current)(void*), void* context, Control** output) {
  if (!handle || !expected || !is_current) return ArxFormStateResult::kStale;
  auto* element = const_cast<Element*>(handle.ConstUnwrap<Element>());
  Document& document = element->GetDocument();
  LocalFrame* frame = document.GetFrame();
  const auto bound = [&]() {
    return frame && document.IsActive() && frame->GetDocument() == &document &&
        handle.GetDocument() == expected && element->isConnected() &&
        WebNode::FromDomNodeId(node) == handle && document.DomTreeVersion() == version &&
        is_current(context);
  };
  if (!bound()) return ArxFormStateResult::kStale;
  auto* control = DynamicTo<Control>(element);
  if (!control || ArxFormStatePassword(element)) return ArxFormStateResult::kUnsupported;
  if (control->IsDisabledFormControl() ||
      handle.InteractionDisallowedReason(/*check_aria=*/true).has_value())
    return ArxFormStateResult::kNotInteractable;
  document.UpdateStyleAndLayoutTreeForElement(element, DocumentUpdateReason::kInput);
  if (!bound()) return ArxFormStateResult::kStale;
  if (!element->GetLayoutObject() || element->GetLayoutObject()->AbsoluteBoundingBoxRect().IsEmpty())
    return ArxFormStateResult::kNotInteractable;
  *output = control;
  return ArxFormStateResult::kDispatched;
}
}  // namespace

ArxFormStateResult SetCheckedForArxInspection(
    const WebElement& handle, const WebDocument& expected, uint64_t version,
    int32_t node, bool checked, bool (*is_current)(void*), void* context) {
  HTMLInputElement* input = nullptr;
  if (const auto prepared = ArxFormStatePrepare(handle, expected, version, node, is_current, context, &input);
      prepared != ArxFormStateResult::kDispatched) return prepared;
  const auto type = input->FormControlType();
  const bool radio = type == mojom::blink::FormControlType::kInputRadio;
  if (!radio && type != mojom::blink::FormControlType::kInputCheckbox) return ArxFormStateResult::kUnsupported;
  if (radio && !checked) return ArxFormStateResult::kInvalidValue;
  if (input->Checked() == checked && !input->indeterminate()) return ArxFormStateResult::kUnchanged;
  // A user toggle clears indeterminate; then the setter fires input and change.
  // Handlers may destroy the page, so nothing is read afterwards.
  input->setIndeterminate(false);
  input->SetChecked(checked);
  input->DispatchInputAndChangeEventIfNeeded();
  return ArxFormStateResult::kDispatched;
}

ArxFormStateResult SelectValuesForArxInspection(
    const WebElement& handle, const WebDocument& expected, uint64_t version,
    int32_t node, const std::vector<WebString>& web_values,
    bool (*is_current)(void*), void* context) {
  if (web_values.size() > 64) return ArxFormStateResult::kInvalidValue;
  HashSet<String> values;
  for (const auto& value : web_values) {
    const String text = value;
    if (text.IsNull() || text.length() > 4096 || !values.insert(text).is_new_entry)
      return ArxFormStateResult::kInvalidValue;
  }
  HTMLSelectElement* select = nullptr;
  if (const auto prepared = ArxFormStatePrepare(handle, expected, version, node, is_current, context, &select);
      prepared != ArxFormStateResult::kDispatched) return prepared;
  if (!select->IsMultiple()) return ArxFormStateResult::kUnsupported;
  HeapVector<Member<HTMLOptionElement>> options;
  HashMap<String, unsigned> matches;
  for (auto& option : select->GetOptionList()) {
    if (options.size() >= 1024) return ArxFormStateResult::kUnsupported;
    options.push_back(&option);
    const String value = option.value();
    if (values.Contains(value)) {
      auto added = matches.insert(value, 0);
      ++added.stored_value->value;
    }
  }
  for (const auto& value : values) {
    const auto found = matches.find(value);
    if (found == matches.end()) return ArxFormStateResult::kOptionNotFound;
    if (found->value > 1) return ArxFormStateResult::kAmbiguousOption;
  }
  bool changed = false;
  for (const auto& option : options) {
    const bool selected = values.Contains(option->value());
    if (selected && !option->Selected() && option->IsDisabledFormControl())
      return ArxFormStateResult::kNotInteractable;
    changed |= option->Selected() != selected;
  }
  if (!changed) return ArxFormStateResult::kUnchanged;
  for (const auto& option : options) {
    option->SetSelected(values.Contains(option->value()));
    option->SetDirty(true);
  }
  // Handlers may destroy the page, so nothing is read afterwards.
  Persistent<HTMLSelectElement> owner = select;
  owner->DispatchInputEvent();
  owner->DispatchChangeEvent();
  return ArxFormStateResult::kDispatched;
}
}  // namespace blink
