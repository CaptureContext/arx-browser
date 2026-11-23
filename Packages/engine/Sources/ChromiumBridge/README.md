# ChromiumBridge

ABI11 appends semantic page inspection, asynchronous reference validation,
cancellation, scope revocation and a synchronous native document-liveness query.
The latter never claims current DOM validity. Borrowed UTF-8 JSON is bounded to
256 KiB, with stricter node/text/reference budgets enforced before renderer IPC.
Scopes are trusted per-client/grant UUIDs; snapshots/references are opaque native
nonces. There is no page action or arbitrary JavaScript operation in this ABI.

The versioned C declarations shared by Swift and the GN-built native implementation. No Chromium headers or Objective-C classes cross this ABI. All calls and callbacks use the main thread. Strings and NSView pointers are borrowed. The Swift module copies callback values and owns its Swift wrappers.

ABI 4 adds `ArxDownloadSnapshot`, download change/initialized callbacks, observation and cancel commands. Snapshot pointers and every referenced string are borrowed only for the callback. State and interruption codes follow the pinned Chromium DownloadItem enums; unknown state codes must be treated as interrupted.

ABI5 appends bounded viewport capture/cancel functions and the capture completion callback. A successful snapshot includes PNG bytes, physical pixel dimensions, viewport points, device scale, loading state, and a document UUID. Payload memory is borrowed only until the callback returns. Logical cancellation/timeout does not imply that compositor copy or encoding has physically stopped; new work can return busy until it drains.

ABI5 appends `run_with_options` with `ArxEngineRunOptions.use_mock_keychain_for_testing`. The original `run` supplies false. This explicit option is reserved for disposable smoke profiles, and native startup emits a distinct mock-mode marker. No inherited environment variable or arbitrary host argument is forwarded to Chromium.

ABI6 appends ordinary-page media snapshots, bounded command completions and source-activation callbacks, plus observe/perform/cancel functions. Commands carry page, media generation and revision; metadata strings are borrowed only during the callback. A separate private-media probe returns only unavailable/visible/hidden policy status, never private metadata. PiP/video pixels and NSWindow ownership remain entirely native.

ABI7 appends profile-keyed extension inventory/management, cancellation and exact developer-fixture loading. Completion carries at most 1 MiB of borrowed UTF-8 JSON plus a runtime/profile-bound revision. The snapshot preserves native disable reasons and permissions; commands recheck the revision and native policy. The run options default extension support off. The fixture option requires mock Keychain and creates fresh native-owned storage, ignoring the supplied profile path. No public install path or permissions-grant operation is exposed.

ABI8 appends the read-only `media_source_is_current` function after all ABI7 extension entries. The caller stays on the UI thread; the query returns false for a missing/private source or invalidated generation and performs no activation, observation refresh or callback. The header, lock, native table and Swift completeness gate must move together.

ABI9 appends document-bound close approval: `page_close_generation`, request/consume/cancel functions and `authorized_close_decided`. Requesting approval does not destroy the page. Its one-use token binds the exact page, document, close generation and request; synchronous consumption rechecks that identity before destruction. Navigation, reload, cancellation, replacement and renderer failure invalidate prior authority. Tagged before-unload completion keeps late native callbacks from completing a newer operation. Callers recheck live app authorization after approval and publish disposal without suspension after successful consumption. Ordinary user-close functions retain their existing behavior.

ABI10 appends `lookup_site_icon` and `cancel_site_icon`, plus `site_icon_changed` and `site_icon_completed`. Lookup is ordinary-profile and exact-URL. A database miss fetches the icon the site's root page declares, or `/favicon.ico`, never the saved URL itself, through that profile's network context without cookies and stores it as an on-demand favicon (no ABI change); a missing icon is a normal fallback. PNG payloads are borrowed only during completion and bounded to 32 pixels per dimension and 64 KiB. Live change callbacks identify an existing page and its committed URL after native document validation; callers must revalidate current Swift page/profile ownership. Private contexts never consult the parent profile cache.

ABI13 appends `perform_inspection_form_action`, cancellation and a typed form
completion. Requests carry the trusted scope, snapshot/reference, independent
operation UUID, action kind and bounded borrowed UTF-8 bytes. Text replacement
is capped at 32768 bytes and select values at 4096. Native copies only bounded
request bytes; no output contains values. Completion adds `unchanged` to the
existing dispatch/uncertainty model, plus unsupported-control, invalid-value,
missing-option and ambiguous-option failures. Click/form operations share their
native receipt and physical-capacity accounting. Header, lock, function table
and Swift completeness checks change together.

ABI22 appends `set_extension_tab_placements` (`ArxExtensionTabPlacement`: page, AppKit window number, index, active, highlighted), `page_user_action_requests` (`ArxUserActionRequest` bits for refused WebAuthn and FedCM prompts in the current document) and `set_unattended_shutdown` (a shutdown deadline in seconds and an expiry callback on Chromium's watchdog thread). A primary main-frame HTTP challenge in an unattended run now also counts in `page_authentication_cancellations`.

ABI21 appends `page_authentication_cancellations`: the count of HTTP authentication challenges an unattended run cancelled for a page's current document instead of building a login prompt. `page_changed` follows each cancellation; it is always 0 in interactive runs.

ABI23 appends `page_find`, `page_stop_find` and `page_find_status`. Chromium highlights the matches; results arrive through `page_changed`, and a new document clears them.

ABI24 appends the `link_force_clicked` callback: a Force Click over an http(s) link offers that link once per press, with the page's document generation. Returning true takes it; native then skips Look Up and the press never becomes a click.

ABI43 appends the `cross_site_link_requested` callback (DEV-727): a plain click on an http(s) link to another site in an ordinary page offers that link once, after the navigation has been deferred, with the page's document generation. Returning true takes it and cancels the navigation; false lets it go on.

ABI50 appends the `external_link_requested` callback (DEV-857) and `ArxExternalLinkFlag`: a page's link for another app, after Chrome's scheme policy and before its lookup, dialog or launch, posted, with the page's document generation, its ordinary profile key (NULL in a private one), the requesting origin and gesture, redirect and private flags. Returning true takes it and Chrome shows and launches nothing; false hands it back to Chrome's path unchanged. The offer carries a token, and the appended API entry `external_link_is_current(page, token)` tells whether the taken link's source (main document and Chrome's exact initiator check) is still current.

ABI50 also appends `set_site_icon_fetch(enabled)` (DEV-796): whether `lookup_site_icon` may fetch a site's icon when the profile's favicon database has none. It is on by default and may be set before the runtime starts; off, a miss answers MISSING and nothing is requested. Swift exposes it as `ChromiumRuntime.setSiteIconFetch(enabled:)`, and Settings › General › Fetch icons for tabs that haven't loaded drives it.

ABI51 (DEV-940) adds `icon_url` to `site_icon_changed` and `site_icon_completed` (the favicon whose bitmap the page shows or the answer holds; empty when unknown) and appends the `site_icon_redirects` callback: a committed cross-document main-frame navigation's redirect chain, oldest first, http(s) only, at most the last eight, or a same-document commit's one address before the page's icon is known, with `truncated` set when addresses were left out; posted, never for private pages. It also appends `lookup_cached_site_icon`, `lookup_site_icon` without the fetch on a database miss. Strings are borrowed during the callbacks.
