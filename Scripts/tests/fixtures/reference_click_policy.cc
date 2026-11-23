#include <cassert>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>
#include "click_policy.h"
#include "pointer_policy.h"
#include "keyboard_policy.h"
#include "policy.h"
#include "ChromiumBridge.h"

namespace blink {
enum class EVisibility { kVisible, kHidden };
enum class EPointerEvents { kAuto, kNone };
enum class EContentVisibility { kVisible, kHidden };
enum class DocumentUpdateReason { kInput };
enum class SimulatedClickCreationScope { kFromAccessibility };
enum class ArxReferenceClickResult { kStale, kNotInteractable, kDispatched };
struct Style {
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
struct Document;
struct LocalFrame { Document* document; Document* GetDocument() const { return document; } };
struct Element;
struct Document {
  LocalFrame* frame = nullptr;
  uint64_t version = 1;
  bool active = true;
  std::function<void()> preflight, layout;
  bool IsActive() const { return active; }
  LocalFrame* GetFrame() const { return frame; }
  uint64_t DomTreeVersion() const { return version; }
  void UpdateStyleAndLayoutTreeForElement(Element*, DocumentUpdateReason) {
    if (layout) layout();
  }
};
struct Element {
  Document* document;
  Element* parent = nullptr;
  Style style;
  Layout layout;
  bool connected = true, disabled = false, has_layout = true, password = false;
  int dispatches = 0;
  std::function<void()> on_dispatch;
  Document& GetDocument() const { return *document; }
  bool isConnected() const { return connected; }
  const Style* GetComputedStyle() const { return &style; }
  Layout* GetLayoutObject() { return has_layout ? &layout : nullptr; }
  void DispatchSimulatedClick(void*, SimulatedClickCreationScope) {
    ++dispatches;
    if (on_dispatch) on_dispatch();
  }
};
struct WebDocument {
  Document* pointer;
  explicit operator bool() const { return pointer; }
  bool operator==(const WebDocument&) const = default;
};
std::map<int, Element*> nodes;
struct WebNode {
  Element* pointer = nullptr;
  explicit operator bool() const { return pointer; }
  bool operator==(const WebNode&) const = default;
  static WebNode FromDomNodeId(int id) { return {nodes[id]}; }
  WebDocument GetDocument() const { return {pointer->document}; }
  WebNode ParentOrShadowHostNode() const { return {pointer->parent}; }
  template<typename T> T DynamicTo() const { return T{{pointer}}; }
};
struct WebElement : WebNode {
  template<typename T> const T* ConstUnwrap() const { return pointer; }
  std::optional<int> InteractionDisallowedReason(bool) const {
    auto& document = pointer->GetDocument();
    if (document.preflight) document.preflight();
    return pointer->disabled ? std::optional<int>(1) : std::nullopt;
  }
};
// PRODUCTION_BLINK_CLICK
}  // namespace blink

using arx::inspection::ClickBinding;
using arx::inspection::ClickReceipts;
using arx::inspection::Dispatch;

void AtomicDispatch() {
  using namespace blink;
  for (int scenario = 0; scenario < 17; ++scenario) {
    Document document;
    Document replacement;
    LocalFrame frame{&document};
    document.frame = &frame;
    Element target{&document};
    Element parent{&document};
    Element reused{&document};
    target.parent = &parent;
    nodes[7] = &target;
    bool authorized = true;
    struct Context { Element* target; bool* authorized; } context{&target, &authorized};
    const auto current = [](void* pointer) {
      const auto& value = *static_cast<Context*>(pointer);
      return *value.authorized && !value.target->password;
    };
    switch (scenario) {
      case 1: document.preflight = [&] { ++document.version; }; break;
      case 2: document.layout = [&] { ++document.version; }; break;
      case 3: document.layout = [&] { nodes[7] = &reused; }; break;
      case 4: document.layout = [&] { target.connected = false; }; break;
      case 5: document.layout = [&] { frame.document = &replacement; }; break;
      case 6: document.layout = [&] { authorized = false; }; break;
      case 7: document.layout = [&] { target.password = true; }; break;
      case 8: target.disabled = true; break;
      case 9: document.layout = [&] { target.style.visibility = EVisibility::kHidden; }; break;
      case 10: document.layout = [&] { parent.style.opacity = 0; }; break;
      case 11: parent.style.inert = true; break;
      case 12: parent.style.content = EContentVisibility::kHidden; break;
      case 13: target.layout.bounds.empty = true; break;
      case 14: target.style.pointer = EPointerEvents::kNone; break;
      case 16: target.disabled = true; document.preflight = [&] { ++document.version; }; break;
      case 15: target.on_dispatch = [&] { frame.document = &replacement; target.connected = false; }; break;
    }
    const auto result = ClickReferenceForArxInspection(WebElement{{&target}}, {&document},
        1, 7, current, &context);
    const bool committed = scenario == 0 || scenario == 15;
    assert((result == ArxReferenceClickResult::kDispatched) == committed);
    assert(target.dispatches == (committed ? 1 : 0));
    if (scenario == 16) assert(result == ArxReferenceClickResult::kStale);
  }
}

void ReceiptBounds() {
  ClickReceipts receipts;
  ClickBinding binding{1, "scope", "snapshot", "reference"};
  assert(receipts.Reserve("first", binding));
  assert(!receipts.Reserve("first", binding));
  assert(receipts.Duplicate("first", binding) == Dispatch::kNone);
  receipts.Record("first", Dispatch::kPossible);
  assert(receipts.Duplicate("first", binding) == Dispatch::kPossible);
  receipts.Record("first", Dispatch::kDispatched);
  assert(receipts.Duplicate("first", binding) == Dispatch::kDispatched);
  auto other = binding;
  other.scope = "other";
  assert(receipts.Duplicate("first", other) == Dispatch::kPossible);
  for (size_t i = 1; i < arx::inspection::kMaximumScopeClickReceipts; ++i)
    assert(receipts.Reserve(std::to_string(i), binding));
  assert(!receipts.Reserve("overflow", binding));
  for (size_t i = arx::inspection::kMaximumScopeClickReceipts;
       i < arx::inspection::kMaximumClickReceipts; ++i) {
    other.scope = "scope" + std::to_string(i / arx::inspection::kMaximumScopeClickReceipts);
    assert(receipts.Reserve(std::to_string(i), other));
  }
  other.scope = "new grant after reconnect";
  assert(!receipts.Reserve("exhausted", other));
  assert(receipts.Duplicate("first", binding) == Dispatch::kDispatched);
}

#define FROM_HERE 0
namespace base {
using Job = std::function<void()>;
std::vector<Job> immediate, delayed;
struct SingleThreadTaskRunner {
  static SingleThreadTaskRunner* GetCurrentDefault() { static SingleThreadTaskRunner runner; return &runner; }
  void PostTask(int, Job job) { immediate.push_back(std::move(job)); }
  void PostDelayedTask(int, Job job, int) { delayed.push_back(std::move(job)); }
};
template<class Function, class... Arguments>
auto BindOnce(Function function, Arguments... arguments) {
  return [=](auto... rest) { return std::invoke(function, arguments..., rest...); };
}
int Milliseconds(uint32_t value) { return static_cast<int>(value); }
void Drain() {
  while (!immediate.empty()) {
    auto jobs = std::exchange(immediate, {});
    for (auto& job : jobs) job();
  }
}
}
namespace arx::inspection::mojom {
enum class ClickDisposition { kNotDispatched, kDispatched, kPossiblyDispatched };
enum class ClickStatus { kOK, kUnavailable, kNotReady, kUnsupported, kStale };
enum class ScrollAxis { kHorizontal, kVertical };
enum class ScrollDisposition { kNotDispatched, kDispatched, kPossiblyDispatched, kUnchanged };
enum class ScrollStatus { kOK, kUnavailable, kNotReady, kUnsupported, kStale };
enum class FormActionKind {
  kReplaceText = 1, kSelectValue = 2, kHover = 8, kPointerClick = 16, kDrag = 32, kType = 64, kKeyChord = 128,
  kSelectValues = 256, kSetChecked = 512,
};
enum class FormDisposition { kNotDispatched, kDispatched, kPossiblyDispatched, kUnchanged };
enum class FormStatus { kOK, kUnavailable, kNotReady, kUnsupported, kStale };
}
namespace arx {
using ReferenceClickReply = void (*)(uint64_t, uint64_t, int32_t, int32_t);
size_t physical_click_count = 0;
inspection::ClickReceipts& ClickReceipts() { static inspection::ClickReceipts receipts; return receipts; }
struct Result { int32_t disposition; int32_t status; };
std::vector<Result> results;
void Reply(uint64_t, uint64_t, int32_t disposition, int32_t status) {
  results.push_back({disposition, status});
}
std::vector<uint64_t> armed_choosers;
void ArmFileChooser(uint64_t page) { armed_choosers.push_back(page); }
void ReplyClickLater(ReferenceClickReply reply, uint64_t request, uint64_t page,
                    int32_t disposition, int32_t status) {
  base::immediate.push_back([=] { reply(request, page, disposition, status); });
}
struct Remote {
  bool is_bound() const { return true; }
  Remote* operator->() { return this; }
  template<class Callback>
  void Click(const std::string&, const std::string&, const std::string&, const std::string&, Callback) {}
  template<class Callback>
  void Scroll(const std::string&, const std::string&, const std::string&, const std::string&,
              inspection::mojom::ScrollAxis, double, Callback) {}
  template<class Callback>
  void FormAction(const std::string&, const std::string&, const std::string&, const std::string&,
                  inspection::mojom::FormActionKind, const std::vector<uint8_t>&, Callback) {}
  template<class Callback>
  void PointerAction(const std::string&, const std::string&, const std::string&, const std::string&,
                     inspection::mojom::FormActionKind, const std::vector<uint8_t>&, Callback) {
    ++pointer_actions;
  }
  template<class Callback>
  void KeyboardAction(const std::string&, const std::string&, const std::string&, const std::string&,
                      inspection::mojom::FormActionKind, const std::vector<uint8_t>&, Callback) {
    ++keyboard_actions;
  }
  int keyboard_actions = 0;
  template<class Callback>
  void FormStateAction(const std::string&, const std::string&, const std::string&, const std::string&,
                       inspection::mojom::FormActionKind, const std::vector<uint8_t>&, Callback) {
    ++form_state_actions;
  }
  int form_state_actions = 0;
  int pointer_actions = 0;
};
class Inspection {
 public:
  // PRODUCTION_PENDING
  Inspection() : weak_{this} {}
  bool Current(const std::string&, const std::string&) { return current; }
  // ABI25 routes each action to its snapshot's frame; the fake has one frame.
  Remote* ActionRemote(const std::string&, const std::string&) { return current ? &remote_ : nullptr; }
  struct Snapshots {
    struct Entry { std::string frame = "frame"; } entry;
    const Entry& at(const std::string&) const { return entry; }
  } snapshots_;
  void Forget(const std::string&) { ++forgot; }
  // PRODUCTION_SUBMIT_CANCEL
  // PRODUCTION_RECEIVE_DELIVER
  bool current = true;
  int forgot = 0;
  uint64_t page_ = 1;
  std::map<uint64_t, PendingClick> clicks_;
  Remote remote_;
  struct Weak { Inspection* value; Inspection* GetWeakPtr() { return value; } } weak_;
};
void PhysicalLifetime() {
  using inspection::mojom::ClickDisposition;
  using inspection::mojom::ClickStatus;
  Inspection page;
  ClickReceipts().Reserve("a", {1, "scope", "snapshot", "ref"});
  page.Click(1, "scope", "snapshot", "ref", "a", 2000, Reply);
  assert(physical_click_count == 1);
  page.CancelClick(1);
  base::Drain();
  assert(results.back().disposition == ARX_CLICK_POSSIBLY_DISPATCHED);
  assert(page.clicks_.size() == 1 && physical_click_count == 1);
  page.Click(2, "scope", "snapshot", "ref", "b", 2000, Reply);
  base::Drain();
  assert(results.back().status == ARX_CLICK_BUSY);
  page.ReceivedClick(1, ClickDisposition::kDispatched, ClickStatus::kOK);
  base::Drain();
  assert(page.clicks_.empty() && physical_click_count == 0);
  assert(ClickReceipts().Find("a")->disposition == Dispatch::kDispatched);
  assert(results.size() == 2);  // Late completion never replies twice.
  page.Click(3, "scope", "snapshot", "ref", "c", 2000, Reply);
  page.ReceivedClick(3, ClickDisposition::kDispatched, ClickStatus::kOK);
  page.CancelClick(3, ARX_CLICK_STALE);
  base::Drain();
  assert(results.back().disposition == ARX_CLICK_DISPATCHED);
  assert(results.back().status == ARX_CLICK_STALE);
  assert(page.clicks_.empty() && physical_click_count == 0);
  physical_click_count = inspection::kMaximumPhysicalClicks;
  page.Click(4, "scope", "snapshot", "ref", "d", 2000, Reply);
  base::Drain();
  assert(results.back().status == ARX_CLICK_BUSY);
  assert(page.clicks_.empty());
  physical_click_count = 0;
  ClickReceipts().Reserve("scroll", {1, "scope", "snapshot", "ref", 3});
  page.Scroll(40, "scope", "snapshot", "ref", "scroll", ARX_SCROLL_VERTICAL, 80, 2000, Reply);
  assert(physical_click_count == 1);
  page.FormAction(41, "scope", "snapshot", "ref", "blocked-form", ARX_FORM_REPLACE_TEXT, {}, 2000, Reply);
  base::Drain();
  assert(results.back().status == ARX_FORM_BUSY);
  page.CancelClick(40, ARX_CLICK_TIMEOUT);
  base::Drain();
  assert(results.back().disposition == ARX_SCROLL_POSSIBLY_DISPATCHED);
  assert(physical_click_count == 1);
  page.ReceivedScroll(40, inspection::mojom::ScrollDisposition::kUnchanged,
                       inspection::mojom::ScrollStatus::kOK);
  base::Drain();
  assert(physical_click_count == 0);
  assert(ClickReceipts().Find("scroll")->disposition == Dispatch::kUnchanged);
  page.Scroll(42, "scope", "snapshot", "ref", "scroll2", ARX_SCROLL_VERTICAL, 80, 2000, Reply);
  page.ReceivedScroll(42, inspection::mojom::ScrollDisposition::kUnchanged,
                       inspection::mojom::ScrollStatus::kOK);
  page.CancelClick(42, ARX_CLICK_STALE);
  base::Drain();
  assert(results.back().disposition == ARX_SCROLL_UNCHANGED);
  assert(results.back().status == ARX_CLICK_STALE && physical_click_count == 0);
  results.clear();
  ClickReceipts().Reserve("form", {1, "scope", "snapshot", "ref", 1});
  page.FormAction(5, "scope", "snapshot", "ref", "form", ARX_FORM_REPLACE_TEXT, {}, 2000, Reply);
  page.Click(6, "scope", "snapshot", "ref", "click", 2000, Reply);
  base::Drain();
  assert(results.size() == 1 && results.back().status == ARX_CLICK_BUSY);
  assert(page.clicks_.size() == 1 && physical_click_count == 1);
  page.CancelClick(5);
  base::Drain();
  page.FormAction(7, "scope", "snapshot", "ref", "form2", ARX_FORM_SELECT_VALUE, {}, 2000, Reply);
  base::Drain();
  assert(results.back().status == ARX_FORM_BUSY);
  page.ReceivedFormAction(5, inspection::mojom::FormDisposition::kUnchanged,
                         inspection::mojom::FormStatus::kOK);
  base::Drain();
  assert(page.clicks_.empty() && physical_click_count == 0);
  assert(ClickReceipts().Find("form")->disposition == Dispatch::kUnchanged);
  auto wrong_kind = inspection::ClickBinding{1, "scope", "snapshot", "ref"};
  assert(ClickReceipts().Duplicate("form", wrong_kind) == Dispatch::kPossible);
  auto changed_payload = inspection::ClickBinding{1, "scope", "snapshot", "ref", 1};
  changed_payload.payload_digest[0] = 1;
  assert(ClickReceipts().Duplicate("form", changed_payload) == Dispatch::kPossible);

}
// DEV-669: only a dispatched, successful hover keeps its snapshot.
void PointerSnapshots() {
  using inspection::mojom::FormDisposition;
  using inspection::mojom::FormStatus;
  Inspection page;
  const auto run = [&](uint64_t request, const char* operation, ArxFormActionKind kind,
                       FormDisposition disposition, FormStatus status) {
    ClickReceipts().Reserve(operation, {1, "scope", "snapshot", "ref", static_cast<uint32_t>(kind)});
    page.FormAction(request, "scope", "snapshot", "ref", operation, kind, {}, 2000, Reply);
    page.ReceivedFormAction(request, disposition, status);
    base::Drain();
    assert(page.clicks_.empty() && physical_click_count == 0);
  };
  run(50, "hover", ARX_FORM_HOVER, FormDisposition::kDispatched, FormStatus::kOK);
  assert(page.remote_.pointer_actions == 1 && page.forgot == 0);
  run(51, "hover-again", ARX_FORM_HOVER, FormDisposition::kDispatched, FormStatus::kOK);
  assert(page.remote_.pointer_actions == 2 && page.forgot == 0);
  run(52, "hover-stale", ARX_FORM_HOVER, FormDisposition::kNotDispatched, FormStatus::kStale);
  assert(page.forgot == 1);
  run(53, "hover-partial", ARX_FORM_HOVER, FormDisposition::kPossiblyDispatched, FormStatus::kStale);
  assert(page.forgot == 2);
  run(54, "click", ARX_FORM_POINTER_CLICK, FormDisposition::kDispatched, FormStatus::kOK);
  assert(page.remote_.pointer_actions == 5 && page.forgot == 3);
  run(55, "drag", ARX_FORM_DRAG, FormDisposition::kDispatched, FormStatus::kOK);
  assert(page.forgot == 4);
  // Real pointer input arms the page's file chooser; a text setter doesn't.
  assert(armed_choosers.size() == 6);
  run(56, "text", ARX_FORM_REPLACE_TEXT, FormDisposition::kDispatched, FormStatus::kOK);
  assert(armed_choosers.size() == 6);
  assert(page.remote_.pointer_actions == 6 && page.forgot == 5);
  run(58, "type", ARX_FORM_TYPE, FormDisposition::kDispatched, FormStatus::kOK);
  run(59, "chord", ARX_FORM_KEY_CHORD, FormDisposition::kDispatched, FormStatus::kOK);
  assert(page.remote_.keyboard_actions == 2 && page.remote_.pointer_actions == 6 && page.forgot == 7);
  run(60, "checked", ARX_FORM_SET_CHECKED, FormDisposition::kUnchanged, FormStatus::kOK);
  run(61, "values", ARX_FORM_SELECT_VALUES, FormDisposition::kDispatched, FormStatus::kOK);
  assert(page.remote_.form_state_actions == 2 && page.forgot == 9);
  // A cancelled hover keeps today's rule: uncertainty consumes the snapshot.
  ClickReceipts().Reserve("hover-cancel", {1, "scope", "snapshot", "ref", 8});
  page.FormAction(57, "scope", "snapshot", "ref", "hover-cancel", ARX_FORM_HOVER, {}, 2000, Reply);
  page.CancelClick(57);
  base::Drain();
  assert(page.forgot == 10);
}
}
int main(int argc, char** argv) {
  assert(argc == 2);
  const std::string scenario = argv[1];
  if (scenario == "atomic") AtomicDispatch();
  else if (scenario == "receipts") ReceiptBounds();
  else if (scenario == "physical") arx::PhysicalLifetime();
  else if (scenario == "pointer") arx::PointerSnapshots();
  else return 1;
}
