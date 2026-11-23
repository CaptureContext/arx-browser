# DefaultBrowserClient

Reads whether Arx opens `http` and `https` links from other apps, and asks macOS to make Arx the default browser. Onboarding's "Links from other apps" page and the Default Browser row in Settings both use it as `@Dependency(\.defaultBrowser)`. Onboarding's "Make it yours" page reads `currentBrowserIdentifier` to preselect the browser people use now.

## Behaviour

- **`status()`:** `isDefault` when Arx handles both schemes, `otherBrowser(name)` with the current browser's name otherwise, and `unavailable` in runs that may not touch the setting.
- **`makeDefault()`:** returns `alreadyDefault` without asking when Arx already handles both schemes. Otherwise it calls `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` for `http`, and for `https` only if that still isn't Arx's afterwards. macOS shows its own confirmation. The result is read back from Launch Services: `accepted` when Arx now handles both schemes, `declined` when it doesn't, whether the prompt threw or returned. A declined `http` prompt doesn't go on to ask about `https`.
- Comparison uses the bundle identifier, so another copy of Arx counts as Arx.

## Skipping it

`live` returns `unavailable`, which never touches Launch Services, for test runs (XCTest environment keys), headless runs (`--headless`), smoke fixtures (`ARX_ENGINE_PROFILE` or `--arx-…` options), and when `ARX_SKIP_DEFAULT_BROWSER` is set. `testValue` is unimplemented, so a test that reaches the client without supplying one fails. `previewValue` reports Safari as the default and changes nothing.

## Structure

`status()` and `makeDefault()` hold every decision on top of four closures (`isAvailable`, `isDefault`, `currentBrowserName`, `requestDefault`), plus `currentBrowserIdentifier`, the bundle identifier of the app that opens `http` links (nil unless supplied), so `DefaultBrowserTests` covers each result with doubles. The live closures use `NSWorkspace.urlForApplication(toOpen:)` and `setDefaultApplication(at:toOpenURLsWithScheme:)`.

`BrowserLinkClient` (DEV-1193) is for other browsers' own links.
- It finds Chrome (release, Beta, Dev or Canary) or Arc by bundle identifier, when a link opens.
- It opens a link in that browser with `NSWorkspace.open(_:withApplicationAt:)`. Chrome's `application:openURLs:` opens a `chrome://` link as a trusted tab.
- It never asks macOS to send Arx another browser's scheme.
- Automated runs get `unavailable`, as with `DefaultBrowserClient`.
