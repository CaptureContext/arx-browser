namespace blink {
namespace {
// Present only while one explicit pointer action runs on this thread. A drag
// started inside it is captured here instead of reaching the browser.
struct ArxPointerScope {
  bool captured = false;
  WebDragData data;
  DragOperationsMask operations = kDragOperationNone;
};
thread_local ArxPointerScope* arx_pointer_scope = nullptr;

bool ArxPointerControlEligible(const Node* node) {
  if (const auto* input = DynamicTo<HTMLInputElement>(node)) {
    const auto type = input->FormControlType();
    // Pickers that open platform UI are not pointer targets. A file chooser a
    // pointer action opens is held for the app instead (ABI30).
    if (type == mojom::blink::FormControlType::kInputPassword || input->HasBeenPasswordField() ||
        type == mojom::blink::FormControlType::kInputColor) return false;
  }
  // macOS selects open a native menu that runs its own event loop.
  return !IsA<HTMLSelectElement>(node);
}

bool ArxPointerEligible(const Node* node) {
  for (unsigned depth = 0; node; ++depth) {
    if (depth >= 1024 || !ArxPointerControlEligible(node)) return false;
    if (const auto* label = DynamicTo<HTMLLabelElement>(node)) {
      if (const auto* control = label->Control(); control && !ArxPointerControlEligible(control))
        return false;
    }
    node = node->ParentOrShadowHostNode();
  }
  return true;
}

bool ArxPointerContains(const Element& element, const Node& node) {
  return element.IsShadowIncludingInclusiveAncestorOf(node);
}
}  // namespace

bool ArxCapturePointerDrag(const WebDragData& data, DragOperationsMask operations) {
  if (!arx_pointer_scope || arx_pointer_scope->captured) return false;
  arx_pointer_scope->captured = true;
  arx_pointer_scope->data = data;
  arx_pointer_scope->operations = operations;
  return true;
}

ArxPointerResult PerformPointerForArxInspection(
    const WebDocument& expected_document, uint64_t expected_version,
    const WebElement& target, int32_t target_node,
    const WebElement& destination, int32_t destination_node,
    const ArxPointerRequest& request, bool (*is_current)(void*), void* context) {
  if (!expected_document || !is_current) return ArxPointerResult::kStale;
  if (arx_pointer_scope) return ArxPointerResult::kBusy;
  const bool drag = request.kind == ArxPointerKind::kDrag;
  if ((request.kind != ArxPointerKind::kHover && request.kind != ArxPointerKind::kClick && !drag) ||
      request.click_count < 1 || request.click_count > 3 || request.steps < 1 || request.steps > 32 ||
      (request.modifiers & ~(kArxPointerShift | kArxPointerAlt | kArxPointerMeta)) ||
      (!target && !request.has_point) ||
      (drag && !destination && !request.has_destination_point) ||
      (!drag && (destination || request.has_destination_point)))
    return ArxPointerResult::kInvalid;
  for (const auto& point : {request.point, request.destination_point}) {
    if (!std::isfinite(point.x()) || !std::isfinite(point.y()) ||
        point.x() < 0 || point.y() < 0 || point.x() > 100000 || point.y() > 100000)
      return ArxPointerResult::kInvalid;
  }
  Persistent<Document> document = const_cast<Document*>(expected_document.ConstUnwrap<Document>());
  Persistent<LocalFrame> frame = document->GetFrame();
  if (!frame) return ArxPointerResult::kStale;
  Persistent<LocalFrame> root = &frame->LocalFrameRoot();
  auto* root_impl = WebLocalFrameImpl::FromFrame(root.Get());
  WeakPersistent<WebFrameWidgetImpl> widget = root_impl ? root_impl->FrameWidgetImpl() : nullptr;
  if (!widget) return ArxPointerResult::kUnsupported;
  // Viewport points are main-widget points; an out-of-process frame has its own.
  if ((request.has_point || request.has_destination_point) && !root->IsOutermostMainFrame())
    return ArxPointerResult::kUnsupported;
  Persistent<Element> source_element =
      target ? const_cast<Element*>(target.ConstUnwrap<Element>()) : nullptr;
  Persistent<Element> destination_element =
      destination ? const_cast<Element*>(destination.ConstUnwrap<Element>()) : nullptr;

  const auto attached = [&](const Element* element, const WebElement& handle, int32_t id) {
    return !element || (element->isConnected() && &element->GetDocument() == document.Get() &&
                        WebNode::FromDomNodeId(id) == handle);
  };
  const auto identity = [&]() {
    return widget && frame->GetDocument() == document.Get() && document->GetFrame() == frame.Get() &&
        document->IsActive() && !frame->IsDetached() && !root->IsDetached() &&
        attached(source_element.Get(), target, target_node) &&
        attached(destination_element.Get(), destination, destination_node) && is_current(context);
  };
  const auto bound = [&]() { return identity() && document->DomTreeVersion() == expected_version; };
  if (!bound()) return ArxPointerResult::kStale;
  for (const auto* element : {source_element.Get(), destination_element.Get()}) {
    if (element && WebElement(const_cast<Element*>(element))
                       .InteractionDisallowedReason(/*check_aria=*/true).has_value())
      return ArxPointerResult::kNotInteractable;
  }
  document->UpdateStyleAndLayout(DocumentUpdateReason::kInput);
  if (!bound()) return ArxPointerResult::kStale;

  // Every point is in the widget's Blink space, as WebMouseEvent expects.
  const auto locate = [&](Element* element, bool has_point, const gfx::PointF& dips,
                          gfx::PointF* output) {
    if (has_point) {
      *output = widget->DIPsToBlinkSpace(dips);
      return true;
    }
    const gfx::Rect visible = WebElement(element).VisibleBoundsInWidget();
    if (visible.IsEmpty()) return false;
    *output = gfx::PointF(visible.CenterPoint());
    return true;
  };
  // The point must hit the reference (or, for a point, the snapshot's document)
  // through Blink's own hit test, including same-process child frames.
  const auto hits = [&](const gfx::PointF& point, Element* element) {
    LocalFrameView* view = root->View();
    if (!view) return ArxPointerResult::kStale;
    const gfx::PointF in_document = view->ConvertFromRootFrame(view->ViewportToFrame(point));
    const HitTestResult result = view->HitTestWithThrottlingAllowed(
        HitTestLocation(in_document),
        HitTestRequest::kReadOnly | HitTestRequest::kActive | HitTestRequest::kAllowChildFrameContent);
    const Node* node = result.InnerNode();
    if (!node) return ArxPointerResult::kNotInteractable;
    if (element ? !ArxPointerContains(*element, *node) : &node->GetDocument() != document.Get())
      return ArxPointerResult::kObscured;
    return ArxPointerEligible(node) ? ArxPointerResult::kDispatched : ArxPointerResult::kNotInteractable;
  };

  gfx::PointF source, end;
  if (!locate(source_element.Get(), request.has_point, request.point, &source))
    return ArxPointerResult::kNotInteractable;
  if (const auto hit = hits(source, source_element.Get()); hit != ArxPointerResult::kDispatched) return hit;
  if (drag) {
    if (!locate(destination_element.Get(), request.has_destination_point, request.destination_point, &end))
      return ArxPointerResult::kNotInteractable;
    if (const auto hit = hits(end, destination_element.Get()); hit != ArxPointerResult::kDispatched) return hit;
  }
  if (!bound() || widget->DoingDragAndDrop()) return ArxPointerResult::kStale;

  ArxPointerScope scope;
  arx_pointer_scope = &scope;
  struct Reset {
    ~Reset() { arx_pointer_scope = nullptr; }
  } reset;
  int modifiers = 0;
  if (request.modifiers & kArxPointerShift) modifiers |= WebInputEvent::kShiftKey;
  if (request.modifiers & kArxPointerAlt) modifiers |= WebInputEvent::kAltKey;
  if (request.modifiers & kArxPointerMeta) modifiers |= WebInputEvent::kMetaKey;
  const auto send = [&](WebInputEvent::Type type, const gfx::PointF& point,
                        WebPointerProperties::Button button, int clicks, int flags) {
    WebMouseEvent event(type, point, point, button, clicks, modifiers | flags, base::TimeTicks::Now());
    event.SetFrameScale(1);
    widget->HandleInputEvent(WebCoalescedInputEvent(event, ui::LatencyInfo()));
  };
  using Button = WebPointerProperties::Button;
  using Type = WebInputEvent::Type;
  // Once the first event is sent, website handlers may have run.
  send(Type::kMouseMove, source, Button::kNoButton, 0, 0);
  if (request.kind == ArxPointerKind::kHover) {
    return identity() ? ArxPointerResult::kDispatched : ArxPointerResult::kPossiblyDispatched;
  }
  if (!drag) {
    for (uint32_t click = 1; click <= request.click_count; ++click) {
      if (!identity()) return ArxPointerResult::kPossiblyDispatched;
      send(Type::kMouseDown, source, Button::kLeft, click, WebInputEvent::kLeftButtonDown);
      if (!identity()) return ArxPointerResult::kPossiblyDispatched;
      send(Type::kMouseUp, source, Button::kLeft, click, 0);
    }
    return identity() ? ArxPointerResult::kDispatched : ArxPointerResult::kPossiblyDispatched;
  }

  if (!identity()) return ArxPointerResult::kPossiblyDispatched;
  send(Type::kMouseDown, source, Button::kLeft, 1, WebInputEvent::kLeftButtonDown);
  // The drag protocol is public on the WebFrameWidget interface.
  const auto drag_widget = [&]() { return static_cast<WebFrameWidget*>(widget.Get()); };
  auto operation = ui::mojom::DragOperation::kNone;
  bool entered = false;
  const auto settle = [&operation]() {
    return base::BindOnce(
        [](ui::mojom::DragOperation* output, ui::mojom::DragOperation value, bool) { *output = value; },
        base::Unretained(&operation));
  };
  gfx::PointF point = source;
  for (uint32_t step = 1; step <= request.steps; ++step) {
    if (!identity()) break;
    const float progress = static_cast<float>(step) / request.steps;
    point = gfx::PointF(source.x() + (end.x() - source.x()) * progress,
                        source.y() + (end.y() - source.y()) * progress);
    if (!scope.captured) {
      send(Type::kMouseMove, point, Button::kLeft, 0, WebInputEvent::kLeftButtonDown);
      if (!scope.captured) continue;
    }
    if (!entered) {
      entered = true;
      drag_widget()->DragTargetDragEnter(scope.data, point, point, scope.operations, modifiers, settle());
    } else {
      drag_widget()->DragTargetDragOver(point, point, scope.operations, modifiers, settle());
    }
  }
  const bool current = identity() && point == end;
  if (!scope.captured) {
    if (widget) send(Type::kMouseUp, point, Button::kLeft, 1, 0);
    return current && identity() ? ArxPointerResult::kDispatched : ArxPointerResult::kPossiblyDispatched;
  }
  if (!widget) return ArxPointerResult::kPossiblyDispatched;
  if (current && entered && operation != ui::mojom::DragOperation::kNone) {
    drag_widget()->DragTargetDrop(scope.data, point, point, modifiers, base::DoNothing());
  } else {
    if (entered) drag_widget()->DragTargetDragLeave(point, point);
    operation = ui::mojom::DragOperation::kNone;
  }
  // Ends the renderer's drag source and clears its drag state.
  if (widget) drag_widget()->DragSourceEndedAt(point, point, operation, base::DoNothing());
  if (widget && widget->DoingDragAndDrop()) drag_widget()->DragSourceSystemDragEnded();
  if (widget) send(Type::kMouseMove, point, Button::kNoButton, 0, 0);
  return current && identity() ? ArxPointerResult::kDispatched : ArxPointerResult::kPossiblyDispatched;
}
}  // namespace blink
