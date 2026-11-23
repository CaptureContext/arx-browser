#ifndef ARX_PROTECTED_MEDIA_BRIDGE_H_
#define ARX_PROTECTED_MEDIA_BRIDGE_H_

#include <cstddef>
#include <cstdint>

// DEV-877 WebKit pages, exported outside the ABI table so engines built before
// them still load (ChromiumOptionalExports.swift looks them up).
//
// Every entry point is main thread only.

// Reports a page whose frame asked for protected media (EME) key systems:
// `page` is the Arx page, `url` its main frame's committed URL (NUL-terminated
// UTF-8). Posted, never called inside Chromium's own call.
typedef void (*ArxProtectedMediaHandler)(void* context, uint64_t page, const char* url);

// DEV-1211: why a page is reported. A handler set with
// ArxEngineSetProtectedMediaReasonHandler hears it; ArxEngineSetProtectedMediaHandler's
// handler hears every report without it, as before.
enum {
  // The page can't play its protected media.
  ARX_PROTECTED_MEDIA_PLAYBACK_FAILED = 0,
  // Keys couldn't be created (or access was refused) before any media element
  // wanted keys: a bot check may do this, and so may a player that stops early.
  ARX_PROTECTED_MEDIA_KEYS_WITHOUT_MEDIA = 1,
};
typedef void (*ArxProtectedMediaReasonHandler)(void* context, uint64_t page, const char* url,
                                               int32_t reason);

// The cookies a URL's site would receive, as a NUL-terminated JSON array of
// {"name", "value", "domain", "path", "expires" (seconds since 1970, or null
// for a session cookie), "secure", "httpOnly", "sameSite" ("none", "lax",
// "strict" or "unspecified")}. Partitioned cookies are left out. `json` is
// borrowed for the call; a lost cookie manager answers "[]".
typedef void (*ArxSiteCookiesCallback)(void* context, const char* json, size_t length);

extern "C" {
// Sets or clears (NULL) the handler. One handler; a later call replaces it.
__attribute__((visibility("default")))
void ArxEngineSetProtectedMediaHandler(ArxProtectedMediaHandler handler, void* context);

// DEV-1211: sets or clears (NULL) a handler that hears each report's reason. It
// replaces a handler either setter set. Outside the ABI table; the app looks
// it up and falls back to ArxEngineSetProtectedMediaHandler on older engines.
__attribute__((visibility("default")))
void ArxEngineSetProtectedMediaReasonHandler(ArxProtectedMediaReasonHandler handler,
                                             void* context);

// Reads the cookies of `url` (http or https) from the store of `page`'s
// profile when `page` is an Arx page, otherwise from the loaded ordinary
// profile `profile_key` ("" or NULL for the legacy profile). False, and no
// callback, when neither is available or the URL isn't http(s). Otherwise
// `done` runs exactly once, later, on the main thread.
__attribute__((visibility("default")))
bool ArxEngineCopySiteCookies(const char* profile_key, uint64_t page, const char* url,
                              ArxSiteCookiesCallback done, void* context);
}

#endif  // ARX_PROTECTED_MEDIA_BRIDGE_H_
