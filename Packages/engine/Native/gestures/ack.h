#ifndef COMPONENTS_INPUT_ARX_HISTORY_GESTURE_H_
#define COMPONENTS_INPUT_ARX_HISTORY_GESTURE_H_

#include <optional>

#include "base/functional/callback.h"
#include "base/unguessable_token.h"

namespace input {

// Browser-local metadata; never serialized to the renderer. Queue copies retain
// the issuing owner, and different gestures must not coalesce. The oldest
// event's callback survives coalescing, just like its latency admission.
struct HistoryGestureAck {
  base::UnguessableToken identity;
  base::RepeatingCallback<void(bool renderer_reply, bool consumed,
                               std::optional<bool> propagates_x)> callback;
};

}  // namespace input
#endif  // COMPONENTS_INPUT_ARX_HISTORY_GESTURE_H_
