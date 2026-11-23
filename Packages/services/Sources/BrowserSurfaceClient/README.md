# BrowserSurfaceClient

MainActor native view attachment by tab identity; no Chromium dependency.

Requires macOS 27 and Swift 6.4. Features use core, services, AppUI and lower-level features; services never import features. Verify with `make test-all`.

BrowserSurface reports native mouse and keyboard focus without consuming events or replacing the renderer’s first responder. Its event monitor is removed when the host is dismantled.

Focus requests wait until the native page and its host belong to the same window. AppKit announces a new subview before assigning its window, so the attachment notification defers until that transition completes and rechecks the current pane's focus intent. AppKit regression tests cover a retained page moving between windows, delayed page mounting, and deactivation before a queued attachment notification.

`BrowserSurfaceStage`, driven by a `BrowserSurfaceStageController` outside SwiftUI, keeps a page that is about to be shown (a pressed sidebar tab, the space a swipe uncovers) drawing in the window, transparent over the page card, so showing it needs no new frame; presented, it shows that page until a host takes it. A staged page is in a window, so Chromium treats it as shown: stage only a page that's about to be shown, never one merely hovered (DEV-941). The controller's `window` lets its owner match events to the stage's window. A page staged out of sight takes no drags: AppKit gives a drag to the front-most view registered for its type whatever its opacity, so the stage takes its page's drag types away until it shows the page or lets it go, and a file dropped on the page card reaches the page under it (DEV-1309).

A host retries attachment when it enters a window. This handles SwiftUI replacement while native page creation is pending; child-view notifications only retry focus, avoiding recursive mounts. Suppressed Peek sources cannot remount, noninteractive visible pages remain mounted, and dismantling clears the coordinator's target before any later callback.

BrowserSurfaceVisibility reports a stable host token, bound tab and optional
native visibility through the host environment. It observes window occlusion,
minimization, hidden ancestors and geometry independently of focus. Nil means
that the native child is detached or still attaching. Deferred reports are
superseded on rebinding; dismantling publishes a source-bound removal and removes
notification observers. AppFeature resolves competing hosts and rehost transitions
before using these observations for automatic PiP.

Unhandled Escape arrives through the engine's renderer ACK, never through the
focus monitor. A callback belongs to the actual native host and tab. Rebinding,
suppression and dismantling revoke its deferred work; old-host teardown cannot
unbind a replacement. The accepting view must recheck the supplied predicate
before changing state. Ordinary browser surfaces have no accepting callback.

`BrowserPageOverlay` is native content a host draws above one page's surface, by tab, through `browserPageOverlay` (the capture overlay, which takes the keyboard) or `browserPageNotice` (a passing notice such as the link toast in split view, which doesn't).

`browserTabPlaceholder` is what a host draws in place of a suppressed page that another window holds, such as a page floating in Page PiP (DEV-950); `ViewerItemView` shows it. A tab suppressed for Peek or page full screen gets none.
