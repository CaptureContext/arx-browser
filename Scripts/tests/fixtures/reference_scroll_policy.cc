#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <optional>
#include <vector>
namespace blink {
// PRODUCTION_SCROLL_CONTRACT
namespace mojom::blink {
enum class FormControlType { kInputText, kInputPassword, kInputFile };
enum class ScrollType { kProgrammatic };
enum class ScrollBehavior { kInstant };
}
namespace cc { enum class ScrollSourceType { kRelativeScroll }; }
enum class EUserModify { kReadOnly, kReadWrite };
enum class EVisibility { kVisible, kHidden };
enum class EPointerEvents { kAuto, kNone };
enum class EContentVisibility { kVisible, kHidden };
enum class DocumentUpdateReason { kScroll };
enum ScrollbarOrientation { kHorizontalScrollbar, kVerticalScrollbar };
struct Style {
  EUserModify modify = EUserModify::kReadOnly;
  EVisibility visibility = EVisibility::kVisible;
  EPointerEvents pointer = EPointerEvents::kAuto;
  EContentVisibility content = EContentVisibility::kVisible;
  float opacity = 1, zoom = 1;
  bool inert = false;
  EUserModify UsedUserModify() const { return modify; }
  EVisibility Visibility() const { return visibility; }
  EPointerEvents UsedPointerEvents() const { return pointer; }
  EContentVisibility ContentVisibility() const { return content; }
  float Opacity() const { return opacity; }
  float EffectiveZoom() const { return zoom; }
  bool IsInert() const { return inert; }
};
struct ScrollOffset {
  float horizontal = 0, vertical = 0;
  float x() const { return horizontal; }
  float y() const { return vertical; }
  void set_x(float value) { horizontal = value; }
  void set_y(float value) { vertical = value; }
};
struct ScrollableArea {
  bool horizontal = true, vertical = true;
  float min_x = 0, max_x = 100, min_y = 0, max_y = 100;
  ScrollOffset offset;
  int setters = 0;
  std::function<void()> on_set;
  bool UserInputScrollable(ScrollbarOrientation axis) const {
    return axis == kHorizontalScrollbar ? horizontal : vertical;
  }
  float MinimumScrollOffset(ScrollbarOrientation axis) const { return axis == kHorizontalScrollbar ? min_x : min_y; }
  float MaximumScrollOffset(ScrollbarOrientation axis) const { return axis == kHorizontalScrollbar ? max_x : max_y; }
  ScrollOffset GetScrollOffset() const { return offset; }
  bool SetScrollOffset(ScrollOffset value, mojom::blink::ScrollType,
                       cc::ScrollSourceType, mojom::blink::ScrollBehavior) {
    ++setters;
    offset = value;
    if (on_set) on_set();
    return true;
  }
};
struct Document;
struct Element;
struct LocalFrame {
  Document* document;
  float zoom = 1;
  Document* GetDocument() const { return document; }
  float LayoutZoomFactor() const { return zoom; }
};
struct Document {
  LocalFrame* frame = nullptr;
  uint64_t version = 1;
  bool active = true;
  int layout_count = 0;
  std::function<void()> layout;
  bool IsActive() const { return active; }
  LocalFrame* GetFrame() const { return frame; }
  uint64_t DomTreeVersion() const { return version; }
  void UpdateStyleAndLayoutForNode(Element*, DocumentUpdateReason) { ++layout_count; if (layout) layout(); }
};
struct Rect { bool empty = false; bool IsEmpty() const { return empty; } };
struct LayoutBox {
  virtual ~LayoutBox() = default;
  Document* document = nullptr;
  LayoutBox* parent = nullptr;
  ScrollableArea* area = nullptr;
  Style style;
  Rect bounds;
  LayoutBox* EnclosingBox() { return this; }
  LayoutBox* ContainingBlock() { return parent; }
  Document& GetDocument() const { return *document; }
  ScrollableArea* GetScrollableArea() { return area; }
  const Style& Style() const { return style; }
  Rect AbsoluteBoundingBoxRect() const { return bounds; }
};
struct LayoutView : LayoutBox {};
struct Node {
  virtual ~Node() = default;
  Document* document = nullptr;
  Node* parent = nullptr;
  bool connected = true;
};
struct Element : Node {
  Style style;
  LayoutBox* box = nullptr;
  bool aria_disabled = false, aria_hidden = false, presentation = false;
  Document& GetDocument() const { return *document; }
  bool isConnected() const { return connected; }
  const Style* GetComputedStyle() const { return &style; }
  LayoutBox* GetLayoutObject() { return box; }
};
struct HTMLFormControlElement : Element {
  bool disabled = false;
  bool IsDisabledFormControl() const { return disabled; }
};
struct HTMLInputElement : HTMLFormControlElement {
  bool former_password = false;
  mojom::blink::FormControlType type = mojom::blink::FormControlType::kInputText;
  bool HasBeenPasswordField() const { return former_password; }
  auto FormControlType() const { return type; }
};
namespace html_names { constexpr int kAriaDisabledAttr = 0, kAriaHiddenAttr = 1; }
bool AriaBoolAttr(const Element& node, int attribute) {
  return attribute == html_names::kAriaDisabledAttr ? node.aria_disabled : node.aria_hidden;
}
bool HasPresentationalRole(const Element& node) { return node.presentation; }
template<class T, class U> const T* DynamicTo(const U* value) { return dynamic_cast<const T*>(value); }
template<class T, class U> bool IsA(U* value) { return dynamic_cast<T*>(value); }
struct WebDocument {
  Document* pointer;
  explicit operator bool() const { return pointer; }
  bool operator==(const WebDocument&) const = default;
};
std::map<int, Node*> nodes;
struct WebNode {
  Node* pointer = nullptr;
  explicit operator bool() const { return pointer; }
  bool operator==(const WebNode&) const = default;
  static WebNode FromDomNodeId(int id) { return {nodes[id]}; }
  WebDocument GetDocument() const { return {pointer->document}; }
  WebNode ParentOrShadowHostNode() const { return {pointer->parent}; }
  bool IsContentEditable() const { assert(false && "unexpected lifecycle flush"); return false; }
  template<class T> const T* ConstUnwrap() const { return dynamic_cast<const T*>(pointer); }
  template<class T> T DynamicTo() const { return T{{dynamic_cast<Element*>(pointer)}}; }
};
struct WebElement : WebNode {
  std::optional<int> InteractionDisallowedReason(bool) const {
    assert(false && "unexpected lifecycle flush");
    return std::nullopt;
  }
};
// PRODUCTION_SCROLL_HELPER
struct Fixture {
  Document document, replacement;
  LocalFrame frame{&document};
  HTMLInputElement target, parent, reused;
  LayoutBox inner;
  LayoutView outer;
  ScrollableArea inner_area, outer_area;
  bool authorized = true;
  Fixture() {
    document.frame = &frame;
    for (auto* node : {&target, &parent, &reused}) node->document = &document;
    target.parent = &parent;
    target.box = &inner;
    inner.parent = &outer;
    inner.document = outer.document = &document;
    inner.area = &inner_area;
    outer.area = &outer_area;
    nodes[7] = &target;
  }
  ArxScrollResult Run(double delta = 40, ArxScrollAxis axis = ArxScrollAxis::kVertical) {
    return ScrollReferenceForArxInspection(WebElement{{&target}}, {&document}, 1, 7,
        axis, delta, [](void* value) { return static_cast<Fixture*>(value)->authorized; }, this);
  }
};
void Atomic() {
  for (int scenario = 0; scenario < 24; ++scenario) {
    Fixture f;
    switch (scenario) {
      case 1: f.document.layout = [&] { ++f.document.version; }; break;
      case 2: f.document.layout = [&] { ++f.document.version; }; break;
      case 3: f.document.layout = [&] { nodes[7] = &f.reused; }; break;
      case 4: f.document.layout = [&] { f.target.connected = false; }; break;
      case 5: f.document.layout = [&] { f.frame.document = &f.replacement; }; break;
      case 6: f.document.layout = [&] { f.authorized = false; }; break;
      case 7: f.document.layout = [&] { f.parent.former_password = true; }; break;
      case 8: f.target.type = mojom::blink::FormControlType::kInputFile; break;
      case 9: f.parent.type = mojom::blink::FormControlType::kInputPassword; break;
      case 10: f.document.layout = [&] { f.parent.style.opacity = 0; }; break;
      case 11: f.document.layout = [&] { f.inner.style.inert = true; }; break;
      case 12: f.target.box = nullptr; break;
      case 13: f.inner.bounds.empty = true; break;
      case 14: f.inner.document = &f.replacement; break;
      case 15: f.parent.style.modify = EUserModify::kReadWrite; break;
      case 16: f.target.disabled = true; f.document.layout = [&] { ++f.document.version; }; break;
      case 18: f.document.layout = [&] { f.target.disabled = true; }; break;
      case 19: f.document.layout = [&] { f.parent.aria_disabled = true; }; break;
      case 20: f.document.layout = [&] { f.parent.aria_hidden = true; }; break;
      case 21: f.document.layout = [&] { f.target.presentation = true; }; break;
      case 22: f.document.layout = [&] { f.parent.style.modify = EUserModify::kReadWrite; }; break;
      case 23: f.document.layout = [&] { f.target.disabled = true; ++f.document.version; }; break;
      case 17: f.inner_area.on_set = [&] { f.target.connected = false; f.document.active = false; }; break;
    }
    const auto result = f.Run();
    assert(f.document.layout_count == 1);
    const bool dispatched = scenario == 0 || scenario == 17;
    assert((result == ArxScrollResult::kDispatched) == dispatched);
    assert(f.inner_area.setters == (dispatched ? 1 : 0));
    assert(f.outer_area.setters == 0);
    if (scenario == 16 || scenario == 23) assert(result == ArxScrollResult::kStale);
  }
}
void Containers() {
  { Fixture f; f.inner_area.offset.vertical = 100;
    assert(f.Run() == ArxScrollResult::kUnchanged);
    assert(f.inner_area.setters == 0 && f.outer_area.setters == 0); }
  { Fixture f; f.inner_area.vertical = false;
    assert(f.Run() == ArxScrollResult::kDispatched);
    assert(f.inner_area.setters == 0 && f.outer_area.offset.vertical == 40); }
  { Fixture f; f.inner_area.max_y = 0;
    assert(f.Run() == ArxScrollResult::kDispatched);
    assert(f.outer_area.offset.vertical == 40); }
  { Fixture f; f.inner_area.vertical = f.outer_area.vertical = false;
    assert(f.Run() == ArxScrollResult::kNoContainer); }
  { Fixture f; f.inner_area.offset.horizontal = 23; f.inner.style.zoom = 2;
    assert(f.Run(80) == ArxScrollResult::kDispatched);
    assert(f.inner_area.offset.vertical == 100 && f.inner_area.offset.horizontal == 23); }
  { Fixture f; f.inner_area.min_x = -100; f.inner_area.max_x = 0;
    assert(f.Run(-8192, ArxScrollAxis::kHorizontal) == ArxScrollResult::kDispatched);
    assert(f.inner_area.offset.horizontal == -100 && f.inner_area.offset.vertical == 0); }
  { Fixture f; f.target.box = &f.outer; f.frame.zoom = 2; f.outer.style.zoom = 3;
    assert(f.Run(20) == ArxScrollResult::kDispatched);
    assert(f.outer_area.offset.vertical == 40); }
  { Fixture f; f.document.layout = [&] { f.inner.area = &f.outer_area; };
    assert(f.Run() == ArxScrollResult::kDispatched);
    assert(f.inner_area.setters == 0 && f.outer_area.setters == 1); }
  { Fixture f; f.inner.area = nullptr; f.inner.parent = &f.inner;
    assert(f.Run() == ArxScrollResult::kLimit); }
  for (double delta : {0.0, -0.0}) {
    Fixture f; assert(f.Run(delta) == ArxScrollResult::kUnchanged);
    assert(f.inner_area.setters == 0); }
  for (double delta : {8193.0, -8193.0, std::numeric_limits<double>::infinity(),
                       std::numeric_limits<double>::quiet_NaN()}) {
    Fixture f; assert(f.Run(delta) == ArxScrollResult::kInvalidDelta);
    assert(f.inner_area.setters == 0); }
  { Fixture f; f.inner.style.zoom = std::numeric_limits<float>::infinity();
    assert(f.Run() == ArxScrollResult::kInvalidDelta); }
}
}  // namespace blink
int main() { blink::Atomic(); blink::Containers(); }
