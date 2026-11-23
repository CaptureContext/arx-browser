namespace blink {
namespace {
struct ArxKeyboardKey {
  int dom_key = 0;
  int virtual_key = 0;
  UChar text[3] = {};
  bool character = false;
  bool editing = false;     // Edits or moves the caret in an editable reference.
  bool activation = false;  // Enter and Space activate a focused control.
};

bool ArxKeyboardDefine(const String& key, ArxKeyboardKey* output) {
  struct Named { const char* name; int dom; int code; bool editing; };
  static const Named named[] = {
    {"Backspace", ui::DomKey::BACKSPACE, ui::VKEY_BACK, true},
    {"Delete", ui::DomKey::DEL, ui::VKEY_DELETE, true},
    {"ArrowLeft", ui::DomKey::ARROW_LEFT, ui::VKEY_LEFT, true},
    {"ArrowRight", ui::DomKey::ARROW_RIGHT, ui::VKEY_RIGHT, true},
    {"ArrowUp", ui::DomKey::ARROW_UP, ui::VKEY_UP, true},
    {"ArrowDown", ui::DomKey::ARROW_DOWN, ui::VKEY_DOWN, true},
    {"Home", ui::DomKey::HOME, ui::VKEY_HOME, true},
    {"End", ui::DomKey::END, ui::VKEY_END, true},
    {"Enter", ui::DomKey::ENTER, ui::VKEY_RETURN, true},
    {"Tab", ui::DomKey::TAB, ui::VKEY_TAB, false},
    {"Escape", ui::DomKey::ESCAPE, ui::VKEY_ESCAPE, false},
    {"PageUp", ui::DomKey::PAGE_UP, ui::VKEY_PRIOR, false},
    {"PageDown", ui::DomKey::PAGE_DOWN, ui::VKEY_NEXT, false},
    {"F1", ui::DomKey::F1, ui::VKEY_F1, false}, {"F2", ui::DomKey::F2, ui::VKEY_F2, false},
    {"F3", ui::DomKey::F3, ui::VKEY_F3, false}, {"F4", ui::DomKey::F4, ui::VKEY_F4, false},
    {"F5", ui::DomKey::F5, ui::VKEY_F5, false}, {"F6", ui::DomKey::F6, ui::VKEY_F6, false},
    {"F7", ui::DomKey::F7, ui::VKEY_F7, false}, {"F8", ui::DomKey::F8, ui::VKEY_F8, false},
    {"F9", ui::DomKey::F9, ui::VKEY_F9, false}, {"F10", ui::DomKey::F10, ui::VKEY_F10, false},
    {"F11", ui::DomKey::F11, ui::VKEY_F11, false}, {"F12", ui::DomKey::F12, ui::VKEY_F12, false},
  };
  for (const auto& value : named) {
    if (key != value.name) continue;
    output->dom_key = value.dom;
    output->virtual_key = value.code;
    output->editing = value.editing;
    if (value.code == ui::VKEY_RETURN) {
      output->text[0] = '\r';
      output->activation = true;
    }
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
      scalar == 0x2028 || scalar == 0x2029 || (scalar & 0xffff) >= 0xfffe) return false;
  output->dom_key = ui::DomKey::FromCharacter(scalar);
  output->character = true;
  output->editing = true;
  output->activation = scalar == ' ';
  // Letters, digits and Space carry their Windows key code so shortcut
  // listeners that read keyCode work; no physical code or layout is claimed.
  if (scalar == ' ') output->virtual_key = ui::VKEY_SPACE;
  else if (scalar >= 'a' && scalar <= 'z') output->virtual_key = static_cast<int>(scalar - 'a' + 'A');
  else if ((scalar >= 'A' && scalar <= 'Z') || (scalar >= '0' && scalar <= '9'))
    output->virtual_key = static_cast<int>(scalar);
  for (unsigned i = 0; i < key.length(); ++i) output->text[i] = key[i];
  return true;
}

bool ArxKeyboardPassword(const Node* node) {
  for (unsigned depth = 0; node; ++depth) {
    if (depth >= 1024) return true;
    if (const auto* input = DynamicTo<HTMLInputElement>(node);
        input && (input->FormControlType() == mojom::blink::FormControlType::kInputPassword ||
                  input->HasBeenPasswordField())) return true;
    node = node->ParentOrShadowHostNode();
  }
  return false;
}

// A text field or textarea that the guarded keypress baseline supports, or
// the root of a contenteditable region.
enum class ArxEditable { kNone, kTextControl, kContentEditable };
ArxEditable ArxKeyboardEditable(Element& element) {
  if (IsA<TextControlElement>(element)) {
    if (const auto* input = DynamicTo<HTMLInputElement>(element); input && !input->IsTextField())
      return ArxEditable::kNone;
    return ArxEditable::kTextControl;
  }
  return IsEditable(element) && IsRootEditableElement(element) ? ArxEditable::kContentEditable
                                                               : ArxEditable::kNone;
}

// Same-task authority for one keyboard action on one reference.
struct ArxKeyboardTarget {
  Persistent<Element> element;
  Persistent<Document> document;
  Persistent<LocalFrame> frame;
  WebElement handle;
  WebDocument expected_document;
  int32_t node = 0;
  bool (*is_current)(void*) = nullptr;
  void* context = nullptr;
  ArxEditable editable = ArxEditable::kNone;

  bool Identity() const {
    return frame && document->IsActive() && document->GetFrame() == frame.Get() &&
        frame->GetDocument() == document.Get() && handle.GetDocument() == expected_document &&
        element->isConnected() && WebNode::FromDomNodeId(node) == handle && is_current(context);
  }
  bool Focused() const { return Identity() && document->FocusedElement() == element.Get(); }
  // Text may only go to the reference itself: focus and selection stay in it,
  // and no password control is reachable from either.
  bool Editing() const {
    if (!Focused() || ArxKeyboardPassword(element.Get())) return false;
    const auto& selection = frame->Selection().GetSelectionInDomTree();
    if (selection.IsNone()) return false;
    for (const Node* node : {selection.Anchor().AnchorNode(), selection.Focus().AnchorNode()}) {
      if (!node || ArxKeyboardPassword(node) ||
          !element->IsShadowIncludingInclusiveAncestorOf(*node)) return false;
    }
    return true;
  }
};

enum class ArxKeyMode { kGuarded, kListeners, kNative };

int ArxKeyboardModifiers(uint32_t modifiers) {
  int result = WebInputEvent::kNoModifiers;
  if (modifiers & kArxKeyShift) result |= WebInputEvent::kShiftKey;
  if (modifiers & kArxKeyControl) result |= WebInputEvent::kControlKey;
  if (modifiers & kArxKeyAlt) result |= WebInputEvent::kAltKey;
  if (modifiers & kArxKeyMeta) result |= WebInputEvent::kMetaKey;
  return result;
}

// One keydown, optional keypress and keyup sequence to the reference itself.
// Guarded: defaults run only while Editing() holds (ArxKeypressGuard).
// Listeners: author listeners see every event; no default runs.
// Native: Blink's defaults run (focus navigation, Escape, activation).
ArxKeyboardResult ArxDispatchKey(const ArxKeyboardTarget& target, const ArxKeyboardKey& key,
                                 int modifiers, ArxKeyMode mode) {
  if (ArxKeypressGuard::Busy()) return ArxKeyboardResult::kBusy;
  struct Binding { const ArxKeyboardTarget* target; } binding{&target};
  std::optional<ArxKeypressGuard> guard;
  if (mode == ArxKeyMode::kGuarded) {
    guard.emplace([](void* pointer) { return static_cast<Binding*>(pointer)->target->Editing(); }, &binding);
    if (!guard->installed() || !target.Editing()) return ArxKeyboardResult::kStale;
  }
  const bool text = key.character && !(modifiers & (WebInputEvent::kControlKey | WebInputEvent::kMetaKey));
  const auto dispatch = [&](WebInputEvent::Type type, bool suppress_default) {
    WebKeyboardEvent native(type, modifiers, base::TimeTicks::Now());
    native.dom_key = key.dom_key;
    native.windows_key_code = key.virtual_key;
    if (text || type == WebInputEvent::Type::kChar) {
      for (unsigned i = 0; i < 3; ++i) native.text[i] = native.unmodified_text[i] = key.text[i];
    }
    auto* event = KeyboardEvent::Create(native, target.frame->DomWindow());
    event->SetTrusted(true);
    event->SetTarget(target.element.Get());
    if (suppress_default || mode == ArxKeyMode::kListeners) event->SetDefaultHandled();
    if (guard) guard->SetEvent(event);
    return target.element->DispatchEvent(*event);
  };
  const auto down = dispatch(WebInputEvent::Type::kRawKeyDown, false);
  if (guard && guard->suppressed()) return ArxKeyboardResult::kPossiblyDispatched;
  if (!target.Identity()) return ArxKeyboardResult::kPossiblyDispatched;
  // A keypress follows only for text or Enter whose keydown wasn't cancelled,
  // and only while focus is still on the reference: its default inserts text
  // wherever the selection now is.
  const bool continuation = down == DispatchEventResult::kNotCanceled ||
      (guard && down == DispatchEventResult::kCanceledByDefaultEventHandler && guard->fallback_handled());
  if ((text || key.virtual_key == ui::VKEY_RETURN) && continuation && target.Focused()) {
    if (guard && !target.Editing()) return ArxKeyboardResult::kPossiblyDispatched;
    dispatch(WebInputEvent::Type::kChar, false);
    if (guard && guard->suppressed()) return ArxKeyboardResult::kPossiblyDispatched;
  }
  if (!target.Identity()) return ArxKeyboardResult::kPossiblyDispatched;
  dispatch(WebInputEvent::Type::kKeyUp, true);
  return target.Identity() ? ArxKeyboardResult::kDispatched : ArxKeyboardResult::kPossiblyDispatched;
}

// Checks the snapshot authority, focuses the reference and reports whether
// any author code may have run (focus events) before the first key.
ArxKeyboardResult ArxKeyboardPrepare(ArxKeyboardTarget& target, uint64_t expected_version,
                                     bool* focused) {
  *focused = false;
  const auto bound = [&]() { return target.Identity() && target.document->DomTreeVersion() == expected_version; };
  if (!bound()) return ArxKeyboardResult::kStale;
  if (ArxKeyboardPassword(target.element.Get())) return ArxKeyboardResult::kNotInteractable;
  if (target.handle.InteractionDisallowedReason(/*check_aria=*/true).has_value())
    return ArxKeyboardResult::kNotInteractable;
  target.document->UpdateStyleAndLayoutTreeForElement(target.element.Get(), DocumentUpdateReason::kInput);
  if (!bound()) return ArxKeyboardResult::kStale;
  if (!target.element->GetLayoutObject() ||
      target.element->GetLayoutObject()->AbsoluteBoundingBoxRect().IsEmpty())
    return ArxKeyboardResult::kNotInteractable;
  target.editable = ArxKeyboardEditable(*target.element);
  if (target.document->FocusedElement() != target.element.Get()) {
    *focused = true;
    target.element->Focus(FocusParams(SelectionBehaviorOnFocus::kRestore,
                                      mojom::blink::FocusType::kNone, nullptr));
    if (!target.Focused()) return ArxKeyboardResult::kPossiblyDispatched;
  }
  return ArxKeyboardResult::kDispatched;
}

ArxKeyboardTarget ArxKeyboardTargetFor(const WebElement& handle, const WebDocument& expected,
                                       int32_t node, bool (*is_current)(void*), void* context) {
  ArxKeyboardTarget target;
  target.element = const_cast<Element*>(handle.ConstUnwrap<Element>());
  target.document = &target.element->GetDocument();
  target.frame = target.document->GetFrame();
  target.handle = handle;
  target.expected_document = expected;
  target.node = node;
  target.is_current = is_current;
  target.context = context;
  return target;
}
}  // namespace

ArxKeyboardResult TypeTextForArxInspection(
    const WebElement& handle, const WebDocument& expected_document,
    uint64_t expected_version, int32_t expected_node, const WebString& web_text,
    bool (*is_current)(void*), void* context) {
  if (!handle || !expected_document || !is_current) return ArxKeyboardResult::kStale;
  if (ArxKeypressGuard::Busy()) return ArxKeyboardResult::kBusy;
  const String text = web_text;
  if (text.empty() || text.length() > 1024) return ArxKeyboardResult::kInvalidKey;
  auto target = ArxKeyboardTargetFor(handle, expected_document, expected_node, is_current, context);
  if (!target.frame) return ArxKeyboardResult::kStale;
  // Validate every character before any focus or key event.
  Vector<String> keys;
  const bool multiline = IsA<HTMLTextAreaElement>(*target.element) ||
      ArxKeyboardEditable(*target.element) == ArxEditable::kContentEditable;
  for (unsigned i = 0; i < text.length();) {
    const unsigned size = U16_IS_LEAD(text[i]) && i + 1 < text.length() ? 2 : 1;
    String key = text.substr(i, size);
    if (key == "\n") {
      if (!multiline) return ArxKeyboardResult::kInvalidKey;
      key = "Enter";
    }
    ArxKeyboardKey definition;
    if (!ArxKeyboardDefine(key, &definition) || (!definition.character && key != "Enter"))
      return ArxKeyboardResult::kInvalidKey;
    keys.push_back(key);
    i += size;
  }
  bool focused = false;
  if (const auto prepared = ArxKeyboardPrepare(target, expected_version, &focused);
      prepared != ArxKeyboardResult::kDispatched) return prepared;
  if (target.editable == ArxEditable::kNone) {
    return focused ? ArxKeyboardResult::kPossiblyDispatched : ArxKeyboardResult::kUnsupported;
  }
  // Type at the end of the existing content.
  if (target.editable == ArxEditable::kTextControl) {
    auto& control = To<TextControlElement>(*target.element);
    const unsigned length = control.InnerEditorValue().length();
    control.SetSelectionRange(length, length);
  } else {
    target.frame->Selection().SetSelection(
        SelectionInDomTree::Builder().Collapse(Position::LastPositionInNode(*target.element)).Build(),
        SetSelectionOptions());
  }
  bool dispatched = focused;
  for (const auto& key : keys) {
    if (!target.Editing()) return dispatched ? ArxKeyboardResult::kPossiblyDispatched : ArxKeyboardResult::kStale;
    ArxKeyboardResult result;
    if (target.editable == ArxEditable::kTextControl) {
      // Text fields reuse the guarded keypress with a fresh baseline per key.
      ArxKeypressBaseline baseline;
      if (CaptureKeypressBaselineForArxInspection(target.handle, &baseline) != ArxFormBaselineStatus::kAvailable)
        return dispatched ? ArxKeyboardResult::kPossiblyDispatched : ArxKeyboardResult::kUnsupported;
      const auto keypress = PerformKeypressForArxInspection(target.handle, target.expected_document,
          target.document->DomTreeVersion(), target.node, baseline, WebString(key), is_current, context);
      result = keypress == ArxKeypressResult::kDispatched ? ArxKeyboardResult::kDispatched
          : keypress == ArxKeypressResult::kBusy && !dispatched ? ArxKeyboardResult::kBusy
          : ArxKeyboardResult::kPossiblyDispatched;
    } else {
      ArxKeyboardKey definition;
      ArxKeyboardDefine(key, &definition);
      result = ArxDispatchKey(target, definition, WebInputEvent::kNoModifiers, ArxKeyMode::kGuarded);
    }
    if (result != ArxKeyboardResult::kDispatched) {
      return dispatched || result == ArxKeyboardResult::kPossiblyDispatched
          ? ArxKeyboardResult::kPossiblyDispatched : result;
    }
    dispatched = true;
  }
  return ArxKeyboardResult::kDispatched;
}

ArxKeyboardResult PressKeyForArxInspection(
    const WebElement& handle, const WebDocument& expected_document,
    uint64_t expected_version, int32_t expected_node, const WebString& web_key,
    uint32_t modifiers, bool (*is_current)(void*), void* context) {
  if (!handle || !expected_document || !is_current) return ArxKeyboardResult::kStale;
  if (ArxKeypressGuard::Busy()) return ArxKeyboardResult::kBusy;
  ArxKeyboardKey key;
  if (!ArxKeyboardDefine(String(web_key), &key) ||
      (modifiers & ~(kArxKeyShift | kArxKeyControl | kArxKeyAlt | kArxKeyMeta)))
    return ArxKeyboardResult::kInvalidKey;
  auto target = ArxKeyboardTargetFor(handle, expected_document, expected_node, is_current, context);
  if (!target.frame) return ArxKeyboardResult::kStale;
  bool focused = false;
  if (const auto prepared = ArxKeyboardPrepare(target, expected_version, &focused);
      prepared != ArxKeyboardResult::kDispatched) return prepared;
  const bool chord = modifiers & (kArxKeyControl | kArxKeyAlt | kArxKeyMeta);
  // Control, Alt and Meta chords are page shortcuts: no clipboard, undo or
  // editing default may run. Text and editing keys on an editable reference
  // are guarded like typing. Enter and Space activate a focused control.
  // Other keys keep Blink's defaults; they never insert text.
  const bool editable = target.editable != ArxEditable::kNone;
  ArxKeyMode mode = ArxKeyMode::kNative;
  if (chord) mode = ArxKeyMode::kListeners;
  else if (editable && key.editing) mode = ArxKeyMode::kGuarded;
  else if (!editable && key.character && !key.activation) mode = ArxKeyMode::kListeners;
  if (mode == ArxKeyMode::kGuarded && !target.Editing())
    return focused ? ArxKeyboardResult::kPossiblyDispatched : ArxKeyboardResult::kStale;
  const auto result = ArxDispatchKey(target, key, ArxKeyboardModifiers(modifiers), mode);
  if (focused && result != ArxKeyboardResult::kDispatched) return ArxKeyboardResult::kPossiblyDispatched;
  return result;
}
}  // namespace blink
