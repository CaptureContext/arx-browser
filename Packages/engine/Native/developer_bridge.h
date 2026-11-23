#ifndef ARX_DEVELOPER_BRIDGE_H
#define ARX_DEVELOPER_BRIDGE_H

#include <string>
#include <string_view>
#include <vector>

#include "base/functional/callback.h"

#include "chrome/browser/arx/ChromiumBridge.h"

class GURL;
namespace content { class WebContents; }

namespace arx {
using DeveloperReply = void (*)(uint64_t request, uint64_t page, ArxDeveloperStatus status,
                                const uint8_t* json, size_t size);

// ABI34 (DEV-668). Runs an agent's script in the main frame's developer world
// of an ordinary HTTP(S) page. Replies once, never synchronously; private
// pages are refused and a navigation replies STALE.
void EvaluateDeveloperScript(content::WebContents* contents, uint64_t page, uint64_t request,
                             const char* source,
                             uint32_t maximum_bytes, uint32_t timeout_ms, DeveloperReply reply);
// ABI57 (DEV-996). The app's page translation scripts, in the main frame's
// translation world of an HTTP(S) page, private pages included. The same
// limits and replies as EvaluateDeveloperScript; one translation script and one
// agent script may run on a page at once.
void EvaluateTranslationScript(content::WebContents* contents, uint64_t page, uint64_t request,
                               const char* source, uint32_t maximum_bytes, uint32_t timeout_ms,
                               DeveloperReply reply);
// Starts or stops the page's console and network logs; stopping drops them.
bool SetDeveloperLog(content::WebContents* contents, uint64_t page, bool enabled);
// Replies once, never synchronously.
void ReadDeveloperLog(content::WebContents* contents, uint64_t page, uint64_t request,
                      ArxDeveloperLogKind kind, uint64_t after, uint32_t limit,
                      DeveloperReply reply);
// ABI58 (DEV-1009). Asks the page's main frame for nothing in Chrome's internal world,
// apart from the developer scripts' queue (a script a frozen page holds keeps that busy):
// OK when it answers, TIMEOUT after timeout_ms (at most 30000), or UNAVAILABLE when
// `held` says at the deadline that the page couldn't answer for another reason. Replies
// once, never synchronously; private pages too.
void PingPage(content::WebContents* contents, uint64_t page, uint64_t request,
              uint32_t timeout_ms, base::RepeatingCallback<bool()> held, DeveloperReply reply);
void CancelDeveloperRequest(uint64_t request);
void ForgetDeveloperPage(uint64_t page);
void StopDevelopers();

// Exposed for the native policy tests.
// Strips user info and fragments, and replaces the values of query keys that
// usually carry credentials (token, key, secret, password, session, code...).
std::string SanitizedDeveloperURL(const GURL& url);
// Replaces every cookie value of at least 8 bytes, raw or JSON-escaped, in text.
void RedactDeveloperText(std::string& text, const std::vector<std::string>& cookie_values);
}  // namespace arx

#endif
