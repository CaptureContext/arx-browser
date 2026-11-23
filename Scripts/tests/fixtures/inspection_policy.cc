#include <cassert>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>
#include "policy.h"

namespace base {
// Chromium's, without line-break trimming: runs of ASCII whitespace become one space.
inline std::string CollapseWhitespaceASCII(std::string_view text, bool trim_sequences_with_line_breaks) {
  assert(!trim_sequences_with_line_breaks);
  std::string result;
  bool space = false;
  for (char character : text) {
    if (character == ' ' || character == '\t' || character == '\n' || character == '\r' || character == '\f') {
      space = !result.empty();
      continue;
    }
    if (space) result += ' ';
    space = false;
    result += character;
  }
  return result;
}
// Chromium's: at most `size` bytes, never splitting a UTF-8 sequence.
inline void TruncateUTF8ToByteSize(const std::string& input, size_t size, std::string* output) {
  if (input.size() <= size) { *output = input; return; }
  size_t end = size;
  while (end > 0 && (static_cast<unsigned char>(input[end]) & 0xC0) == 0x80) --end;
  *output = input.substr(0, end);
}
}  // namespace base

namespace blink {
namespace mojom {
enum class FormControlType { kInputText, kInputPassword, kInputSubmit, kInputButton, kInputReset, kButtonSubmit };
}
struct WebString {
  std::string value;
  static WebString FromUtf8(const char* value) { return {value}; }
  size_t length() const { return value.size(); }
  std::string Utf8() const { return value; }
};
struct DocumentState { std::string token = "document"; uint64_t version = 7; bool active = true; };
struct Document {
  DocumentState* state;
  explicit operator bool() const { return state; }
  bool IsActive() const { return state->active; }
  uint64_t DomTreeVersionForArxInspection() const { return state->version; }
  struct Identity { std::string value; std::string ToString() const { return value; } };
  Identity Token() const { return {state->token}; }
  bool operator==(const Document&) const = default;
};
struct Data {
  Data* parent = nullptr;
  Data* shadow_host = nullptr;
  bool password = false, former_password = false, control = false, editable = false;
  bool user_agent = false, connected = true;
  // A text node has `text`; an element lists its `children` in order.
  std::optional<std::string> text;
  std::vector<Data*> children;
  std::string type;
  std::string tag;
  std::map<std::string, std::string> attributes;
  std::map<std::string, std::string> style;
  DocumentState* document = nullptr;
};
struct WebNode {
  Data* data = nullptr;
  explicit operator bool() const { return data; }
  template <typename T> T DynamicTo() const;
  WebNode ParentOrShadowHostNode() const { return {data->parent ? data->parent : data->shadow_host}; }
  bool IsContentEditable() const { return data->editable; }
  bool IsInUserAgentShadowRoot() const { return data->user_agent; }
  bool IsConnected() const { return data && data->connected; }
  bool IsNull() const { return !data; }
  bool IsTextNode() const { return data->text.has_value(); }
  WebString NodeValue() const { return {data->text.value_or("")}; }
  WebNode FirstChild() const { return {data->children.empty() ? nullptr : data->children.front()}; }
  WebNode NextSibling() const {
    if (!data->parent) return {};
    const auto& siblings = data->parent->children;
    for (size_t index = 0; index + 1 < siblings.size(); ++index) {
      if (siblings[index] == data) return {siblings[index + 1]};
    }
    return {};
  }
  Document GetDocument() const { return {data->document}; }
  bool operator==(const WebNode&) const = default;
};
struct WebElement : WebNode {
  bool HasHTMLTagName(WebString tag) const { return data->tag == tag.value; }
  bool HasAttribute(WebString key) const { return data->attributes.contains(key.value); }
  WebString GetComputedValue(WebString property) const {
    auto found = data->style.find(property.value);
    return {found == data->style.end() ? "" : found->second};
  }
  WebString GetAttribute(WebString key) const {
    auto found = data->attributes.find(key.value);
    return {found == data->attributes.end() ? "" : found->second};
  }
};
struct WebFormControlElement : WebElement {
  mojom::FormControlType FormControlType() const {
    if (data->password) return mojom::FormControlType::kInputPassword;
    if (data->type == "submit") return mojom::FormControlType::kInputSubmit;
    if (data->type == "button") return mojom::FormControlType::kInputButton;
    if (data->type == "reset") return mojom::FormControlType::kInputReset;
    if (data->tag == "button") return mojom::FormControlType::kButtonSubmit;
    return mojom::FormControlType::kInputText;
  }
  mojom::FormControlType FormControlTypeForAutofill() const {
    return data->former_password ? mojom::FormControlType::kInputPassword : FormControlType();
  }
};
template <> WebElement WebNode::DynamicTo() const { return {{data}}; }
template <> WebFormControlElement WebNode::DynamicTo() const { return {{{data && data->control ? data : nullptr}}}; }
}  // namespace blink

using namespace arx::inspection;
// PRODUCTION_SAFETY

struct FakeRemote {
  size_t forgets = 0;
  bool is_bound() const { return true; }
  FakeRemote* operator->() { return this; }
  void Forget(const std::string&) { ++forgets; }
};
size_t snapshot_count = 0;
class Inspection {
 public:
  struct Snapshot { bool retired = false; std::string frame; };
  struct Pending { bool inspection; std::string snapshot; };
  std::map<std::string, Snapshot> snapshots_;
  std::map<uint64_t, Pending> pending_;
  FakeRemote remote_;
  FakeRemote* Remote(const std::string&) { return &remote_; }
  // PRODUCTION_FORGET
};

int main(int argc, char** argv) {
  assert(argc == 2);
  const std::string scenario = argv[1];
  if (scenario == "password") {
    blink::Data password;
    password.control = true;
    password.password = true;
    blink::Data shadow;
    shadow.shadow_host = &password;
    blink::Data text;
    text.parent = &shadow;
    assert(!SafeNode({&password}, false));
    assert(!SafeNode({&text}, false));
    assert(!SafeNode({&text}, true));
    password.password = false;
    password.former_password = true;
    assert(!SafeNode({&text}, false));
    password.former_password = false;
    assert(SafeNode({&text}, false));
    assert(!SafeNode({&text}, true));
    password.control = false;
    shadow.user_agent = true;
    assert(!SafeNode({&text}, true));
    shadow.user_agent = false;
    password.editable = true;
    assert(!SafeNode({&text}, true));
    password.editable = false;
    password.tag = "canvas";
    assert(!SafeNode({&text}, true));
    password.tag = "div";
    assert(SafeNode({&text}, true));
    text.parent = &text;
    assert(!SafeNode({&text}, false));
  } else if (scenario == "names") {
    blink::Data node;
    node.attributes["aria-label"] = "Upload";
    assert(HasSafeOwnName({&node}, "Upload"));
    assert(!HasSafeOwnName({&node}, "Upload secret-file.txt"));
    assert(!HasSafeOwnName({&node}, "related password value"));
    node.attributes["title"] = "Explicit title";
    assert(HasSafeOwnName({&node}, "Explicit title"));
    assert(!HasSafeOwnName({&node}, ""));
    node.attributes["alt"] = std::string(4097, 'x');
    assert(!HasSafeOwnName({&node}, node.attributes["alt"]));
    assert(JSONStringBytes("\"\\\n") == 12);
    Budget text(10), output(10);
    assert(TakeText("hello", text, output));
    assert(!TakeText("hello", text, output));
  } else if (scenario == "buttons") {
    // A plain button is named by its own words, across inline children, collapsed.
    blink::Data page, button, start, bold, boldText, end;
    page.tag = "div";
    button.tag = "button";
    button.control = true;
    button.parent = &page;
    start.text = "  Arx\n ";
    start.parent = &button;
    bold.tag = "b";
    bold.parent = &button;
    boldText.text = "plain";
    boldText.parent = &bold;
    bold.children = {&boldText};
    end.text = " button ";
    end.parent = &button;
    button.children = {&start, &bold, &end};
    assert(ButtonLabel({&button}) == "Arx plain button");

    // Words inside a nested control, password ancestry, an editable region or a canvas stay out.
    blink::Data field, fieldText, editable, editableText, canvas, canvasText;
    field.control = true;
    field.parent = &button;
    fieldText.text = "ARX_BUTTON_NESTED_SECRET";
    fieldText.parent = &field;
    field.children = {&fieldText};
    editable.editable = true;
    editable.parent = &button;
    editableText.text = "ARX_EDITABLE_SECRET";
    editableText.parent = &editable;
    editable.children = {&editableText};
    canvas.tag = "canvas";
    canvas.parent = &button;
    canvasText.text = "ARX_CANVAS_FALLBACK_SECRET";
    canvasText.parent = &canvas;
    canvas.children = {&canvasText};
    button.children = {&start, &field, &editable, &canvas, &end};
    assert(ButtonLabel({&button}) == "Arx button");

    // An icon's hidden ligature isn't part of the name.
    blink::Data icon, iconText;
    icon.tag = "span";
    icon.parent = &button;
    icon.attributes["aria-hidden"] = "true";
    iconText.text = "shopping_cart";
    iconText.parent = &icon;
    icon.children = {&iconText};
    button.children = {&icon, &start, &end};
    assert(ButtonLabel({&button}) == "Arx button");

    // Nor is text CSS hides.
    icon.attributes.clear();
    for (auto [property, value] : {std::pair{"display", "none"}, std::pair{"visibility", "hidden"}}) {
      icon.style = {{property, value}};
      assert(ButtonLabel({&button}) == "Arx button");
    }
    icon.style.clear();
    assert(ButtonLabel({&button}) == "shopping_cart Arx button");

    // Inline text runs together; blocks and line breaks separate words.
    {
      blink::Data split, s, span, end;
      split.tag = "button";
      split.control = true;
      s.text = "S";
      s.parent = &split;
      span.tag = "span";
      span.parent = &split;
      end.text = "end";
      end.parent = &span;
      span.children = {&end};
      split.children = {&s, &span};
      assert(ButtonLabel({&split}) == "Send");
      span.style = {{"display", "block"}};
      assert(ButtonLabel({&split}) == "S end");
      span.style = {{"display", "inline-block"}};
      assert(ButtonLabel({&split}) == "Send");
      blink::Data pay, payText, br, now;
      split.children = {&pay, &br, &now};
      pay.tag = "div";
      pay.parent = &split;
      pay.style = {{"display", "block"}};
      payText.text = "Pay";
      payText.parent = &pay;
      pay.children = {&payText};
      br.tag = "br";
      br.parent = &split;
      now.text = "now";
      now.parent = &split;
      assert(ButtonLabel({&split}) == "Pay now");
    }

    // An editable button's words are a draft, not a label.
    button.editable = true;
    assert(ButtonLabel({&button}).empty());
    button.editable = false;

    // A name the author gave elsewhere is the button's; its words aren't projected.
    button.attributes["aria-labelledby"] = "password";
    assert(ButtonLabel({&button}).empty());
    button.attributes.clear();
    button.attributes["aria-label"] = "Explicit";
    assert(ButtonLabel({&button}).empty());
    button.attributes.clear();

    // Nothing under a password, an editable region, a canvas or another control.
    blink::Data password;
    password.control = true;
    password.password = true;
    page.parent = &password;
    assert(ButtonLabel({&button}).empty());
    page.parent = nullptr;
    for (auto host : {"editable", "canvas", "control"}) {
      blink::Data outer;
      outer.editable = std::string(host) == "editable";
      outer.tag = std::string(host) == "canvas" ? "canvas" : "div";
      outer.control = std::string(host) == "control";
      page.parent = &outer;
      assert(ButtonLabel({&button}).empty());
      page.parent = nullptr;
    }

    // Long words are cut at 256 bytes without splitting a character.
    blink::Data longText;
    longText.text = std::string(255, 'a') + "\xc3\xa9";
    longText.parent = &button;
    button.children = {&longText};
    const auto bounded = ButtonLabel({&button});
    assert(bounded == std::string(255, 'a'));

    // A submit, button or reset input is named by its value; other inputs never are.
    blink::Data input;
    input.tag = "input";
    input.control = true;
    input.parent = &page;
    input.attributes["value"] = "Arx submit input";
    for (auto type : {"submit", "button", "reset"}) {
      input.type = type;
      assert(ButtonLabel({&input}) == "Arx submit input");
    }
    input.type = "text";
    input.attributes["value"] = "ARX_FORM_VALUE_SECRET";
    assert(ButtonLabel({&input}).empty());
    input.type = "submit";
    input.password = true;
    assert(ButtonLabel({&input}).empty());

    // Anything else has no button words.
    blink::Data paragraph;
    paragraph.tag = "p";
    paragraph.children = {&start};
    assert(ButtonLabel({&paragraph}).empty());
    assert(ButtonLabel({}).empty());
  } else if (scenario == "reference") {
    blink::DocumentState state;
    blink::Data data, replacement;
    data.document = &state;
    replacement.document = &state;
    blink::WebNode retained{&data}, resolved = retained;
    blink::Document document{&state};
    auto matches = [&] {
      return ReferenceMatches(retained, 12, "document", 7, document,
          [&](int id) { assert(id == 12); return resolved; },
          [&](const blink::WebNode& node) { return SafeNode(node, false); },
          [](const blink::Document& document) { return document.DomTreeVersionForArxInspection(); });
    };
    assert(matches());
    state.version = 8;  // DOM replacement before any queued AX event.
    assert(!matches());
    state.version = 7;
    resolved = {&replacement};  // Same integer ID, different retained identity.
    assert(!matches());
    resolved = retained;
    data.connected = false;
    assert(!matches());
    data.connected = true;
    state.token = "replacement document";
    assert(!matches());
    state.token = "document";
    state.active = false;
    assert(!matches());
    state.active = true;
    assert(!ReferenceMatches(retained, 12, "document", 7, document,
        [&](int) { return resolved; }, [&](const blink::WebNode&) {
          state.version = 8; return true;
        }, [](const blink::Document& document) { return document.DomTreeVersionForArxInspection(); }));
  } else if (scenario == "retirement") {
    Inspection owner;
    owner.snapshots_["old"] = {};
    owner.pending_[1] = {true, "old"};
    snapshot_count = 1;
    for (int i = 0; i < 100; ++i) owner.Forget("old");
    assert(owner.remote_.forgets == 1);
    assert(snapshot_count == 1);  // Timeout/revoke do not reopen admission.
    owner.snapshots_["new"] = {};
    ++snapshot_count;
    owner.pending_.erase(1);  // Physical callback/disconnect drains.
    owner.Forget("old");
    assert(snapshot_count == 1);
    assert(owner.remote_.forgets == 1);
    assert(owner.snapshots_.contains("new"));
    owner.Forget("old");
    owner.Forget("new");
    assert(snapshot_count == 0 && owner.remote_.forgets == 2);
  } else if (scenario == "limits") {
    struct Limits { uint32_t nodes, text_bytes, references, output_bytes, timeout_ms, window_start; };
    Limits limit{512, 65536, 256, 262144, 2000, 0};
    assert(ValidLimits(limit));
    // Windows start anywhere inside the projected tree, never past it.
    limit.window_start = kMaximumTreeNodes - 1;
    assert(ValidLimits(limit));
    limit.window_start = kMaximumTreeNodes;
    assert(!ValidLimits(limit));
    limit.window_start = 0;
    assert(SensitiveAutocomplete("billing cc-number") && SensitiveAutocomplete("one-time-code"));
    assert(!SensitiveAutocomplete("email") && !SensitiveAutocomplete("name"));
    ++limit.nodes;
    assert(!ValidLimits(limit));
    limit.nodes = 1;
    limit.references = 257;
    assert(!ValidLimits(limit));
    assert(kMaximumSnapshots * kMaximumReferences == kMaximumHandles);
    assert(kMaximumRequests == 16 && kReferenceSeconds == 30);
    assert(!ValidToken(std::string(100000, 'a')));
    assert(ValidToken(std::string(32, 'a')));
    assert(!ValidToken(std::string(32, 'x')));
  } else assert(false);
}
