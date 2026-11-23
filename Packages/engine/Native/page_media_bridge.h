#ifndef ARX_PAGE_MEDIA_BRIDGE_H_
#define ARX_PAGE_MEDIA_BRIDGE_H_

#include <cstddef>
#include <cstdint>

namespace content { class WebContents; }

// DEV-1144 page media bridge, exported outside the ABI table so engines built
// before it still load (ChromiumOptionalExports.swift looks them up). The app
// gives the engine a script and the origins it runs on; the script runs in the
// main world of those origins' top-level documents at document start and
// exchanges JSON text with the app. FairPlay in Chromium tabs uses it.
//
// Every entry point is main thread only.

// A message a bridged document sent: `page` is the Arx page, `document` the
// engine's number for that document (never reused while the engine runs),
// `message` UTF-8 text of `length` bytes, borrowed for the call. Posted, never
// called inside Chromium's own call.
typedef void (*ArxPageMediaHandler)(void* context, uint64_t page, uint64_t document,
                                    const char* message, size_t length);

extern "C" {
// Sets the bridged origins (serialized, such as "https://open.spotify.com";
// exact matches), the script, and the handler. Takes effect from each page's
// next cross-document navigation. NULL `script`, no origins or a NULL handler
// turn the bridge off for the next documents; documents already running the
// script stay bridged until they go, but their messages reach no handler.
__attribute__((visibility("default")))
void ArxEngineSetPageMediaBridge(const char* const* origins, size_t origin_count,
                                 const char* script, ArxPageMediaHandler handler,
                                 void* context);

// Sends `message` (UTF-8, `length` bytes) to `document` of `page`. False when
// that document is no longer the page's current primary main document or
// doesn't run the script, or the message is too large; the page then never
// sees it.
__attribute__((visibility("default")))
bool ArxEngineSendPageMedia(uint64_t page, uint64_t document, const char* message,
                            size_t length);

// DEV-1151. While `keeps` is true, `page` is kept out of Chromium's freezing
// (voting, Battery Saver and infinite tabs), as it is while it plays sound:
// Arx's FairPlay helper holds `document`'s track and its script must keep
// answering. The lease ends when the app passes false for that document, when
// `document` stops being the page's primary main document, or when the page
// closes. False when `document` isn't the page's current bridged document
// (with `keeps`) or the page is unknown.
__attribute__((visibility("default")))
bool ArxEngineSetPageMediaKeepsRunning(uint64_t page, uint64_t document, bool keeps);
}

namespace arx {
// Prepares each of `contents`' cross-document main-frame commits with the
// bridge's script when its origin is bridged. engine_bridge.mm calls it once
// per page; the observer lives as the contents' user data.
void AttachPageMedia(content::WebContents* contents);
}  // namespace arx

#endif  // ARX_PAGE_MEDIA_BRIDGE_H_
