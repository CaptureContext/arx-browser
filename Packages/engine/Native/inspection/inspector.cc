#include <cmath>
#include "third_party/blink/public/web/arx_scroll_actions.h"
#include "components/arx_inspection/inspector.h"
#include "components/arx_inspection/script_runner.h"

#include <algorithm>
#include <optional>
#include <set>
#include <utility>
#include <vector>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/task/single_thread_task_runner.h"
#include "base/unguessable_token.h"
#include "base/values.h"
#include "components/arx_inspection/policy.h"
#include "components/arx_inspection/pointer_policy.h"
#include "components/arx_inspection/keyboard_policy.h"
#include "content/public/renderer/render_frame.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_registry.h"
#include "third_party/blink/public/mojom/forms/form_control_type.mojom.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/arx_inspection.h"
#include "third_party/blink/public/web/web_element.h"
#include "third_party/blink/public/web/web_form_control_element.h"
#include "third_party/blink/public/web/web_frame_widget.h"
#include "third_party/blink/public/web/web_input_element.h"
#include "third_party/blink/public/web/web_local_frame.h"
#include "ui/accessibility/ax_enum_util.h"
#include "ui/accessibility/ax_mode.h"
#include "ui/accessibility/ax_node_data.h"
#include "ui/accessibility/ax_tree_update.h"
#include "url/gurl.h"

namespace arx::inspection {
namespace {
// Renderer-process caps are independent of the stricter whole-browser registry.
size_t snapshot_count = 0;
size_t handle_count = 0;

bool IsTag(const blink::WebNode& node, const char* tag) {
  const auto element = node.DynamicTo<blink::WebElement>();
  return element && element.HasHTMLTagName(blink::WebString::FromUtf8(tag));
}

bool IsPassword(const blink::WebNode& node) {
  const auto control = node.DynamicTo<blink::WebFormControlElement>();
  return control &&
      (control.FormControlType() == blink::mojom::FormControlType::kInputPassword ||
       control.FormControlTypeForAutofill() == blink::mojom::FormControlType::kInputPassword);
}

// ParentOrShadowHostNode crosses UA and author shadow roots. Bound ancestry
// traversal separately from the snapshot; hostile depth fails closed.
bool SafeNode(const blink::WebNode& node, bool text) {
  auto ancestor = node;
  for (size_t depth = 0; depth < kMaximumNodes; ++depth) {
    if (!ancestor) return true;
    if (IsPassword(ancestor)) return false;
    if (text && (ancestor.IsContentEditable() ||
                 ancestor.DynamicTo<blink::WebFormControlElement>() ||
                 ancestor.IsInUserAgentShadowRoot() || IsTag(ancestor, "canvas"))) return false;
    ancestor = ancestor.ParentOrShadowHostNode();
  }
  return false;
}

bool HasSafeOwnName(const blink::WebNode& node, std::string_view name) {
  const auto element = node.DynamicTo<blink::WebElement>();
  if (!element || name.empty()) return false;
  // AX labels may append file values or recursively incorporate password values.
  // Equality to an explicit own attribute is intentionally stricter than NameFrom.
  for (const char* attribute : {"aria-label", "alt", "title"}) {
    const auto value = element.GetAttribute(blink::WebString::FromUtf8(attribute));
    if (value.length() <= kMaximumStringBytes && value.Utf8() == name) return true;
  }
  return false;
}

// A button's words: its own text, or a submit, button or reset input's value.
// A button holds no user data, so unlike other form controls its words are
// projected; text inside nested controls, password ancestry, editable regions
// and canvases stays omitted. Agents and the approval check read what a press
// would do from it (DEV-1008).
// Appends the words under `parent` as they read: inline text runs together, as
// in <button>S<span>end</span></button>, and a block or a line break separates
// them. Decoration the accessible name leaves out (an icon's hidden ligature),
// nested controls, password ancestry, editable regions and canvases stay out.
// False when the text is too long to project.
bool AppendButtonText(const blink::WebNode& parent, std::string& label, size_t& visited, int depth) {
  if (depth > 16) return true;
  for (auto child = parent.FirstChild(); !child.IsNull() && visited < 64; child = child.NextSibling()) {
    ++visited;
    if (child.IsTextNode()) {
      const auto text = child.NodeValue();
      if (text.length() > kMaximumStringBytes) return false;
      label += text.Utf8();
      continue;
    }
    auto element = child.DynamicTo<blink::WebElement>();
    if (!element) continue;
    const auto style = [&](const char* property) {
      return element.GetComputedValue(blink::WebString::FromUtf8(property)).Utf8();
    };
    const std::string display = style("display");
    const bool hidden =
        element.GetAttribute(blink::WebString::FromUtf8("aria-hidden")).Utf8() == "true" ||
        element.HasAttribute(blink::WebString::FromUtf8("hidden")) || display == "none" ||
        style("visibility") == "hidden";
    if (hidden || IsPassword(child) || child.DynamicTo<blink::WebFormControlElement>() ||
        child.IsContentEditable() || IsTag(child, "canvas")) continue;
    const bool flows = display.empty() || display.rfind("inline", 0) == 0 || display == "contents";
    if (!flows || IsTag(child, "br")) label += ' ';
    if (!AppendButtonText(child, label, visited, depth + 1)) return false;
    if (!flows) label += ' ';
  }
  return true;
}

std::string ButtonLabel(const blink::WebNode& node) {
  const auto element = node.DynamicTo<blink::WebElement>();
  // A name the author gave elsewhere is the control's own; its words aren't.
  if (!element || node.IsContentEditable() || !SafeNode(node, false) ||
      !SafeNode(node.ParentOrShadowHostNode(), true) ||
      element.HasAttribute(blink::WebString::FromUtf8("aria-labelledby")) ||
      element.HasAttribute(blink::WebString::FromUtf8("aria-label"))) return std::string();
  std::string label;
  if (IsTag(node, "input")) {
    const auto control = node.DynamicTo<blink::WebFormControlElement>();
    if (!control) return std::string();
    const auto type = control.FormControlType();
    if (type != blink::mojom::FormControlType::kInputSubmit &&
        type != blink::mojom::FormControlType::kInputButton &&
        type != blink::mojom::FormControlType::kInputReset) return std::string();
    const auto value = control.GetAttribute(blink::WebString::FromUtf8("value"));
    if (value.length() > kMaximumStringBytes) return std::string();
    label = value.Utf8();
  } else if (IsTag(node, "button")) {
    size_t visited = 0;
    if (!AppendButtonText(node, label, visited, 0)) return std::string();
  } else {
    return std::string();
  }
  std::string collapsed = base::CollapseWhitespaceASCII(label, false);
  std::string bounded;
  base::TruncateUTF8ToByteSize(collapsed, 256, &bounded);
  return bounded;
}

size_t JSONStringBytes(std::string_view value) {
  size_t count = 2;
  for (unsigned char character : value) {
    count += character < 0x20 ? 6 : (character == '"' || character == '\\' ? 2 : 1);
  }
  return count;
}

bool TakeText(std::string_view text, Budget& characters, Budget& output) {
  return text.size() <= kMaximumStringBytes && characters.Consume(text.size()) &&
      output.Consume(JSONStringBytes(text));
}

base::ListValue Omissions(bool form_values) {
  base::ListValue values;
  for (const char* value : {"subframes", "crossOriginFrames", "fencedFrames",
                            "canvasPixels", "generatedText", "computedNames",
                            "formValues", "passwordSubtrees"}) {
    if (form_values && std::string_view(value) == "formValues") continue;
    values.Append(value);
  }
  return values;
}

// A control's value when the caller opted in. Password ancestry, file, hidden
// and payment/one-time inputs never qualify; nothing else is read.
bool FormValue(const blink::WebNode& node, std::string* value, std::optional<bool>* checked) {
  const auto control = node.DynamicTo<blink::WebFormControlElement>();
  if (!control || !SafeNode(node, false)) return false;
  using Type = blink::mojom::FormControlType;
  const auto type = control.FormControlType();
  if (type == Type::kInputFile || type == Type::kInputHidden || type == Type::kInputPassword)
    return false;
  const auto autocomplete = control.GetAttribute(blink::WebString::FromUtf8("autocomplete"));
  if (autocomplete.length() > kMaximumStringBytes ||
      SensitiveAutocomplete(base::ToLowerASCII(autocomplete.Utf8()))) return false;
  if (type == Type::kInputCheckbox || type == Type::kInputRadio) {
    const auto input = node.DynamicTo<blink::WebInputElement>();
    if (!input) return false;
    *checked = input.IsChecked();
    return true;
  }
  const auto text = control.Value();
  if (text.length() > kMaximumStringBytes) return false;
  *value = text.Utf8();
  return true;
}
}  // namespace

Inspector::Inspector(content::RenderFrame* frame) : RenderFrameObserver(frame) {
  // DEV-668: the frame's developer-world script runner lives alongside it.
  new developer::ScriptRunner(frame);
  frame->GetAssociatedInterfaceRegistry()->AddInterface<mojom::Inspector>(
      base::BindRepeating(&Inspector::Bind, weak_.GetWeakPtr()));
}

Inspector::~Inspector() { Clear(); }

void Inspector::Bind(mojo::PendingAssociatedReceiver<mojom::Inspector> receiver) {
  receiver_.reset();
  Clear();
  receiver_.Bind(std::move(receiver));
  receiver_.set_disconnect_handler(base::BindOnce(&Inspector::Clear, weak_.GetWeakPtr()));
}

void Inspector::Clear() {
  for (const auto& [id, snapshot] : snapshots_) handle_count -= snapshot.handles.size();
  snapshot_count -= snapshots_.size();
  snapshots_.clear();
  expiry_.Stop();
}

void Inspector::Forget(const std::string& snapshot) {
  auto owned = snapshots_.extract(snapshot);
  if (owned.empty()) return;
  handle_count -= owned.mapped().handles.size();
  --snapshot_count;
  if (snapshots_.empty()) expiry_.Stop();
}

void Inspector::Prune() {
  const auto now = base::TimeTicks::Now();
  std::vector<std::string> expired;
  for (const auto& [id, snapshot] : snapshots_) {
    if (snapshot.expires <= now) expired.push_back(id);
  }
  for (const auto& id : expired) Forget(id);
}

void Inspector::DidCreateNewDocument() { Clear(); }

void Inspector::OnDestruct() {
  receiver_.reset();
  Clear();
  weak_.InvalidateWeakPtrs();
  base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE, this);
}

void Inspector::Inspect(const std::string& scope, const std::string& snapshot,
                        mojom::LimitsPtr limits, InspectCallback callback) {
  const auto fail = [&callback](mojom::Status status) {
    std::move(callback).Run(status, {});
  };
  if (!ValidToken(scope) || !ValidToken(snapshot) || !limits || !ValidLimits(*limits)) {
    fail(mojom::Status::kInvalid);
    return;
  }
  Prune();
  // A newer scoped read retires old action references even when projection
  // later fails. There is no fallback to an earlier snapshot after expiry.
  std::vector<std::string> superseded;
  for (const auto& [id, owned] : snapshots_) {
    if (owned.scope == scope) superseded.push_back(id);
  }
  for (const auto& id : superseded) Forget(id);
  if (snapshots_.contains(snapshot) || snapshots_.size() >= kMaximumPageSnapshots ||
      snapshot_count >= kMaximumSnapshots || handle_count + limits->references > kMaximumHandles) {
    fail(mojom::Status::kBusy);
    return;
  }
  auto* frame = render_frame()->GetWebFrame();
  // ABI25: the browser selects which frame to inspect and admits only ordinary
  // HTTP(S) frames of its primary page; each frame owns its own snapshots.
  if (!frame) { fail(mojom::Status::kUnsupported); return; }
  auto document = frame->GetDocument();
  if (!document || !document.IsActive() || !document.IsLoaded()) {
    fail(mojom::Status::kNotReady);
    return;
  }
  if (!document.IsHTMLDocument() || !GURL(document.Url()).SchemeIsHTTPOrHTTPS()) {
    fail(mojom::Status::kUnsupported);
    return;
  }
  const auto document_id = document.Token().ToString();
  const uint64_t version = blink::DomTreeVersionForArxInspection(document);
  const auto started = base::TimeTicks::Now();
  const auto timeout = base::Milliseconds(limits->timeout_ms);
  const auto lifetime = weak_.GetWeakPtr();
  ui::AXTreeUpdate tree;
  std::set<ui::AXSerializationErrorFlag> errors;
  document.SnapshotAccessibilityTree(kMaximumTreeNodes, timeout, &tree,
      ui::AXMode(ui::AXMode::kWebContents), &errors);
  if (!lifetime || !render_frame() || render_frame()->GetWebFrame() != frame) {
    fail(mojom::Status::kStale);
    return;
  }
  if (base::TimeTicks::Now() - started >= timeout) { fail(mojom::Status::kTimeout); return; }
  // Never transform a truncated soft snapshot into a supposedly complete tree.
  if (!errors.empty() || tree.nodes.size() > kMaximumTreeNodes) {
    fail(mojom::Status::kLimit);
    return;
  }
  if (document != frame->GetDocument() || !document.IsActive() ||
      document.Token().ToString() != document_id ||
      blink::DomTreeVersionForArxInspection(document) != version) {
    fail(mojom::Status::kStale);
    return;
  }

  std::map<int, const ui::AXNodeData*> by_id;
  for (const auto& node : tree.nodes) {
    if (!by_id.emplace(node.id, &node).second) { fail(mojom::Status::kInvalid); return; }
  }
  if (!by_id.contains(tree.root_id)) { fail(mojom::Status::kInvalid); return; }
  Snapshot retained{scope, document_id, version,
                    base::TimeTicks::Now() + base::Seconds(kReferenceSeconds), {}};
  base::ListValue nodes;
  Budget text_budget(limits->text_bytes);
  Budget output_budget(limits->output_bytes);
  if (!output_budget.Consume(1024)) { fail(mojom::Status::kLimit); return; }
  std::vector<std::pair<int, int>> pending{{tree.root_id, -1}};
  std::set<int> visited;
  const size_t window_start = limits->window_start;
  const size_t window_end = window_start + limits->nodes;
  size_t projected = 0;
  // Bounds are in the main widget's viewport points; out-of-process frames
  // have their own widget, so their nodes carry no bounds.
  auto* widget = limits->bounds && frame->LocalRoot() && !frame->LocalRoot()->Parent()
      ? frame->LocalRoot()->FrameWidget() : nullptr;
  while (!pending.empty()) {
    const auto [id, parent] = pending.back();
    pending.pop_back();
    if (!visited.insert(id).second || !by_id.contains(id)) {
      fail(mojom::Status::kInvalid);
      return;
    }
    const auto& ax = *by_id.at(id);
    // Protected AX subtrees are discarded even when their DOM node is synthetic.
    if (ax.HasState(ax::mojom::State::kProtected)) continue;
    const auto node = id > 0 ? blink::WebNode::FromDomNodeId(id) : blink::WebNode();
    if (node && (!node.IsConnected() || node.GetDocument() != document || !SafeNode(node, false))) continue;
    const bool foreign_boundary = node && (IsTag(node, "iframe") || IsTag(node, "frame") ||
                                          IsTag(node, "fencedframe") || IsTag(node, "canvas"));
    int next_parent = parent;
    const bool projects = node && !ax.HasState(ax::mojom::State::kIgnored);
    const size_t index = projects ? projected++ : 0;
    if (projected > kMaximumTreeNodes) { fail(mojom::Status::kLimit); return; }
    if (projects) next_parent = static_cast<int>(index);
    if (projects && index >= window_start && index < window_end) {
      if (!output_budget.Consume(256)) {
        fail(mojom::Status::kLimit);
        return;
      }
      base::DictValue result;
      result.Set("index", static_cast<int>(index));
      if (parent >= 0) result.Set("parent", parent);
      result.Set("role", ui::ToString(ax.role));
      const auto& name = ax.GetStringAttribute(ax::mojom::StringAttribute::kName);
      if (node.IsTextNode() && ax.role == ax::mojom::Role::kStaticText && SafeNode(node, true)) {
        if (!TakeText(name, text_budget, output_budget)) { fail(mojom::Status::kLimit); return; }
        result.Set("text", name);
      } else if (!node.IsTextNode() && HasSafeOwnName(node, name)) {
        if (!TakeText(name, text_budget, output_budget)) { fail(mojom::Status::kLimit); return; }
        result.Set("name", name);
      } else if (const auto label = ButtonLabel(node); !label.empty()) {
        if (!TakeText(label, text_budget, output_budget)) { fail(mojom::Status::kLimit); return; }
        result.Set("name", label);
      }
      if (node.IsElementNode() && node.IsFocusable() && !foreign_boundary) {
        if (retained.handles.size() >= limits->references) { fail(mojom::Status::kLimit); return; }
        const auto reference = base::UnguessableToken::Create().ToString();
        Handle handle{reference, id, node};
        handle.baseline_status = blink::CaptureFormBaselineForArxInspection(
            node.DynamicTo<blink::WebElement>(), &handle.baseline);
        handle.key_baseline_status = blink::CaptureKeypressBaselineForArxInspection(
            node.DynamicTo<blink::WebElement>(), &handle.key_baseline);
        retained.handles.push_back(std::move(handle));
        result.Set("reference", reference);
      }
      if (limits->form_values) {
        std::string value;
        std::optional<bool> checked;
        if (FormValue(node, &value, &checked)) {
          if (checked) {
            result.Set("checked", *checked);
          } else {
            if (!TakeText(value, text_budget, output_budget)) { fail(mojom::Status::kLimit); return; }
            result.Set("value", value);
          }
        }
      }
      if (widget && node.IsElementNode()) {
        const auto box = widget->BlinkSpaceToEnclosedDIPs(
            node.DynamicTo<blink::WebElement>().BoundsInWidget());
        if (!box.IsEmpty()) {
          base::DictValue bounds;
          bounds.Set("x", box.x());
          bounds.Set("y", box.y());
          bounds.Set("width", box.width());
          bounds.Set("height", box.height());
          result.Set("bounds", std::move(bounds));
        }
      }
      // The browser maps this to the child frame's own ID, or drops it.
      if (node && (IsTag(node, "iframe") || IsTag(node, "frame"))) {
        if (auto* child = blink::WebFrame::FromFrameOwnerElement(node)) {
          result.Set("frame", child->GetFrameToken().ToString());
          result.Set("frameRemote", child->IsWebRemoteFrame());
        }
      }
      nodes.Append(std::move(result));
    }
    if (foreign_boundary) continue;
    if (pending.size() + ax.child_ids.size() > kMaximumTreeNodes) { fail(mojom::Status::kLimit); return; }
    for (auto child = ax.child_ids.rbegin(); child != ax.child_ids.rend(); ++child)
      pending.emplace_back(*child, next_parent);
  }
  base::DictValue result;
  result.Set("snapshotID", snapshot);
  result.Set("documentID", document_id);
  result.Set("frameID", frame->GetLocalFrameToken().ToString());
  result.Set("domVersion", base::NumberToString(version));
  result.Set("nodes", std::move(nodes));
  result.Set("windowStart", static_cast<int>(window_start));
  result.Set("totalNodes", static_cast<int>(projected));
  result.Set("omissions", Omissions(limits->form_values));
  auto json = base::WriteJson(result);
  if (!json || json->size() > limits->output_bytes) { fail(mojom::Status::kLimit); return; }
  // AX/layout work and eligibility queries can flush lifecycle work. Bind the
  // complete result and every retained handle to the same synchronous revision.
  if (document != frame->GetDocument() || !document.IsActive() ||
      document.Token().ToString() != document_id ||
      blink::DomTreeVersionForArxInspection(document) != version) {
    fail(mojom::Status::kStale);
    return;
  }
  if (base::TimeTicks::Now() - started >= timeout) { fail(mojom::Status::kTimeout); return; }
  handle_count += retained.handles.size();
  ++snapshot_count;
  snapshots_.emplace(snapshot, std::move(retained));
  if (!expiry_.IsRunning()) expiry_.Start(FROM_HERE, base::Seconds(1), this, &Inspector::Prune);
  std::move(callback).Run(mojom::Status::kSuccess, std::vector<uint8_t>(json->begin(), json->end()));
}

void Inspector::Validate(const std::string& scope, const std::string& snapshot,
                         const std::string& reference, ValidateCallback callback) {
  Prune();
  auto found = snapshots_.find(snapshot);
  auto* frame = render_frame()->GetWebFrame();
  auto document = frame ? frame->GetDocument() : blink::WebDocument();
  bool valid = found != snapshots_.end() && document && document.IsActive() &&
      document.IsLoaded() && found->second.scope == scope &&
      found->second.document == document.Token().ToString() &&
      found->second.version == blink::DomTreeVersionForArxInspection(document);
  if (valid) {
    const auto& handles = found->second.handles;
    const auto handle = std::find_if(handles.begin(), handles.end(),
        [&reference](const Handle& value) { return value.token == reference; });
    valid = handle != handles.end() && ReferenceMatches(handle->node, handle->id,
        found->second.document, found->second.version, document,
        [](int id) { return blink::WebNode::FromDomNodeId(id); },
        [](const blink::WebNode& node) { return SafeNode(node, false); },
        blink::DomTreeVersionForArxInspection);
  }
  if (!valid && found != snapshots_.end() && found->second.scope == scope) Forget(snapshot);
  std::move(callback).Run(valid ? mojom::Status::kSuccess : mojom::Status::kStale);
}

void Inspector::Click(const std::string& scope, const std::string& snapshot,
                       const std::string& reference, const std::string& operation,
                       ClickCallback callback) {
  const auto reject = [&callback](mojom::ClickStatus status) {
    std::move(callback).Run(mojom::ClickDisposition::kNotDispatched, status);
  };
  if (!ValidToken(scope) || !ValidToken(snapshot) || !ValidToken(reference) ||
      !ValidToken(operation)) { reject(mojom::ClickStatus::kInvalid); return; }
  Prune();
  auto found = snapshots_.find(snapshot);
  auto* frame = render_frame() ? render_frame()->GetWebFrame() : nullptr;
  auto document = frame ? frame->GetDocument() : blink::WebDocument();
  if (found == snapshots_.end() || found->second.scope != scope || !document ||
      !document.IsActive() || !document.IsLoaded() ||
      !document.IsHTMLDocument() || !GURL(document.Url()).SchemeIsHTTPOrHTTPS()) {
    reject(mojom::ClickStatus::kStale);
    return;
  }
  const auto handle = std::find_if(found->second.handles.begin(), found->second.handles.end(),
      [&reference](const Handle& value) { return value.token == reference; });
  if (handle == found->second.handles.end()) { reject(mojom::ClickStatus::kStale); return; }
  // Retain the exact GC node/document independently of registry mutation during
  // lifecycle work. The final callback checks current registry authority again.
  struct Context {
    base::WeakPtr<Inspector> owner;
    std::string scope, snapshot, reference, document_id;
    uint64_t version;
    int id;
    blink::WebNode node;
    blink::WebDocument document;
    blink::WebLocalFrame* frame;
  } context{weak_.GetWeakPtr(), scope, snapshot, reference, found->second.document,
      found->second.version, handle->id, handle->node, document, frame};
  const auto current = [](void* pointer) {
    const auto& value = *static_cast<Context*>(pointer);
    if (!value.owner || !value.owner->render_frame() ||
        value.owner->render_frame()->GetWebFrame() != value.frame) return false;
    auto owned = value.owner->snapshots_.find(value.snapshot);
    if (owned == value.owner->snapshots_.end() || owned->second.scope != value.scope ||
        owned->second.expires <= base::TimeTicks::Now()) return false;
    const auto retained = std::find_if(owned->second.handles.begin(), owned->second.handles.end(),
        [&value](const Handle& item) { return item.token == value.reference &&
            item.id == value.id && item.node == value.node; });
    if (retained == owned->second.handles.end()) return false;
    return ReferenceMatches(value.node, value.id, value.document_id, value.version,
        value.document, [](int id) { return blink::WebNode::FromDomNodeId(id); },
        [](const blink::WebNode& node) {
          const auto control = node.DynamicTo<blink::WebFormControlElement>();
          // File upload is outside this capability; password ancestry is denied
          // even when the page changed an original password control to text.
          return SafeNode(node, false) &&
              !(control && control.FormControlType() == blink::mojom::FormControlType::kInputFile);
        }, blink::DomTreeVersionForArxInspection);
  };
  if (!current(&context)) { reject(mojom::ClickStatus::kStale); return; }
  const auto element = context.node.DynamicTo<blink::WebElement>();
  if (!element) { reject(mojom::ClickStatus::kNotInteractable); return; }
  const auto result = blink::ClickReferenceForArxInspection(element, document,
      context.version, context.id, current, &context);
  // Dispatch may synchronously destroy the frame and this observer. Only the
  // stack-owned callback/result may be used after entering Blink dispatch.
  switch (result) {
    case blink::ArxReferenceClickResult::kDispatched:
      std::move(callback).Run(mojom::ClickDisposition::kDispatched, mojom::ClickStatus::kOK);
      return;
    case blink::ArxReferenceClickResult::kStale:
      reject(mojom::ClickStatus::kStale);
      return;
    case blink::ArxReferenceClickResult::kNotInteractable:
      reject(mojom::ClickStatus::kNotInteractable);
      return;
  }
}
void Inspector::FormAction(const std::string& scope, const std::string& snapshot,
                       const std::string& reference, const std::string& operation,
                       mojom::FormActionKind kind, const std::vector<uint8_t>& payload,
                       FormActionCallback callback) {
  const auto reject = [&callback](mojom::FormStatus status) {
    std::move(callback).Run(mojom::FormDisposition::kNotDispatched, status);
  };
  if (!ValidToken(scope) || !ValidToken(snapshot) || !ValidToken(reference) ||
      !ValidToken(operation)) { reject(mojom::FormStatus::kInvalid); return; }
  const size_t maximum = kind == mojom::FormActionKind::kReplaceText ? 32768 :
      kind == mojom::FormActionKind::kKeypress ? 32 : 4096;
  if (payload.size() > maximum) { reject(mojom::FormStatus::kLimit); return; }
  const std::string_view bytes(reinterpret_cast<const char*>(payload.data()), payload.size());
  if (!base::IsStringUTF8(bytes) || bytes.find('\0') != std::string_view::npos) {
    reject(mojom::FormStatus::kInvalidValue);
    return;
  }
  Prune();
  auto found = snapshots_.find(snapshot);
  auto* frame = render_frame() ? render_frame()->GetWebFrame() : nullptr;
  auto document = frame ? frame->GetDocument() : blink::WebDocument();
  if (found == snapshots_.end() || found->second.scope != scope || !document ||
      !document.IsActive() || !document.IsLoaded() ||
      !document.IsHTMLDocument() || !GURL(document.Url()).SchemeIsHTTPOrHTTPS()) {
    reject(mojom::FormStatus::kStale);
    return;
  }
  const auto handle = std::find_if(found->second.handles.begin(), found->second.handles.end(),
      [&reference](const Handle& value) { return value.token == reference; });
  if (handle == found->second.handles.end()) { reject(mojom::FormStatus::kStale); return; }
  const bool keypress = kind == mojom::FormActionKind::kKeypress;
  const auto baseline_status = keypress ? handle->key_baseline_status : handle->baseline_status;
  if (baseline_status != blink::ArxFormBaselineStatus::kAvailable) {
    switch (baseline_status) {
      case blink::ArxFormBaselineStatus::kLimit: reject(mojom::FormStatus::kLimit); break;
      case blink::ArxFormBaselineStatus::kUnsupported: reject(mojom::FormStatus::kUnsupportedControl); break;
      case blink::ArxFormBaselineStatus::kInvalid: reject(mojom::FormStatus::kInvalid); break;
      case blink::ArxFormBaselineStatus::kAvailable: NOTREACHED();
    }
    return;
  }
  const auto baseline = handle->baseline;
  const auto key_baseline = handle->key_baseline;
  // Retain the exact GC node/document independently of registry mutation during
  // lifecycle work. The final callback checks current registry authority again.
  struct Context {
    base::WeakPtr<Inspector> owner;
    std::string scope, snapshot, reference, document_id;
    uint64_t version;
    int id;
    blink::WebNode node;
    blink::WebDocument document;
    blink::WebLocalFrame* frame;
    bool keypress;
  } context{weak_.GetWeakPtr(), scope, snapshot, reference, found->second.document,
      found->second.version, handle->id, handle->node, document, frame, keypress};
  const auto current = [](void* pointer) {
    const auto& value = *static_cast<Context*>(pointer);
    if (!value.owner || !value.owner->render_frame() ||
        value.owner->render_frame()->GetWebFrame() != value.frame) return false;
    auto owned = value.owner->snapshots_.find(value.snapshot);
    if (owned == value.owner->snapshots_.end() || owned->second.scope != value.scope ||
        owned->second.expires <= base::TimeTicks::Now()) return false;
    const auto retained = std::find_if(owned->second.handles.begin(), owned->second.handles.end(),
        [&value](const Handle& item) { return item.token == value.reference &&
            item.id == value.id && item.node == value.node; });
    if (retained == owned->second.handles.end()) return false;
    // Keypress validates the original DOM/selection baseline inside Blink at
    // each default boundary. After its own edit, keyup may still address only
    // this retained node while scope/document/lifetime authority remains valid.
    if (value.keypress) {
      return value.node.IsConnected() && value.node.GetDocument() == value.document &&
          value.document.IsActive() && value.document.Token().ToString() == value.document_id &&
          value.frame->GetDocument() == value.document &&
          blink::WebNode::FromDomNodeId(value.id) == value.node && SafeNode(value.node, false);
    }
    return ReferenceMatches(value.node, value.id, value.document_id, value.version,
        value.document, [](int id) { return blink::WebNode::FromDomNodeId(id); },
        [](const blink::WebNode& node) {
          const auto control = node.DynamicTo<blink::WebFormControlElement>();
          // File upload is outside this capability; password ancestry is denied
          // even when the page changed an original password control to text.
          return SafeNode(node, false) &&
              !(control && control.FormControlType() == blink::mojom::FormControlType::kInputFile);
        }, blink::DomTreeVersionForArxInspection);
  };
  if (!current(&context)) { reject(mojom::FormStatus::kStale); return; }
  const auto element = context.node.DynamicTo<blink::WebElement>();
  if (!element) { reject(mojom::FormStatus::kNotInteractable); return; }
  if (keypress) {
    const auto result = blink::PerformKeypressForArxInspection(element, document,
        context.version, context.id, key_baseline, blink::WebString::FromUtf8(bytes), current, &context);
    // Never touch this observer after author listeners have run.
    switch (result) {
      case blink::ArxKeypressResult::kDispatched:
        std::move(callback).Run(mojom::FormDisposition::kDispatched, mojom::FormStatus::kOK); return;
      case blink::ArxKeypressResult::kPossiblyDispatched:
        std::move(callback).Run(mojom::FormDisposition::kPossiblyDispatched, mojom::FormStatus::kStale); return;
      case blink::ArxKeypressResult::kStale: reject(mojom::FormStatus::kStale); return;
      case blink::ArxKeypressResult::kNotInteractable: reject(mojom::FormStatus::kNotInteractable); return;
      case blink::ArxKeypressResult::kUnsupported: reject(mojom::FormStatus::kUnsupportedControl); return;
      case blink::ArxKeypressResult::kInvalidKey: reject(mojom::FormStatus::kInvalidValue); return;
      case blink::ArxKeypressResult::kBusy: reject(mojom::FormStatus::kBusy); return;
    }
  }
  const auto result = blink::PerformFormActionForArxInspection(element, document,
      context.version, context.id, baseline, static_cast<blink::ArxFormActionKind>(kind),
      blink::WebString::FromUtf8(bytes), current, &context);
  // Native setters can dispatch script that destroys the observer. Use only
  // stack-owned callback/result from here; never inspect the post-action DOM.
  switch (result) {
    case blink::ArxFormActionResult::kDispatched:
      std::move(callback).Run(mojom::FormDisposition::kDispatched, mojom::FormStatus::kOK);
      return;
    case blink::ArxFormActionResult::kUnchanged:
      std::move(callback).Run(mojom::FormDisposition::kUnchanged, mojom::FormStatus::kOK);
      return;
    case blink::ArxFormActionResult::kStale: reject(mojom::FormStatus::kStale); return;
    case blink::ArxFormActionResult::kNotInteractable: reject(mojom::FormStatus::kNotInteractable); return;
    case blink::ArxFormActionResult::kUnsupported: reject(mojom::FormStatus::kUnsupportedControl); return;
    case blink::ArxFormActionResult::kInvalidValue: reject(mojom::FormStatus::kInvalidValue); return;
    case blink::ArxFormActionResult::kOptionNotFound: reject(mojom::FormStatus::kOptionNotFound); return;
    case blink::ArxFormActionResult::kAmbiguousOption: reject(mojom::FormStatus::kAmbiguousOption); return;
    case blink::ArxFormActionResult::kLimit: reject(mojom::FormStatus::kLimit); return;
    case blink::ArxFormActionResult::kInvalid: reject(mojom::FormStatus::kInvalid); return;
  }
}
void Inspector::PointerAction(const std::string& scope, const std::string& snapshot,
                              const std::string& reference, const std::string& operation,
                              mojom::FormActionKind kind, const std::vector<uint8_t>& payload,
                              PointerActionCallback callback) {
  const auto reject = [&callback](mojom::FormStatus status) {
    std::move(callback).Run(mojom::FormDisposition::kNotDispatched, status);
  };
  if (!ValidToken(scope) || !ValidToken(snapshot) || !ValidToken(reference) ||
      !ValidToken(operation)) { reject(mojom::FormStatus::kInvalid); return; }
  PointerPayload parsed;
  const std::string_view bytes(reinterpret_cast<const char*>(payload.data()), payload.size());
  if (!ParsePointerPayload(static_cast<uint32_t>(kind), bytes, &parsed)) {
    reject(mojom::FormStatus::kInvalidValue);
    return;
  }
  // The snapshot's own ID addresses the frame's viewport; it needs a point,
  // and a real reference never takes one.
  const bool viewport = reference == snapshot;
  if (viewport != parsed.has_point) { reject(mojom::FormStatus::kInvalidValue); return; }
  Prune();
  auto found = snapshots_.find(snapshot);
  auto* frame = render_frame() ? render_frame()->GetWebFrame() : nullptr;
  auto document = frame ? frame->GetDocument() : blink::WebDocument();
  if (found == snapshots_.end() || found->second.scope != scope || !document ||
      !document.IsActive() || !document.IsLoaded() ||
      !document.IsHTMLDocument() || !GURL(document.Url()).SchemeIsHTTPOrHTTPS() ||
      found->second.document != document.Token().ToString()) {
    reject(mojom::FormStatus::kStale);
    return;
  }
  const auto& handles = found->second.handles;
  const auto lookup = [&handles](const std::string& token) {
    return std::find_if(handles.begin(), handles.end(),
                        [&token](const Handle& value) { return value.token == token; });
  };
  const auto source = viewport ? handles.end() : lookup(reference);
  const auto destination = parsed.destination.empty() ? handles.end() : lookup(parsed.destination);
  if ((!viewport && source == handles.end()) ||
      (!parsed.destination.empty() && destination == handles.end())) {
    reject(mojom::FormStatus::kStale);
    return;
  }
  struct Context {
    base::WeakPtr<Inspector> owner;
    std::string scope, snapshot, document_id;
    blink::WebDocument document;
    blink::WebLocalFrame* frame;
    std::vector<std::pair<std::string, blink::WebNode>> nodes;
  } context{weak_.GetWeakPtr(), scope, snapshot, found->second.document, document, frame, {}};
  if (source != handles.end()) context.nodes.emplace_back(source->token, source->node);
  if (destination != handles.end()) context.nodes.emplace_back(destination->token, destination->node);
  const uint64_t version = found->second.version;
  // Retained authority only: scope, snapshot lifetime, document and handles.
  // The DOM version is checked by Blink before the first event; website
  // handlers may legitimately mutate the DOM once input has begun.
  const auto current = [](void* pointer) {
    const auto& value = *static_cast<Context*>(pointer);
    if (!value.owner || !value.owner->render_frame() ||
        value.owner->render_frame()->GetWebFrame() != value.frame ||
        value.frame->GetDocument() != value.document || !value.document.IsActive() ||
        value.document.Token().ToString() != value.document_id) return false;
    auto owned = value.owner->snapshots_.find(value.snapshot);
    if (owned == value.owner->snapshots_.end() || owned->second.scope != value.scope ||
        owned->second.expires <= base::TimeTicks::Now()) return false;
    for (const auto& [token, node] : value.nodes) {
      const bool retained = std::any_of(owned->second.handles.begin(), owned->second.handles.end(),
          [&](const Handle& item) { return item.token == token && item.node == node; });
      if (!retained || !node.IsConnected() || node.GetDocument() != value.document ||
          !SafeNode(node, false)) return false;
    }
    return true;
  };
  if (!current(&context)) { reject(mojom::FormStatus::kStale); return; }
  for (const auto& [token, node] : context.nodes) {
    if (!ReferenceMatches(node, (token == reference ? source : destination)->id,
            context.document_id, version, document,
            [](int id) { return blink::WebNode::FromDomNodeId(id); },
            [](const blink::WebNode& node) { return SafeNode(node, false); },
            blink::DomTreeVersionForArxInspection)) {
      reject(mojom::FormStatus::kStale);
      return;
    }
  }
  blink::ArxPointerRequest request;
  request.kind = kind == mojom::FormActionKind::kHover ? blink::ArxPointerKind::kHover
      : kind == mojom::FormActionKind::kDrag ? blink::ArxPointerKind::kDrag
      : blink::ArxPointerKind::kClick;
  request.has_point = parsed.has_point;
  request.point = gfx::PointF(parsed.x, parsed.y);
  request.has_destination_point = parsed.has_destination_point;
  request.destination_point = gfx::PointF(parsed.destination_x, parsed.destination_y);
  request.click_count = parsed.clicks;
  request.modifiers = parsed.modifiers;
  request.steps = parsed.steps;
  const auto element = [](auto handle, auto end) {
    return handle == end ? blink::WebElement() : handle->node.template DynamicTo<blink::WebElement>();
  };
  const auto target = element(source, handles.end());
  const auto goal = element(destination, handles.end());
  if ((!viewport && !target) || (destination != handles.end() && !goal)) {
    reject(mojom::FormStatus::kNotInteractable);
    return;
  }
  const int32_t target_id = source == handles.end() ? 0 : source->id;
  const int32_t goal_id = destination == handles.end() ? 0 : destination->id;
  const auto result = blink::PerformPointerForArxInspection(document, version,
      target, target_id, goal, goal_id, request, current, &context);
  // Website handlers may have destroyed this observer; use only stack values.
  switch (result) {
    case blink::ArxPointerResult::kDispatched:
      std::move(callback).Run(mojom::FormDisposition::kDispatched, mojom::FormStatus::kOK); return;
    case blink::ArxPointerResult::kPossiblyDispatched:
      std::move(callback).Run(mojom::FormDisposition::kPossiblyDispatched, mojom::FormStatus::kStale); return;
    case blink::ArxPointerResult::kStale: reject(mojom::FormStatus::kStale); return;
    case blink::ArxPointerResult::kNotInteractable: reject(mojom::FormStatus::kNotInteractable); return;
    case blink::ArxPointerResult::kObscured: reject(mojom::FormStatus::kObscured); return;
    case blink::ArxPointerResult::kUnsupported: reject(mojom::FormStatus::kUnsupportedDocument); return;
    case blink::ArxPointerResult::kBusy: reject(mojom::FormStatus::kBusy); return;
    case blink::ArxPointerResult::kInvalid: reject(mojom::FormStatus::kInvalidValue); return;
  }
}
void Inspector::KeyboardAction(const std::string& scope, const std::string& snapshot,
                               const std::string& reference, const std::string& operation,
                               mojom::FormActionKind kind, const std::vector<uint8_t>& payload,
                               KeyboardActionCallback callback) {
  const auto reject = [&callback](mojom::FormStatus status) {
    std::move(callback).Run(mojom::FormDisposition::kNotDispatched, status);
  };
  if (!ValidToken(scope) || !ValidToken(snapshot) || !ValidToken(reference) ||
      !ValidToken(operation)) { reject(mojom::FormStatus::kInvalid); return; }
  const std::string_view bytes(reinterpret_cast<const char*>(payload.data()), payload.size());
  const bool typing = kind == mojom::FormActionKind::kType;
  uint32_t modifiers = 0;
  std::string key;
  if (!IsKeyboardKind(static_cast<uint32_t>(kind)) || !base::IsStringUTF8(bytes) ||
      bytes.find('\0') != std::string_view::npos ||
      (typing ? bytes.empty() || bytes.size() > kMaximumTypedBytes
              : !ParseKeyChord(bytes, &modifiers, &key))) {
    reject(mojom::FormStatus::kInvalidValue);
    return;
  }
  Prune();
  auto found = snapshots_.find(snapshot);
  auto* frame = render_frame() ? render_frame()->GetWebFrame() : nullptr;
  auto document = frame ? frame->GetDocument() : blink::WebDocument();
  if (found == snapshots_.end() || found->second.scope != scope || !document ||
      !document.IsActive() || !document.IsLoaded() ||
      !document.IsHTMLDocument() || !GURL(document.Url()).SchemeIsHTTPOrHTTPS() ||
      found->second.document != document.Token().ToString()) {
    reject(mojom::FormStatus::kStale);
    return;
  }
  const auto handle = std::find_if(found->second.handles.begin(), found->second.handles.end(),
      [&reference](const Handle& value) { return value.token == reference; });
  if (handle == found->second.handles.end()) { reject(mojom::FormStatus::kStale); return; }
  struct Context {
    base::WeakPtr<Inspector> owner;
    std::string scope, snapshot, reference, document_id;
    int id;
    blink::WebNode node;
    blink::WebDocument document;
    blink::WebLocalFrame* frame;
  } context{weak_.GetWeakPtr(), scope, snapshot, reference, found->second.document,
      handle->id, handle->node, document, frame};
  // Retained authority only: typing edits the DOM, so Blink checks the DOM
  // version once, before focusing, and the editing guard after that.
  const auto current = [](void* pointer) {
    const auto& value = *static_cast<Context*>(pointer);
    if (!value.owner || !value.owner->render_frame() ||
        value.owner->render_frame()->GetWebFrame() != value.frame) return false;
    auto owned = value.owner->snapshots_.find(value.snapshot);
    if (owned == value.owner->snapshots_.end() || owned->second.scope != value.scope ||
        owned->second.expires <= base::TimeTicks::Now()) return false;
    const bool retained = std::any_of(owned->second.handles.begin(), owned->second.handles.end(),
        [&value](const Handle& item) { return item.token == value.reference && item.id == value.id &&
                                              item.node == value.node; });
    return retained && value.node.IsConnected() && value.node.GetDocument() == value.document &&
        value.document.IsActive() && value.document.Token().ToString() == value.document_id &&
        value.frame->GetDocument() == value.document &&
        blink::WebNode::FromDomNodeId(value.id) == value.node && SafeNode(value.node, false);
  };
  const uint64_t version = found->second.version;
  if (!current(&context) || blink::DomTreeVersionForArxInspection(document) != version) {
    reject(mojom::FormStatus::kStale);
    return;
  }
  const auto element = context.node.DynamicTo<blink::WebElement>();
  if (!element) { reject(mojom::FormStatus::kNotInteractable); return; }
  const auto result = typing
      ? blink::TypeTextForArxInspection(element, document, version, context.id,
                                        blink::WebString::FromUtf8(bytes), current, &context)
      : blink::PressKeyForArxInspection(element, document, version, context.id,
                                        blink::WebString::FromUtf8(key), modifiers, current, &context);
  // Author listeners may have destroyed this observer; use only stack values.
  switch (result) {
    case blink::ArxKeyboardResult::kDispatched:
      std::move(callback).Run(mojom::FormDisposition::kDispatched, mojom::FormStatus::kOK); return;
    case blink::ArxKeyboardResult::kPossiblyDispatched:
      std::move(callback).Run(mojom::FormDisposition::kPossiblyDispatched, mojom::FormStatus::kStale); return;
    case blink::ArxKeyboardResult::kStale: reject(mojom::FormStatus::kStale); return;
    case blink::ArxKeyboardResult::kNotInteractable: reject(mojom::FormStatus::kNotInteractable); return;
    case blink::ArxKeyboardResult::kUnsupported: reject(mojom::FormStatus::kUnsupportedControl); return;
    case blink::ArxKeyboardResult::kInvalidKey: reject(mojom::FormStatus::kInvalidValue); return;
    case blink::ArxKeyboardResult::kBusy: reject(mojom::FormStatus::kBusy); return;
  }
}
void Inspector::FormStateAction(const std::string& scope, const std::string& snapshot,
                                const std::string& reference, const std::string& operation,
                                mojom::FormActionKind kind, const std::vector<uint8_t>& payload,
                                FormStateActionCallback callback) {
  const auto reject = [&callback](mojom::FormStatus status) {
    std::move(callback).Run(mojom::FormDisposition::kNotDispatched, status);
  };
  if (!ValidToken(scope) || !ValidToken(snapshot) || !ValidToken(reference) ||
      !ValidToken(operation)) { reject(mojom::FormStatus::kInvalid); return; }
  const std::string_view bytes(reinterpret_cast<const char*>(payload.data()), payload.size());
  const bool checked_kind = kind == mojom::FormActionKind::kSetChecked;
  std::vector<blink::WebString> values;
  if (!IsFormStateKind(static_cast<uint32_t>(kind)) || bytes.size() > kMaximumSelectValuesBytes ||
      !base::IsStringUTF8(bytes) || bytes.find('\0') != std::string_view::npos) {
    reject(mojom::FormStatus::kInvalidValue);
    return;
  }
  if (checked_kind) {
    if (bytes != "1" && bytes != "0") { reject(mojom::FormStatus::kInvalidValue); return; }
  } else {
    auto list = base::JSONReader::Read(bytes, base::JSON_PARSE_RFC);
    if (!list || !list->is_list() || list->GetList().size() > 64) {
      reject(mojom::FormStatus::kInvalidValue);
      return;
    }
    for (const auto& item : list->GetList()) {
      if (!item.is_string()) { reject(mojom::FormStatus::kInvalidValue); return; }
      values.push_back(blink::WebString::FromUtf8(item.GetString()));
    }
  }
  Prune();
  auto found = snapshots_.find(snapshot);
  auto* frame = render_frame() ? render_frame()->GetWebFrame() : nullptr;
  auto document = frame ? frame->GetDocument() : blink::WebDocument();
  if (found == snapshots_.end() || found->second.scope != scope || !document ||
      !document.IsActive() || !document.IsLoaded() ||
      !document.IsHTMLDocument() || !GURL(document.Url()).SchemeIsHTTPOrHTTPS()) {
    reject(mojom::FormStatus::kStale);
    return;
  }
  const auto handle = std::find_if(found->second.handles.begin(), found->second.handles.end(),
      [&reference](const Handle& value) { return value.token == reference; });
  if (handle == found->second.handles.end()) { reject(mojom::FormStatus::kStale); return; }
  struct Context {
    base::WeakPtr<Inspector> owner;
    std::string scope, snapshot, reference, document_id;
    uint64_t version;
    int id;
    blink::WebNode node;
    blink::WebDocument document;
    blink::WebLocalFrame* frame;
  } context{weak_.GetWeakPtr(), scope, snapshot, reference, found->second.document,
      found->second.version, handle->id, handle->node, document, frame};
  const auto current = [](void* pointer) {
    const auto& value = *static_cast<Context*>(pointer);
    if (!value.owner || !value.owner->render_frame() ||
        value.owner->render_frame()->GetWebFrame() != value.frame) return false;
    auto owned = value.owner->snapshots_.find(value.snapshot);
    if (owned == value.owner->snapshots_.end() || owned->second.scope != value.scope ||
        owned->second.expires <= base::TimeTicks::Now()) return false;
    const bool retained = std::any_of(owned->second.handles.begin(), owned->second.handles.end(),
        [&value](const Handle& item) { return item.token == value.reference && item.id == value.id &&
                                              item.node == value.node; });
    return retained && ReferenceMatches(value.node, value.id, value.document_id, value.version,
        value.document, [](int id) { return blink::WebNode::FromDomNodeId(id); },
        [](const blink::WebNode& node) { return SafeNode(node, false); },
        blink::DomTreeVersionForArxInspection);
  };
  if (!current(&context)) { reject(mojom::FormStatus::kStale); return; }
  const auto element = context.node.DynamicTo<blink::WebElement>();
  if (!element) { reject(mojom::FormStatus::kNotInteractable); return; }
  const auto result = checked_kind
      ? blink::SetCheckedForArxInspection(element, document, context.version, context.id,
                                          bytes == "1", current, &context)
      : blink::SelectValuesForArxInspection(element, document, context.version, context.id,
                                            values, current, &context);
  // Setters run input and change handlers; use only stack values from here.
  switch (result) {
    case blink::ArxFormStateResult::kDispatched:
      std::move(callback).Run(mojom::FormDisposition::kDispatched, mojom::FormStatus::kOK); return;
    case blink::ArxFormStateResult::kUnchanged:
      std::move(callback).Run(mojom::FormDisposition::kUnchanged, mojom::FormStatus::kOK); return;
    case blink::ArxFormStateResult::kStale: reject(mojom::FormStatus::kStale); return;
    case blink::ArxFormStateResult::kNotInteractable: reject(mojom::FormStatus::kNotInteractable); return;
    case blink::ArxFormStateResult::kUnsupported: reject(mojom::FormStatus::kUnsupportedControl); return;
    case blink::ArxFormStateResult::kInvalidValue: reject(mojom::FormStatus::kInvalidValue); return;
    case blink::ArxFormStateResult::kOptionNotFound: reject(mojom::FormStatus::kOptionNotFound); return;
    case blink::ArxFormStateResult::kAmbiguousOption: reject(mojom::FormStatus::kAmbiguousOption); return;
  }
}
void Inspector::Scroll(const std::string& scope, const std::string& snapshot,
                       const std::string& reference, const std::string& operation,
                       mojom::ScrollAxis axis, double delta_css_pixels,
                       ScrollCallback callback) {
  const auto reject = [&callback](mojom::ScrollStatus status) {
    std::move(callback).Run(mojom::ScrollDisposition::kNotDispatched, status);
  };
  if (!ValidToken(scope) || !ValidToken(snapshot) || !ValidToken(reference) ||
      !ValidToken(operation)) { reject(mojom::ScrollStatus::kInvalid); return; }
  if ((axis != mojom::ScrollAxis::kHorizontal && axis != mojom::ScrollAxis::kVertical) ||
      !std::isfinite(delta_css_pixels) || std::abs(delta_css_pixels) > 8192) {
    reject(mojom::ScrollStatus::kInvalidDelta);
    return;
  }
  Prune();
  auto found = snapshots_.find(snapshot);
  auto* frame = render_frame() ? render_frame()->GetWebFrame() : nullptr;
  auto document = frame ? frame->GetDocument() : blink::WebDocument();
  if (found == snapshots_.end() || found->second.scope != scope || !document ||
      !document.IsActive() || !document.IsLoaded() ||
      !document.IsHTMLDocument() || !GURL(document.Url()).SchemeIsHTTPOrHTTPS()) {
    reject(mojom::ScrollStatus::kStale);
    return;
  }
  const auto handle = std::find_if(found->second.handles.begin(), found->second.handles.end(),
      [&reference](const Handle& value) { return value.token == reference; });
  if (handle == found->second.handles.end()) { reject(mojom::ScrollStatus::kStale); return; }
  // Retain the exact GC node/document independently of registry mutation during
  // lifecycle work. The final callback checks current registry authority again.
  struct Context {
    base::WeakPtr<Inspector> owner;
    std::string scope, snapshot, reference, document_id;
    uint64_t version;
    int id;
    blink::WebNode node;
    blink::WebDocument document;
    blink::WebLocalFrame* frame;
  } context{weak_.GetWeakPtr(), scope, snapshot, reference, found->second.document,
      found->second.version, handle->id, handle->node, document, frame};
  const auto current = [](void* pointer) {
    const auto& value = *static_cast<Context*>(pointer);
    if (!value.owner || !value.owner->render_frame() ||
        value.owner->render_frame()->GetWebFrame() != value.frame) return false;
    auto owned = value.owner->snapshots_.find(value.snapshot);
    if (owned == value.owner->snapshots_.end() || owned->second.scope != value.scope ||
        owned->second.expires <= base::TimeTicks::Now()) return false;
    const auto retained = std::find_if(owned->second.handles.begin(), owned->second.handles.end(),
        [&value](const Handle& item) { return item.token == value.reference &&
            item.id == value.id && item.node == value.node; });
    if (retained == owned->second.handles.end()) return false;
    return ReferenceMatches(value.node, value.id, value.document_id, value.version,
        value.document, [](int id) { return blink::WebNode::FromDomNodeId(id); },
        [](const blink::WebNode& node) {
          const auto control = node.DynamicTo<blink::WebFormControlElement>();
          // File upload is outside this capability; password ancestry is denied
          // even when the page changed an original password control to text.
          return SafeNode(node, false) &&
              !(control && control.FormControlType() == blink::mojom::FormControlType::kInputFile);
        }, blink::DomTreeVersionForArxInspection);
  };
  if (!current(&context)) { reject(mojom::ScrollStatus::kStale); return; }
  const auto element = context.node.DynamicTo<blink::WebElement>();
  if (!element) { reject(mojom::ScrollStatus::kNotInteractable); return; }
  const auto result = blink::ScrollReferenceForArxInspection(element, document,
      context.version, context.id, static_cast<blink::ArxScrollAxis>(axis),
      delta_css_pixels, current, &context);
  // The operation may invalidate its document; use only stack-owned values.
  switch (result) {
    case blink::ArxScrollResult::kDispatched:
      std::move(callback).Run(mojom::ScrollDisposition::kDispatched, mojom::ScrollStatus::kOK);
      return;
    case blink::ArxScrollResult::kUnchanged:
      std::move(callback).Run(mojom::ScrollDisposition::kUnchanged, mojom::ScrollStatus::kOK);
      return;
    case blink::ArxScrollResult::kStale: reject(mojom::ScrollStatus::kStale); return;
    case blink::ArxScrollResult::kNotInteractable: reject(mojom::ScrollStatus::kNotInteractable); return;
    case blink::ArxScrollResult::kNoContainer: reject(mojom::ScrollStatus::kNoContainer); return;
    case blink::ArxScrollResult::kInvalidDelta: reject(mojom::ScrollStatus::kInvalidDelta); return;
    case blink::ArxScrollResult::kLimit: reject(mojom::ScrollStatus::kLimit); return;
  }
}

}  // namespace arx::inspection
