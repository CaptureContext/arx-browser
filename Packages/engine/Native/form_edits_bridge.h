#ifndef ARX_FORM_EDITS_BRIDGE_H_
#define ARX_FORM_EDITS_BRIDGE_H_

#include <stddef.h>
#include <stdint.h>

namespace content {
class WebContents;
}

namespace arx {

// DEV-1084. Whether a page holds form input a person typed and hasn't sent, in
// any of its frames: cross-origin ones too, which a script in the page's main
// frame can't read. The check runs in an isolated world in each frame of the
// page's current document and answers only true or false, so no value leaves
// the renderer. It reads fields as they are, so a password field that now
// shows its text counts like any filled field.
//
// What counts, as the app's own script does (AgentTabTidying): a field whose
// value differs from the page's (a cleared default too), a filled field other
// than a search box (pages that keep their fields' default in step with what's
// typed, as React does, hide an edit), a changed choice, and an editable area
// with text. Open shadow roots are read; closed ones and editors that keep
// their text outside the page's fields aren't.

enum FormEditsResult : int32_t {
  // Nothing typed, or nothing to lose: an unloaded, crashed or closing page,
  // or one that isn't on the web.
  kFormEditsNone = 0,
  // A frame holds typed input.
  kFormEditsTyped = 1,
  // A frame didn't answer within two seconds, the page has more frames than
  // are read, the page or a frame it read navigated or went away meanwhile,
  // or a frame it didn't read was added.
  kFormEditsUnknown = -1,
};

using FormEditsReply = void (*)(void* context, uint64_t request, uint64_t page,
                                int32_t result);

// Main thread. Replies once, always later (never inside this call), within
// about two seconds.
void CheckFormEdits(content::WebContents* contents, uint64_t page,
                    uint64_t request, FormEditsReply reply, void* context);

}  // namespace arx

// Main thread, outside the ABI table: the app looks it up with dlsym and keeps
// its own script on an engine built before it.
extern "C" {

// Checks `page`'s frames for typed input and calls `reply` once with a
// FormEditsResult, on the main thread after this returns. `context` is passed
// back as given. False, with no reply, for an unknown page or a null reply.
__attribute__((visibility("default"))) bool ArxEngineCheckPageFormEdits(
    uint64_t page, uint64_t request,
    void (*reply)(void* context, uint64_t request, uint64_t page, int32_t result),
    void* context);

}

#endif  // ARX_FORM_EDITS_BRIDGE_H_
