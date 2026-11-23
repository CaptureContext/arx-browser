#ifndef ARX_DEVTOOLS_HOOKS_H
#define ARX_DEVTOOLS_HOOKS_H

// DEV-785: Arx pages are browser tabs without Chrome's TabInterface, so
// ChromeDevToolsManagerDelegate reported them as "other" targets. The DevTools
// frontend never takes an "other" target as its page, so every panel stayed
// empty. Dependency-free so chrome_devtools_manager_delegate.cc can include it;
// the key is defined next to its use by the engine overlay.
namespace arx {
// The user-data key marking a WebContents as an Arx page (a "page" target).
const void* DevToolsPageKey();
}  // namespace arx

#endif
