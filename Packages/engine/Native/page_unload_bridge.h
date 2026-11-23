#ifndef ARX_PAGE_UNLOAD_BRIDGE_H
#define ARX_PAGE_UNLOAD_BRIDGE_H

#include <cstdint>

namespace content { class WebContents; }

namespace arx {
// DEV-873. Unloading a hidden page to free its memory, in place: Chromium's
// WebContents::Discard() (kWebContentsDiscard, which startup enables) drops the
// renderer's document and keeps the WebContents, its NavigationController
// (address, title, back/forward list) and its NSView. The page reloads its
// current entry when its view is shown again, or when RestoreUnloadedPage
// asks. Chrome's own discarding needs a TabLifecycleUnit from its tab strip,
// which Arx pages don't have, so Arx decides when and calls this.
//
// The app mirrors these values (ChromiumPageUnload.swift); keep them in step.
enum PageUnloadReason : uint32_t {
  // Hidden longer than Settings allow: Chrome's PROACTIVE rules.
  kPageUnloadInactive = 0,
  // The system is under critical memory pressure: Chrome's URGENT rules.
  kPageUnloadMemoryPressure = 1,
  // DEV-1104: the window that held the page closed. Like Chrome's EXTERNAL
  // discards, sound, recent sound, picture in picture (which UnloadPage ends
  // first), notifications, camera, microphone and screen capture, an
  // extension's autoDiscardable: false and live connections don't keep it:
  // closing a window stops what it played. Unsaved input, a PDF or a page that
  // isn't http(s), USB or Bluetooth, DevTools and Arx's own capture still do.
  kPageUnloadWindowClosed = 2,
  // DEV-1107: as kPageUnloadWindowClosed, for a page whose unsaved input the
  // person already let go: the window asked its before-unload question before
  // closing and they chose Leave, or the page had nothing to ask. Unsaved input
  // (kFormInteractions, kUserEdits) doesn't keep it.
  kPageUnloadWindowClosedAnswered = 3,
};

enum PageUnloadStatus : int32_t {
  kPageUnloaded = 0,
  // No such page, the engine isn't running, or this engine can't discard.
  kPageUnloadUnavailable = 1,
  kPageAlreadyUnloaded = 2,
  // A blocker below applies; the page stays loaded.
  kPageUnloadRefused = 3,
  // The page is loading or committing a navigation; ask again later.
  kPageUnloadBusy = 4,
};

// Why a page can't be unloaded now. A mask; 0 means it can.
enum PageUnloadBlocker : uint32_t {
  // Chrome's DiscardEligibilityPolicy says no: audible or recently audible,
  // picture in picture, form input or user edits, a PDF, notifications
  // (inactive only), title or icon changes in the background (inactive only),
  // camera, microphone, screen or tab capture, USB or Bluetooth, an
  // extension's autoDiscardable: false, DevTools, not http(s), or no document.
  kPageUnloadBlockedByChrome = 1u << 0,
  // Shown in a window, even behind other windows. Only detached views unload.
  kPageUnloadBlockedVisible = 1u << 1,
  // Arx's DevTools or any other debugger (an extension's chrome.debugger) is
  // attached: unloading would detach it.
  kPageUnloadBlockedDevTools = 1u << 2,
  // Plays sound now, in case Performance Manager hasn't seen it yet. Not for a
  // closed window.
  kPageUnloadBlockedAudible = 1u << 3,
  // Not for a closed window, which ends picture in picture instead.
  kPageUnloadBlockedPictureInPicture = 1u << 4,
  // A capturer holds the page (tab capture, Arx's own offscreen capture).
  kPageUnloadBlockedCaptured = 1u << 5,
  // Loading, or committing a navigation that Discard() would ignore.
  kPageUnloadBlockedLoading = 1u << 6,
  // Already unloaded, crashed, or not yet loaded: nothing to free.
  kPageUnloadBlockedNoDocument = 1u << 7,
  // Performance Manager has no page node for it.
  kPageUnloadBlockedUnknownPage = 1u << 8,
  // Holds a WebSocket or WebTransport connection (DEV-879), which unloading
  // would end; content::ArxPageHoldsLiveConnection, the same check that keeps
  // the page out of infinite tabs freezing. Not for a closed window.
  kPageUnloadBlockedLiveConnection = 1u << 9,
  // Form input or other user edits the page hasn't saved (DEV-1104): Chrome's
  // kFormInteractions and kUserEdits. Inactive and memory pressure unloads
  // report them as kPageUnloadBlockedByChrome.
  kPageUnloadBlockedUnsavedInput = 1u << 10,
};

// The one place that decides whether the engine may unload a page: Chrome's
// rules, then Arx's own. The app checks its own facts first (shown, selected,
// in an agent's use; see TabUnloadEligibility). New exemptions that the engine
// knows about, like open WebSocket or WebTransport connections (DEV-879),
// belong here. UI thread.
uint32_t PageUnloadBlockers(content::WebContents* contents, PageUnloadReason reason);

// Unloads the page when no blocker applies. blockers, when given, receives
// PageUnloadBlockers' mask. For a closed window it ends the page's picture in
// picture first, even when a blocker keeps the page loaded. UI thread.
PageUnloadStatus UnloadPage(content::WebContents* contents, PageUnloadReason reason,
                            uint32_t* blockers);

// Whether the page is unloaded and hasn't started loading again.
bool PageIsUnloaded(content::WebContents* contents);

// PageIsUnloaded, or UnloadPage is ending its renderer right now: a renderer
// exit reported then is the unload's, not a crash. UI thread.
bool PageIsBeingUnloaded(content::WebContents* contents);

// Starts loading an unloaded page's current entry, as showing it would, even
// while it stays hidden (an agent's load). False when it wasn't unloaded.
bool RestoreUnloadedPage(content::WebContents* contents);

// DEV-1128: ends the page's video or document picture in picture, as closing the
// window that owns its tab does, without unloading the page, which an agent may
// still be using. True when there was one. Main thread.
bool EndPagePictureInPicture(content::WebContents* contents);
}  // namespace arx

// Main thread, outside the ABI table: the app looks them up with dlsym and, on
// an engine built before them, closes windows without asking (DEV-1107).
extern "C" {

// PageUnloadBlockers for `page` and `reason`, without unloading it: what
// closing the window that holds it would find, so the window can ask the pages
// holding unsaved input (kPageUnloadBlockedUnsavedInput) before it goes.
// kPageUnloadBlockedUnknownPage for an unknown page or reason.
__attribute__((visibility("default"))) uint32_t ArxEnginePageUnloadBlockers(
    uint64_t page, uint32_t reason);

// ArxEngineUnloadPage for kPageUnloadWindowClosedAnswered, which that export
// doesn't take: a PageUnloadStatus, with the blockers mask in `blockers` (may
// be NULL).
__attribute__((visibility("default"))) int32_t ArxEngineUnloadAnsweredPage(
    uint64_t page, uint32_t* blockers);

}

#endif
