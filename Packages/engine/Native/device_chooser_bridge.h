#ifndef ARX_DEVICE_CHOOSER_BRIDGE_H_
#define ARX_DEVICE_CHOOSER_BRIDGE_H_

#include <cstddef>
#include <cstdint>

// DEV-905 device choosers, exported outside the ABI table so engines built
// before them still load. Main thread, while the engine runs.
//
// A page's navigator.usb.requestDevice, navigator.hid.requestDevice,
// navigator.serial.requestPort or navigator.bluetooth.requestDevice reaches
// the app as one chooser per page, named by a token. The app reads it, draws
// its own sheet and answers it. Without a handler, every chooser is cancelled
// at once, so a page never waits for a person who isn't there (headless runs).

// The page's chooser opened, changed (devices came, went or changed, the
// adapter or a rescan changed) or closed (`open` false). Posted.
typedef void (*ArxDeviceChooserHandler)(void* context, uint64_t page, uint64_t token, bool open);

extern "C" {
__attribute__((visibility("default")))
void ArxEngineSetDeviceChooserHandler(ArxDeviceChooserHandler handler, void* context);

// The page's open chooser as NUL-terminated JSON: {"token", "title",
// "revision" (the list's changes, as a string), "multiple", "rescan"
// (Bluetooth can scan again), "scanning", "adapterOff",
// "options": [{"name", "connected", "paired", "signal" (-1 unknown, 0-4)}]}.
// Writes it when `capacity` is larger and returns its length either way; 0
// when the page has no chooser.
__attribute__((visibility("default")))
size_t ArxEngineCopyDeviceChooser(uint64_t page, char* buffer, size_t capacity);

// Chooses the options at `indices` (one unless "multiple") of the list at
// `revision`, or cancels with `count` 0 (any revision). The chooser closes
// either way. False for a stale token, revision or index: the list changed, so
// an index may name another device.
__attribute__((visibility("default")))
bool ArxEngineAnswerDeviceChooser(uint64_t page, uint64_t token, uint64_t revision,
                                  const uint32_t* indices, size_t count);

// Bluetooth's Scan Again. False for a stale token or a chooser without it.
__attribute__((visibility("default")))
bool ArxEngineRescanDeviceChooser(uint64_t page, uint64_t token);

// The devices sites in a loaded ordinary profile ("" for the legacy one) may
// use, as a NUL-terminated JSON array of {"kind" ("usb", "hid", "serial" or
// "bluetooth"), "origin", "key", "name"}. Same buffer contract as above.
__attribute__((visibility("default")))
size_t ArxEngineCopyDeviceGrants(const char* profile_key, char* buffer, size_t capacity);

// Revokes one grant, as listed. False when it isn't there.
__attribute__((visibility("default")))
bool ArxEngineRevokeDeviceGrant(const char* profile_key, const char* kind, const char* origin,
                                const char* key);
}

#endif  // ARX_DEVICE_CHOOSER_BRIDGE_H_
