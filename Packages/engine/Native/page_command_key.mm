#include "chrome/browser/arx/page_command_key.h"

#import <AppKit/AppKit.h>

#include "third_party/blink/public/common/input/web_input_event.h"
#include "third_party/blink/public/common/input/web_keyboard_event.h"
#include "third_party/blink/public/mojom/input/input_event_result.mojom-shared.h"

namespace arx {

PageCommandKey::PageCommandKey(ConsumedCallback consumed)
    : consumed_(std::move(consumed)) {}

PageCommandKey::~PageCommandKey() = default;

namespace {

bool IsShortcutKey(NSEvent* native) {
  // DEV-1332: every combination Arx can bind. ⌘ or ⌃ with any key, or an F-key with or without
  // modifiers. Plain typing (no ⌘ or ⌃), ⌥ characters and Escape are never followed.
  const NSEventModifierFlags flags = native.modifierFlags;
  if (flags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) return true;
  NSString* characters = native.charactersIgnoringModifiers;
  if (characters.length != 1) return false;
  const unichar character = [characters characterAtIndex:0];
  return character >= NSF1FunctionKey && character <= NSF12FunctionKey;
}

}  // namespace

// static
bool PageCommandKey::IsCommandKey(const input::NativeWebKeyboardEvent& event) {
  NSEvent* native = event.os_event.Get();
  return !event.skip_if_unhandled && native && native.type == NSEventTypeKeyDown &&
      IsShortcutKey(native) && event.GetType() == blink::WebInputEvent::Type::kRawKeyDown;
}

}  // namespace arx

// DEV-1332: tells the app this engine follows every key combination Arx can bind, not only ⌘
// ones, so a shortcut without ⌘ can go to the page first. Outside the ABI table: engines built
// before it lack the symbol, and the app keeps such shortcuts Arx's.
bool ArxEngineFollowsAllShortcutKeys(void) {
  return true;
}

namespace arx {

// static
PageCommandKey::Key PageCommandKey::KeyFor(const input::NativeWebKeyboardEvent& event) {
  NSEvent* native = event.os_event.Get();
  if (!native) return {};
  return {native.keyCode,
          static_cast<uint64_t>(native.modifierFlags &
                                NSEventModifierFlagDeviceIndependentFlagsMask),
          native.timestamp};
}

void PageCommandKey::Follow(content::RenderWidgetHost* widget,
                            const input::NativeWebKeyboardEvent& event,
                            uint64_t generation) {
  if (!widget || !IsCommandKey(event)) return;
  if (!input_observation_.IsObservingSource(widget)) {
    Clear();
    input_observation_.Observe(widget);
    widget_observation_.Observe(widget);
  }
  if (followed_.size() == kLimit) followed_.pop_front();
  Followed followed;
  followed.event = event.os_event;
  followed.key = KeyFor(event);
  followed.key.generation = generation;
  followed.windows_key_code = event.windows_key_code;
  followed.modifiers = event.GetModifiers();
  followed.web_timestamp = event.TimeStamp();
  followed_.push_back(std::move(followed));
}

std::optional<PageCommandKey::Key> PageCommandKey::TakeUnconsumed(
    const input::NativeWebKeyboardEvent& event) {
  for (auto it = followed_.begin(); it != followed_.end(); ++it) {
    if (!it->acked || it->event.Get() != event.os_event.Get()) continue;
    const Key key = it->key;
    followed_.erase(it);
    return key;
  }
  return std::nullopt;
}

void PageCommandKey::Clear() {
  input_observation_.Reset();
  widget_observation_.Reset();
  followed_.clear();
}

bool PageCommandKey::Followed::Matches(const blink::WebInputEvent& event) const {
  if (acked || event.GetType() != blink::WebInputEvent::Type::kRawKeyDown) return false;
  const auto& key = static_cast<const blink::WebKeyboardEvent&>(event);
  return key.windows_key_code == windows_key_code &&
      key.GetModifiers() == modifiers && key.TimeStamp() == web_timestamp;
}

void PageCommandKey::OnInputEventAck(const content::RenderWidgetHost& host,
                                     blink::mojom::InputEventResultSource source,
                                     blink::mojom::InputEventResultState state,
                                     const blink::WebInputEvent& event) {
  for (auto it = followed_.begin(); it != followed_.end(); ++it) {
    if (!it->Matches(event)) continue;
    if (state != blink::mojom::InputEventResultState::kConsumed) {
      // HandleKeyboardEvent follows with this event, unless the widget is hidden.
      it->acked = true;
      return;
    }
    const Key key = it->key;
    followed_.erase(it);
    // The report is posted; no member access after this.
    consumed_.Run(key);
    return;
  }
}

void PageCommandKey::RenderWidgetHostDestroyed(content::RenderWidgetHost* widget) {
  Clear();
}

}  // namespace arx
