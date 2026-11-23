#ifndef ARX_PAGE_COMMAND_KEY_H
#define ARX_PAGE_COMMAND_KEY_H

#include <cstdint>
#include <deque>
#include <optional>

#include "base/functional/callback.h"
#include "base/scoped_observation.h"
#include "base/time/time.h"
#include "components/input/native_web_keyboard_event.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_observer.h"

namespace arx {

// ABI62 (DEV-1264, DEV-1073, DEV-1332). Follows one shortcut key a page received, from the
// page's PreHandleKeyboardEvent to the renderer's ACK, so the app learns
// whether the page used it. The app lets the keys whose Conflict resolution
// isn't Arx, and ⌘Z and ⇧⌘Z, reach a focused page first, and runs its own
// command for a key the page left.
//
// A consumed ACK (the page called preventDefault) is reported through
// `consumed`. An unconsumed one is left for the page's HandleKeyboardEvent,
// which Chromium calls next with the same event and which asks the app
// synchronously, so the app can run its command inside that call.
//
// Up to kLimit keys wait for their ACKs, in order, so quick presses on a busy
// page each get their answer. A key for another widget, or the widget's end,
// forgets the ones waiting; past the limit the oldest is forgotten.
class PageCommandKey final : public content::RenderWidgetHost::InputEventObserver,
                             public content::RenderWidgetHostObserver {
 public:
  struct Key {
    uint16_t key_code = 0;
    uint64_t modifier_flags = 0;
    double timestamp = 0;
    // The page's document generation when the key was pressed: a report for a
    // document the page has since left is dropped by the app.
    uint64_t generation = 0;
  };
  using ConsumedCallback = base::RepeatingCallback<void(const Key&)>;

  explicit PageCommandKey(ConsumedCallback consumed);
  ~PageCommandKey() override;
  PageCommandKey(const PageCommandKey&) = delete;
  PageCommandKey& operator=(const PageCommandKey&) = delete;

  // A key down Arx can bind (⌘ or ⌃ held, or an F-key; DEV-1332) that Chromium
  // offers back when the page leaves it (not one it drops when unhandled).
  // Repeats are followed too; the app ignores reports for keys it didn't let
  // through, and nothing about a key is kept past its answer.
  static bool IsCommandKey(const input::NativeWebKeyboardEvent& event);
  static Key KeyFor(const input::NativeWebKeyboardEvent& event);

  // From PreHandleKeyboardEvent, for the widget the key goes to, with the
  // page's document generation now.
  void Follow(content::RenderWidgetHost* widget, const input::NativeWebKeyboardEvent& event,
              uint64_t generation);
  // From HandleKeyboardEvent: the followed key the page left, once.
  std::optional<Key> TakeUnconsumed(const input::NativeWebKeyboardEvent& event);
  void Clear();

 private:
  // content::RenderWidgetHost::InputEventObserver
  void OnInputEventAck(const content::RenderWidgetHost& host,
                       blink::mojom::InputEventResultSource source,
                       blink::mojom::InputEventResultState state,
                       const blink::WebInputEvent& event) override;
  // content::RenderWidgetHostObserver
  void RenderWidgetHostDestroyed(content::RenderWidgetHost* widget) override;

  static constexpr size_t kLimit = 4;

  struct Followed {
    // Retains the NSEvent, so its pointer can't be reused while followed.
    gfx::NativeEvent event;
    Key key;
    int windows_key_code = 0;
    int modifiers = 0;
    base::TimeTicks web_timestamp;
    // Unconsumed: waiting for HandleKeyboardEvent.
    bool acked = false;

    bool Matches(const blink::WebInputEvent& event) const;
  };

  ConsumedCallback consumed_;
  std::deque<Followed> followed_;
  base::ScopedObservation<content::RenderWidgetHost,
                          content::RenderWidgetHost::InputEventObserver>
      input_observation_{this};
  base::ScopedObservation<content::RenderWidgetHost,
                          content::RenderWidgetHostObserver>
      widget_observation_{this};
};

}  // namespace arx
// DEV-1332. True: this engine follows every key combination Arx can bind.
// Exported outside the ABI table (overlay.EXTRA_EXPORTS).
extern "C" __attribute__((visibility("default"))) bool ArxEngineFollowsAllShortcutKeys(void);

#endif  // ARX_PAGE_COMMAND_KEY_H
