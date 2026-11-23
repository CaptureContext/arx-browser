#include <cassert>
#include <initializer_list>

namespace blink {
class Event {
 public:
  explicit Event(const Event* underlying = nullptr) : underlying_(underlying) {}
  const Event* UnderlyingEvent() const { return underlying_; }
  void SetDefaultHandled() { handled = true; }
  bool handled = false;
 private:
  const Event* underlying_;
};
}

// GUARD_HEADER
// GUARD_IMPL

namespace blink {
enum class DispatchEventResult {
  kNotCanceled, kCanceledByEventHandler, kCanceledByDefaultEventHandler
};
enum class ArxKeypressResult { kDispatched, kPossiblyDispatched };
struct WebInputEvent { enum class Type { kRawKeyDown, kChar, kKeyUp }; };
namespace ui { constexpr int VKEY_RETURN = 13; }
enum class Mode {
  kAllowed, kNotCanceled, kAuthorCancel, kEditorHandled, kStaleFocus, kStaleSelection,
  kBeforeInputRedirect
};
struct State {
  int source = 0, other = 0;
  const int* focused = &source;
  bool selection = true;
  bool alive = true;
  int down = 0, character = 0, up = 0, edits = 0, author_edits = 0;
  bool Bound() const { return alive && focused == &source && selection; }
  const int* FocusedElement() const { return focused; }
};

void DefaultFallback(Event* event) {
// NATIVE_FALLBACK
  assert(false && "guarded event reached page/focus fallback");
}

ArxKeypressResult Run(State& state, Mode mode, bool enter = false) {
  const auto identity = [&] { return state.alive; };
  const auto bound = [&] { return state.Bound(); };
  auto& document = state;
  const auto* element = &state.source;
  struct Key { bool character; int virtual_key; } key{!enter, enter ? ui::VKEY_RETURN : 0};
  ArxKeypressGuard guard([](void* value) { return static_cast<State*>(value)->Bound(); }, &state);
  const auto dispatch = [&](WebInputEvent::Type type, bool suppress_default) {
    Event event;
    guard.SetEvent(&event);
    assert(!guard.fallback_handled());
    if (suppress_default) event.SetDefaultHandled();
    {
      ArxKeypressGuard::AuthorDispatch author;
      if (type == WebInputEvent::Type::kRawKeyDown) {
        ++state.down;
        if (mode == Mode::kAuthorCancel) return DispatchEventResult::kCanceledByEventHandler;
      } else if (type == WebInputEvent::Type::kChar) {
        ++state.character;
      } else {
        ++state.up;
      }
      ArxKeypressGuard::DefaultAction native(&event);
      if (!native.allowed()) event.SetDefaultHandled();
      if (!event.handled) {
        if (type == WebInputEvent::Type::kRawKeyDown) {
          if (mode == Mode::kEditorHandled) event.SetDefaultHandled();
          if (!event.handled && mode != Mode::kNotCanceled) DefaultFallback(&event);
        } else if (type == WebInputEvent::Type::kChar) {
          if (mode == Mode::kBeforeInputRedirect) {
            ArxKeypressGuard::AuthorDispatch beforeinput;
            state.selection = false;
            assert(ArxKeypressGuard::BeforeEdit());
            ++state.author_edits;
          }
          if (ArxKeypressGuard::BeforeEdit()) ++state.edits;
          event.SetDefaultHandled();
        }
      }
    }
    if (type == WebInputEvent::Type::kRawKeyDown) {
      if (mode == Mode::kStaleFocus) state.focused = &state.other;
      if (mode == Mode::kStaleSelection) state.selection = false;
    }
    return event.handled ? DispatchEventResult::kCanceledByDefaultEventHandler
                         : DispatchEventResult::kNotCanceled;
  };
// HELPER_CONTINUATION

void ExactDefaultScopeOnly() {
  bool current = true;
  ArxKeypressGuard guard([](void* value) { return *static_cast<bool*>(value); }, &current);
  Event key, text(&key), unrelated;
  guard.SetEvent(&key);
  ArxKeypressGuard::MarkFallbackHandled(&key);
  assert(!guard.fallback_handled());
  {
    ArxKeypressGuard::DefaultAction native(&key);
    {
      ArxKeypressGuard::AuthorDispatch author;
      ArxKeypressGuard::MarkFallbackHandled(&key);
      assert(!guard.fallback_handled());
    }
    {
      ArxKeypressGuard::DefaultAction nested(&text);
      assert(nested.allowed() && ArxKeypressGuard::IsGuardedEvent(&text));
      ArxKeypressGuard::MarkFallbackHandled(&text);
      ArxKeypressGuard::MarkFallbackHandled(&key);
      assert(!guard.fallback_handled());
    }
    {
      ArxKeypressGuard::DefaultAction other(&unrelated);
      ArxKeypressGuard::MarkFallbackHandled(&key);
      assert(!guard.fallback_handled());
    }
    ArxKeypressGuard::MarkFallbackHandled(&key);
    assert(guard.fallback_handled());
  }
  guard.SetEvent(&text);
  assert(!guard.fallback_handled());
  {
    ArxKeypressGuard::DefaultAction native(&text);
    current = false;
    ArxKeypressGuard::MarkFallbackHandled(&text);
    assert(!guard.fallback_handled() && guard.suppressed());
    current = true;
    ArxKeypressGuard::MarkFallbackHandled(&text);
    assert(!guard.fallback_handled());
  }
}
}

int main() {
  using namespace blink;
  for (auto mode : {Mode::kAllowed, Mode::kNotCanceled}) {
    for (bool enter : {false, true}) {
      State state;
      assert(Run(state, mode, enter) == ArxKeypressResult::kDispatched);
      assert(state.down == 1 && state.character == 1 && state.up == 1 && state.edits == 1);
    }
  }
  for (auto mode : {Mode::kAuthorCancel, Mode::kEditorHandled}) {
    State state;
    assert(Run(state, mode) == ArxKeypressResult::kDispatched);
    assert(state.down == 1 && state.character == 0 && state.up == 1 && state.edits == 0);
  }
  for (auto mode : {Mode::kStaleFocus, Mode::kStaleSelection}) {
    State state;
    assert(Run(state, mode) == ArxKeypressResult::kPossiblyDispatched);
    assert(state.down == 1 && state.character == 0 && state.up == 0 && state.edits == 0);
  }
  {
    State state;
    assert(Run(state, Mode::kBeforeInputRedirect) == ArxKeypressResult::kPossiblyDispatched);
    assert(state.character == 1 && state.edits == 0 && state.author_edits == 1 && state.up == 0);
  }
  ExactDefaultScopeOnly();
}
