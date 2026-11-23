#ifndef ARX_GESTURES_FIXTURE_H_
#define ARX_GESTURES_FIXTURE_H_

#include "base/functional/callback.h"
#include "url/gurl.h"

namespace content { class WebContents; }
namespace arx::gestures {

// Caller must prove native-owned fresh storage and mock Keychain. The driver
// injects browser points and real renderer gestures; it cannot prove NSTouch
// delivery, physical thresholds, Magic Mouse or desktop-switch behavior.
void RunFixture(content::WebContents* contents, const GURL& loopback_origin,
                base::OnceCallback<void(bool)> completed);

}  // namespace arx::gestures
#endif  // ARX_GESTURES_FIXTURE_H_
