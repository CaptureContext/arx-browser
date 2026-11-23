"""Keep a page's media session after a back/forward cache restore (DEV-960).

A page restored from the back/forward cache is the same document, and its
`navigator.mediaSession` still holds the metadata and action handlers it set. The
renderer never sends them again. Chromium's `MediaSessionImpl::DidFinishNavigation`
still resets the browser's copy in the frame's `MediaSessionServiceImpl`, as it does
for a new document, so the title, artist, artwork and the previous track, next track
and seek buttons disappear until the page sets them again.

On a restore the service now keeps its metadata and actions. It still clears its
playback state, as before: Chromium restores the page's players paused, and the
page's last report may say playing. A page that changes or clears its metadata or
handlers after the restore sends them as usual, and they replace the kept ones. Any
other navigation resets the service as before. If an anchor changes, the build stops.
"""
from .overlay import replace_once

SERVICE_HEADER = "content/browser/media/session/media_session_service_impl.h"
SERVICE = "content/browser/media/session/media_session_service_impl.cc"
SESSION = "content/browser/media/session/media_session_impl.cc"

DECLARATION = "  void DidFinishNavigation();\n"

ARX_DECLARATION = DECLARATION + """  // Arx (DEV-960): the frame's document came back from the back/forward cache.
  // It keeps the metadata and actions it set; only the playback state resets.
  void DidRestoreFromBackForwardCache();
"""

DEFINITION = """  SetMetadata(nullptr);
  ClearActions();
}
"""

ARX_DEFINITION = DEFINITION + """
void MediaSessionServiceImpl::DidRestoreFromBackForwardCache() {
  // Arx (DEV-960): the restored document's navigator.mediaSession still holds
  // its metadata and action handlers and won't send them again, so they stay.
  // Its players come back paused, so the playback state it last reported
  // doesn't, as for any other navigation.
  SetPlaybackState(blink::mojom::MediaSessionPlaybackState::NONE);
}
"""

NAVIGATION = """  if (auto it = services_.find(rfh_id); it != services_.end()) {
    it->second->DidFinishNavigation();
  }
"""

ARX_NAVIGATION = """  if (auto it = services_.find(rfh_id); it != services_.end()) {
    // Arx (DEV-960): a document restored from the back/forward cache keeps the
    // metadata and actions it set before it was cached.
    if (navigation_handle->IsServedFromBackForwardCache()) {
      it->second->DidRestoreFromBackForwardCache();
    } else {
      it->second->DidFinishNavigation();
    }
  }
"""


def patches():
    yield SERVICE_HEADER, DECLARATION, ARX_DECLARATION
    yield SERVICE, DEFINITION, ARX_DEFINITION
    yield SESSION, NAVIGATION, ARX_NAVIGATION


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)
