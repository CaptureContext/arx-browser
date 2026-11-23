#ifndef ARX_NETWORK_CAPTURE_BRIDGE_H
#define ARX_NETWORK_CAPTURE_BRIDGE_H

#include <cstdint>
#include <string>
#include <string_view>

namespace content { class WebContents; }

namespace arx {
// DEV-924: request and response headers and bodies of an ordinary page, kept
// here while an agent with the network details grant asked for them, read on
// request. Exported outside the ABI table as ArxEngineSetNetworkCapture and
// ArxEngineReadNetworkCapture. Private pages are refused.
bool SetNetworkCapture(content::WebContents* contents, uint64_t page, bool enabled);
// JSON: {"capturing", "entries": [...], "next", "dropped"}; see
// network_capture_bridge.mm for an entry's fields. Empty when not capturing.
std::string ReadNetworkCapture(uint64_t page, uint64_t after, uint32_t limit,
                               uint32_t body_bytes);
void ForgetNetworkCapture(uint64_t page);
void StopNetworkCaptures();

// Exposed for the native policy tests. Cookie, Set-Cookie, Authorization and
// every header whose name suggests a credential (token, secret, session, key,
// auth, password, csrf) never leave the engine.
bool SensitiveHeader(std::string_view name);
}  // namespace arx

#endif
