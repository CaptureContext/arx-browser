#include <algorithm>
#include <array>
#include <cassert>
#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <span>
#include <string>
#include <vector>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <CommonCrypto/CommonDigest.h>
namespace base { template<class T, size_t N = std::dynamic_extent> using span = std::span<T, N>; }
namespace blink {
using UChar = char16_t;
struct String {
  std::u16string value;
  unsigned reported_length = 0;
  mutable unsigned reads = 0;
  String() = default;
  String(const char* text) { while (*text) value.push_back(*text++); }
  String(std::u16string text) : value(std::move(text)) {}
  unsigned length() const { return reported_length ? reported_length : value.size(); }
  UChar operator[](unsigned i) const { ++reads; return value.at(i); }
  bool operator==(const String& other) const { return value == other.value; }
};
using WebString = String;
using DigestValue = std::vector<uint8_t>;
enum HashAlgorithm { kHashAlgorithmSha256 };
struct Digestor {
  CC_SHA256_CTX context;
  explicit Digestor(HashAlgorithm) { CC_SHA256_Init(&context); }
  bool Update(base::span<const uint8_t> bytes) {
    return CC_SHA256_Update(&context, bytes.data(), static_cast<CC_LONG>(bytes.size()));
  }
  bool Finish(DigestValue& value) {
    value.resize(32);
    return CC_SHA256_Final(value.data(), &context);
  }
};
// PRODUCTION_FORM_CONTRACT
namespace mojom::blink {
enum class FormControlType { kInputText, kInputSearch, kInputPassword, kInputFile, kOther };
}
namespace html_names { constexpr int kHiddenAttr = 1; }
enum class EDisplay { kBlock, kNone };
enum class EVisibility { kVisible, kHidden };
enum class EPointerEvents { kAuto, kNone };
enum class EContentVisibility { kVisible, kHidden };
enum class DocumentUpdateReason { kInput };
enum class TextFieldEventBehavior { kDispatchInputAndChangeEvent };
enum class TextControlSetValueSelection { kDoNotSet };
enum class WebAutofillState { kNotFilled };
struct Style {
  EDisplay display = EDisplay::kBlock;
  EDisplay Display() const { return display; }
  EVisibility visibility = EVisibility::kVisible;
  EPointerEvents pointer = EPointerEvents::kAuto;
  EContentVisibility content = EContentVisibility::kVisible;
  float opacity = 1;
  bool inert = false;
  EVisibility Visibility() const { return visibility; }
  EPointerEvents UsedPointerEvents() const { return pointer; }
  EContentVisibility ContentVisibility() const { return content; }
  float Opacity() const { return opacity; }
  bool IsInert() const { return inert; }
};
struct Rect { bool empty = false; bool IsEmpty() const { return empty; } };
struct Layout { Rect bounds; Rect AbsoluteBoundingBoxRect() const { return bounds; } };
struct Node;
struct Element;
struct Document;
struct LocalFrame { Document* document; Document* GetDocument() const { return document; } };
struct Document {
  LocalFrame* frame = nullptr;
  uint64_t version = 1;
  bool active = true;
  std::function<void()> preflight, layout;
  bool IsActive() const { return active; }
  LocalFrame* GetFrame() const { return frame; }
  uint64_t DomTreeVersion() const { return version; }
  void UpdateStyleAndLayoutTreeForElement(Element*, DocumentUpdateReason) { if (layout) layout(); }
};
struct Node {
  virtual ~Node() = default;
  Document* document = nullptr;
  Node* parent = nullptr;
  Node* next = nullptr;
  Node* child = nullptr;
  bool connected = true, editable = false;
  enum NodeType { kElementNode, kCommentNode, kTextNode };
  virtual NodeType getNodeType() const { return kElementNode; }
};
template<class T, class U> const T* DynamicTo(const U* object) { return dynamic_cast<const T*>(object); }
template<class T, class U> T* DynamicTo(U* object) { return dynamic_cast<T*>(object); }
template<class T, class U> bool IsA(const U* object) { return DynamicTo<T>(object); }
template<class T, class U> T* To(U* object) { auto* result = DynamicTo<T>(object); assert(result); return result; }
struct Element : Node {
  Style style;
  Layout layout;
  bool has_layout = true, hidden = false;
  Document& GetDocument() const { return *document; }
  bool isConnected() const { return connected; }
  std::function<void()> ensure_style;
  const Style* GetComputedStyle() const { return &style; }
  const Style* EnsureComputedStyle() { if (ensure_style) ensure_style(); return &style; }
  Layout* GetLayoutObject() { return has_layout ? &layout : nullptr; }
  bool FastHasAttribute(int) const { return hidden; }
};
struct Text : Node {
  unsigned size = 0;
  unsigned length() const { return size; }
  NodeType getNodeType() const override { return kTextNode; }
};
struct NodeTraversal {
  static Node* FirstWithin(Node& node) { return node.child; }
  static Node* Next(Node& node, Node*) { return node.next; }
};
struct HTMLFormControlElement : Element {
  bool readonly = false, disabled = false;
  bool IsReadOnly() const { return readonly; }
  bool IsDisabledFormControl() const { return disabled; }
};
struct TextControlElement : HTMLFormControlElement {
  String value;
  unsigned start = 0, end = 0;
  String direction = "none";
  int maximum = -1;
  unsigned sets = 0;
  std::function<void()> script;
  String Value() const { return value; }
  unsigned selectionStart() const { return start; }
  unsigned selectionEnd() const { return end; }
  String selectionDirection() const { return direction; }
  int maxLength() const { return maximum; }
  void SetValue(const String& replacement, TextFieldEventBehavior, TextControlSetValueSelection) {
    value = replacement;
    ++sets;
    if (script) script();
  }
};
struct HTMLInputElement : TextControlElement {
  bool password = false;
  mojom::blink::FormControlType type = mojom::blink::FormControlType::kInputText;
  bool HasBeenPasswordField() const { return password; }
  auto FormControlType() const { return type; }
};
struct HTMLTextAreaElement : TextControlElement {};
struct HTMLSelectElement;
struct HTMLOptGroupElement : Element {};
struct HTMLOptionElement : Element {
  String option_value;
  bool selected = false, disabled = false;
  HTMLSelectElement* owner = nullptr;
  HTMLOptGroupElement* group = nullptr;
  String value() const { return option_value; }
  bool Selected() const { return selected; }
  bool IsDisabledFormControl() const { return disabled; }
  auto OwnerSelectElement() const { return owner; }
  auto NearestAncestorOptgroup() const { return group; }
};
struct OptionList {
  std::vector<HTMLOptionElement*>* values;
  struct Iterator {
    std::vector<HTMLOptionElement*>::iterator iterator;
    HTMLOptionElement& operator*() const { return **iterator; }
    Iterator& operator++() { ++iterator; return *this; }
    bool operator!=(const Iterator& other) const { return iterator != other.iterator; }
  };
  Iterator begin() const { return {values->begin()}; }
  Iterator end() const { return {values->end()}; }
};
struct HTMLSelectElement : HTMLFormControlElement {
  bool multiple = false, customizable = false;
  unsigned sets = 0;
  std::vector<HTMLOptionElement*> options;
  bool IsMultiple() const { return multiple; }
  bool IsAppearanceBase() const { return customizable; }
  OptionList GetOptionList() { return {&options}; }
  void SelectOptionByElement(HTMLOptionElement* chosen, bool, WebAutofillState) {
    for (auto* option : options) option->selected = option == chosen;
    ++sets;
  }
};
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
  template<class T> T DynamicTo() const { return T{{dynamic_cast<Element*>(pointer)}}; }
  template<class T> const T* ConstUnwrap() const { return dynamic_cast<T*>(pointer); }
  bool IsContentEditable() const { return pointer->editable; }
};
struct WebElement : WebNode {
  std::optional<int> InteractionDisallowedReason(bool) const {
    auto& document = *pointer->document;
    if (document.preflight) document.preflight();
    const auto* control = dynamic_cast<HTMLFormControlElement*>(pointer);
    return control && control->disabled ? std::optional<int>(1) : std::nullopt;
  }
};
// PRODUCTION_FORM_HELPER
}  // namespace blink
#pragma clang diagnostic pop
using namespace blink;
struct Fixture {
  Document document;
  LocalFrame frame{&document};
  bool authority = true;
  Fixture() { document.frame = &frame; }
  void Attach(Element& target) { target.document = &document; nodes[7] = &target; }
  static bool Current(void* pointer) { return static_cast<Fixture*>(pointer)->authority; }
  ArxFormActionResult Run(Element& target, const ArxFormBaseline& state,
                          ArxFormActionKind action, const String& value) {
    return PerformFormActionForArxInspection(WebElement{{&target}}, {&document}, 1, 7,
                                             state, action, value, Current, this);
  }
};
ArxFormBaseline Baseline(Element& target) {
  ArxFormBaseline state;
  assert(CaptureFormBaselineForArxInspection(WebElement{{&target}}, &state) ==
         ArxFormBaselineStatus::kAvailable);
  return state;
}
void TextProperties() {
  for (int scenario = 0; scenario < 20; ++scenario) {
    Fixture fixture;
    HTMLInputElement input, ancestor;
    fixture.Attach(input);
    input.value = "old";
    input.start = 1;
    input.end = 2;
    auto state = Baseline(input);
    switch (scenario) {
      case 1: input.value = "interleaved"; break;
      case 2: input.start = 0; break;
      case 3: input.direction = "backward"; break;
      case 4: input.readonly = true; break;
      case 5: input.maximum = 100; break;
      case 6: input.type = mojom::blink::FormControlType::kInputSearch; break;
      case 7: fixture.document.layout = [&] { input.value = "new"; }; break;
      case 8: fixture.document.layout = [&] { ++fixture.document.version; }; break;
      case 9: fixture.document.layout = [&] { fixture.authority = false; }; break;
      case 10: input.password = true; break;
      case 11: input.type = mojom::blink::FormControlType::kInputFile; break;
      case 12: input.style.opacity = 0; break;
      case 13: input.script = [&] { fixture.authority = false; fixture.frame.document = nullptr; }; break;
      case 14: fixture.document.preflight = [&] { input.disabled = true; ++fixture.document.version; }; break;
      case 15: input.disabled = true; break;
      case 16: nodes[7] = nullptr; break;
      case 17: input.parent = &ancestor; ancestor.password = true; break;
      case 18: input.parent = &ancestor; ancestor.editable = true; break;
      case 19: input.parent = &ancestor; ancestor.type = mojom::blink::FormControlType::kInputFile; break;
    }
    const auto result = fixture.Run(input, state, ArxFormActionKind::kReplaceText, "new");
    const bool dispatched = scenario == 0 || scenario == 13;
    assert((result == ArxFormActionResult::kDispatched) == dispatched);
    assert(input.sets == (dispatched ? 1u : 0u));
    if (scenario == 7 || scenario == 14) assert(result == ArxFormActionResult::kStale);
  }
}
void BoundsAndUnchanged() {
  Fixture fixture;
  HTMLInputElement input;
  fixture.Attach(input);
  input.value = "same";
  auto state = Baseline(input);
  assert(fixture.Run(input, state, ArxFormActionKind::kReplaceText, "same") == ArxFormActionResult::kUnchanged);
  assert(input.sets == 0);
  input.value = "different";
  assert(fixture.Run(input, state, ArxFormActionKind::kReplaceText, "different") == ArxFormActionResult::kStale);
  state = Baseline(input);
  assert(fixture.Run(input, state, ArxFormActionKind::kReplaceText, "line\nbreak") == ArxFormActionResult::kInvalidValue);
  input.maximum = 2;
  state = Baseline(input);
  assert(fixture.Run(input, state, ArxFormActionKind::kReplaceText, "long") == ArxFormActionResult::kInvalidValue);
  input.maximum = 1;
  state = Baseline(input);
  assert(fixture.Run(input, state, ArxFormActionKind::kReplaceText, String(u"\U0001F600")) ==
         ArxFormActionResult::kInvalidValue);
  input.value.reported_length = 32769;
  assert(CaptureFormBaselineForArxInspection(WebElement{{&input}}, &state) == ArxFormBaselineStatus::kLimit);
  input.password = true;
  assert(CaptureFormBaselineForArxInspection(WebElement{{&input}}, &state) == ArxFormBaselineStatus::kUnsupported);
  HTMLTextAreaElement area;
  fixture.Attach(area);
  state = Baseline(area);
  assert(fixture.Run(area, state, ArxFormActionKind::kReplaceText, "line\r\nbreak") == ArxFormActionResult::kInvalidValue);
  assert(fixture.Run(area, state, ArxFormActionKind::kReplaceText, "line\nbreak") == ArxFormActionResult::kDispatched);
}
void SelectCases() {
  for (int scenario = 0; scenario < 17; ++scenario) {
    Fixture fixture;
    HTMLSelectElement select;
    HTMLOptionElement a, b;
    HTMLOptGroupElement group;
    fixture.Attach(select);
    a.option_value = "a"; b.option_value = "b";
    a.selected = true;
    a.owner = b.owner = &select;
    a.document = b.document = &fixture.document;
    a.next = &b; select.child = &a; select.options = {&a, &b};
    if (scenario == 3) b.option_value = "a";
    if (scenario == 4) b.disabled = true;
    if (scenario == 5) b.hidden = true;
    if (scenario == 10) b.style.display = EDisplay::kNone;
    if (scenario == 11) b.style.visibility = EVisibility::kHidden;
    if (scenario == 12) { b.group = &group; group.style.display = EDisplay::kNone; }
    if (scenario == 13) b.ensure_style = [&] { b.option_value = "interleaved"; };
    if (scenario == 14) b.ensure_style = [&] { select.style.visibility = EVisibility::kHidden; };
    if (scenario == 15) { select.parent = &group; b.ensure_style = [&] { group.style.inert = true; }; }
    if (scenario == 16) b.ensure_style = [&] { select.layout.bounds.empty = true; };
    auto state = Baseline(select);
    if (scenario == 6) { a.selected = false; b.selected = true; }
    if (scenario == 7) fixture.document.layout = [&] { b.option_value = "changed"; };
    if (scenario == 8) b.owner = nullptr;
    if (scenario == 9) fixture.document.layout = [&] { fixture.authority = false; };
    const String requested = scenario == 1 || scenario == 3 ? "a" : scenario == 2 ? "missing" : "b";
    const auto result = fixture.Run(select, state, ArxFormActionKind::kSelectValue, requested);
    if (scenario == 0) assert(result == ArxFormActionResult::kDispatched && select.sets == 1);
    else {
      assert(select.sets == 0);
      if (scenario == 1) assert(result == ArxFormActionResult::kUnchanged);
      if (scenario == 2) assert(result == ArxFormActionResult::kOptionNotFound);
      if (scenario == 3) assert(result == ArxFormActionResult::kAmbiguousOption);
      if (scenario == 4 || scenario == 5 || (scenario >= 10 && scenario <= 12) || scenario >= 14) assert(result == ArxFormActionResult::kNotInteractable);
      if ((scenario >= 6 && scenario <= 9) || scenario == 13) assert(result == ArxFormActionResult::kStale);
    }
  }
  Fixture fixture;
  HTMLSelectElement select;
  fixture.Attach(select);
  std::vector<HTMLOptionElement> options(513);
  for (size_t i = 0; i < options.size(); ++i) {
    options[i].next = i + 1 < options.size() ? &options[i + 1] : nullptr;
    select.options.push_back(&options[i]);
  }
  select.child = options.data();
  ArxFormBaseline state;
  assert(CaptureFormBaselineForArxInspection(WebElement{{&select}}, &state) == ArxFormBaselineStatus::kLimit);
  select.multiple = true;
  assert(CaptureFormBaselineForArxInspection(WebElement{{&select}}, &state) == ArxFormBaselineStatus::kUnsupported);
}
void AggregateBoundsAndDigestFraming() {
  Fixture fixture;
  HTMLSelectElement select;
  fixture.Attach(select);
  std::vector<Text> text(1025);
  for (size_t i = 0; i < text.size(); ++i) {
    text[i].next = i + 1 < text.size() ? &text[i + 1] : nullptr;
  }
  select.child = text.data();
  ArxFormBaseline state;
  assert(CaptureFormBaselineForArxInspection(WebElement{{&select}}, &state) == ArxFormBaselineStatus::kLimit);
  text[0].next = nullptr;
  text[0].size = 32769;
  assert(CaptureFormBaselineForArxInspection(WebElement{{&select}}, &state) == ArxFormBaselineStatus::kLimit);

  std::vector<HTMLOptionElement> options(9);
  select.child = options.data();
  for (size_t i = 0; i < options.size(); ++i) {
    options[i].next = i + 1 < options.size() ? &options[i + 1] : nullptr;
    options[i].option_value = String(std::u16string(4096, u'x'));
    select.options.push_back(&options[i]);
  }
  assert(CaptureFormBaselineForArxInspection(WebElement{{&select}}, &state) == ArxFormBaselineStatus::kLimit);

  ArxFormDigest first, second;
  assert(first.StringPart("a", 4) && first.StringPart("bc", 4));
  assert(second.StringPart("ab", 4) && second.StringPart("c", 4));
  std::array<uint8_t, 32> a, b;
  assert(first.Finish(a) && second.Finish(b) && a != b);
}
int main() { TextProperties(); BoundsAndUnchanged(); SelectCases(); AggregateBoundsAndDigestFraming(); }
