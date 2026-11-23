# ChromiumHost

A development host for the independently built Helium framework. It starts Chromium before AppKit, hosts one page in an NSWindow, and supports the local HTTP smoke fixture run by `make engine-smoke`. It does not replace Arx's AppFeature composition. `make engine-host` creates its development-only app bundle with framework resources and helpers.

The host writes lifecycle and fixture-navigation stages directly to stderr, closes its fixture page before requesting shutdown, and emits `ARX_ENGINE_SMOKE_SUCCESS` only after a verified load and clean runtime return. This distinguishes a load timeout from native teardown failure even when stdout was buffered. The standalone host and production app smoke are separate acceptance gates.

The smoke runner explicitly supplies `--disposable-smoke-root` for a fresh mode-0700 directory immediately under the host work directory. Before loading Chromium, the host checks ownership, paths, bounded regular fixture files, a sentinel, the absent profile, and the exact loopback fixture URL. Inherited smoke environment alone cannot enable the mock Keychain. A valid fixture selects Chromium’s supported mock Keychain through the ABI5 run option; native startup emits `ARX_ENGINE_SMOKE_MOCK_KEYCHAIN`. The runner requires both that marker and successful verified load/shutdown. Ordinary host launches and signed app smoke retain the real Keychain. Mock-mode success does not validate production Keychain persistence, access control, or security.

`ARX_ENGINE_CONTENT_BLOCKING=0` turns content blocking (Helium's uBlock Origin, DEV-884) off before the engine runs, through the same optional export as the app; any other value or none leaves it on. `Scripts/engine/smoke.py` sets it to `0` for every engine smoke except the extension, extension install and site settings smokes, which test it. On a fresh profile uBlock reloads itself once after its first run and then selects and fetches lists from the network, and smokes that don't test it would race that.

The first Debug entry operation invokes the read-only bootstrap probe, followed by guarded allocator preparation before Bundle or environment configuration. Unsafe startup stops with a native diagnostic and nonzero exit. A nonempty smoke title enables entry, registration and framework-replacement markers; ordinary successful launches stay quiet. The host uses the same startup wrapper as the app.

`make extensions-smoke` adds `--extension-fixture` to that validated disposable launch. ABI7 startup creates its own fresh browser storage instead of accepting the caller's profile path. The exact compiled-in MV3 fixture tests worker/content-script messaging with a real tab ID, DNR, per-profile storage, disable/enable with stale-revision rejection, preserved permission-disable reasons, removal isolation, and private-profile refusal. Each stage and clean shutdown must emit its exact marker. No arbitrary extension directory, store install, user profile, or normal extension UI is enabled. This gate requires a compiled ABI7 framework; Swift and script tests alone do not verify extension execution.

The extension fixture reports fixed phase names around inspection and mutation. Its disable/enable sequence deliberately rejects the original stale inventory, waits for the disabled page to unload, then inspects again before enabling. Mutation responses are snapshots, not authority across asynchronous registry or preference updates. Immediate mutation races remain explicit failures; the fixture does not swallow them or retry with old authority. Deterministic host tests exercise revision changes during the wait, permission changes, cancellation and the deliberate stale probe.

`make close-smoke` adds `--close-fixture` to the same validated disposable launch. It obtains native approval, verifies cancellation and wrong-page rejection, then navigates/reloads and immediately attempts consumption before queued Swift navigation callbacks. The stale grant must fail while the new document survives. Finally it consumes a fresh grant once and reloads the independent surviving page. Exact stage markers, mock-Keychain evidence, verified completion and clean shutdown are all required. This fixture exercises already-granted authority. Pending reset/retry and delayed ACK ownership are covered by the exact production-policy/overlay harness; it does not simulate a real interactive before-unload dialog. Interactive refusal remains a separate manual check.

`make inspection-smoke` selects `--inspection-fixture` only after the same fresh-root and exact loopback checks. Its dedicated server serves compiled fixture documents and the initial index only. The host requires positive ordinary/closed-shadow semantic text, explicit button references, excluded current/former-password and form/generated/frame/canvas values, unchanged page presentation, strict small-budget rejection, scope/profile isolation, real reference invalidation after replacement and remove/reinsert, reload/navigation/history return, cancellation, close, private/unsupported refusal and expiry. Mutation input goes only to an owned attached fixture window; the page verifies trusted input. Every phase, native mock-Keychain selection and clean runtime return is mandatory. Failures print fixed phases and known error cases, never snapshot data.

The gate does not claim forced DOM-ID allocator reuse or a proven BFCache hit: the retained-node identity policy harness covers reused IDs, and history return must reject old references whether Chromium restores BFCache or reloads. Password controls are CSS-unmasked and include a former-password control; this does not toggle Blink's independent accessibility-password-values preference. Privacy policy tests cover that flag-independent filtering. Renderer physical-capacity/late-callback interleavings remain separately covered by compiled and Swift boundary tests. The fixture is a native acceptance gate only when executed against the matching built framework; compiling the host or mocking the runner is insufficient.

`make back-forward-cache-smoke` (DEV-943) selects `--back-forward-cache-fixture` after the same fresh-root and loopback checks. `BackForwardCacheSmoke` goes A → B → Back → Forward in one attached page and requires a real cache restore each way (`pageshow` with `persisted`, served once, the same script token), A's title, site icon and back/forward list, a new document revision with the same inspection document, and the stale pre-navigation snapshot refused. A video that played and paused before leaving must come back as a paused, playable media source under a new generation. A failure names its phase and, when a wait times out, the wait and the last state it saw (for media, the source's generation, playback and actions). `StoredSiteIconWait` reads A's icon from the profile's database (never the network) every 100 ms for up to five seconds until it is there under the fixture's favicon, at first load and after Back: a change notice only says to look again, and the load's end sends one before Chromium has stored the icon. Its time out names the page, the icon, the last read, the number of reads and the page's icon changes.

`make reference-click-smoke` launches only a fresh owned mock-Keychain profile.
It requires trusted accessibility-event count and no transient user activation,
background target activation without changing the key app window, duplicate and
stale scope/node refusal, transparent/private denial, navigation effects, and
uncertain timeout/cancellation receipts followed by exactly one visible effect.
The runner serves only its exact fixture routes and requires every phase marker
plus clean process exit. Owned direct mouse events are used solely for fixture
DOM replacement controls; they are never sent to another app or user page.

These are acceptance assertions, not evidence until run against the exact built
framework. Policy tests cover post-layout adversarial mutation and receipt/slot
caps; ordinary user interaction, pointer hit-testing/occlusion and other DOM
actions are outside this accessibility-activation fixture.

`make reference-form-smoke` uses fresh owned mock-Keychain storage and bounded
loopback-only HTTP evidence. Native input/change handlers report only allowlisted
booleans, never values. Separate scopes verify property-only changes preserve DOM
version while invalidating the original control baseline. The fixture requires
text/search/textarea/select effects, unchanged/no-event receipts, cross-kind
non-replay, option eligibility, privacy, limits, timeout/cancellation uncertainty,
actual navigation and clean shutdown. Native actions run with no app/window or
control activation; trusted mutation input is confined to exact owned URLs,
validated run IDs and mounted fixture windows. Mock mode does not validate
production Keychain persistence/security.

`make reference-scroll-smoke` uses fresh owned mock-Keychain storage and the
explicit-reference scroll API. Bounded loopback reports contain only numeric
fixture offsets and boolean focus/activation/trust evidence; these are test
observations, not public action-receipt fields. Required phases verify nested
movement, duplicate non-replay, clamping and unchanged/no-event behavior without
residual outer scrolling, horizontal/container/viewport choice, hidden-overflow
fallback, private and stale-reference refusal, navigation and clean shutdown.
The nested case keeps another owned window key while acting on the background
page. Cancellation, timeout and layout reentrancy are deterministic boundary
and extracted native policy tests; this fixture makes no in-flight cancellation
claim. Nothing counts as native acceptance until the exact matching framework
executes every required marker. Mock mode does not validate real Keychain storage.

`--link-context-fixture` requires the existing validated disposable root and loopback source. It sends native right mouse events through real page views, verifies main and offset HTTP iframe source/root coordinates, replacement and navigation invalidation, and private-page closure. It does not select a provider, request a remote href, copy the pasteboard or establish share-picker/provider-preview acceptance. Since ABI48 (DEV-814, DEV-818) `ContextMenuSmoke` follows: it configures the context menus and page menu with each item's own name as its title, right-clicks a text field, a password field, a selection, an image, a video and the blank page, reads each engine menu as it begins tracking, chooses one item as a click would and closes it, and checks the titles offered (edit items, spelling, Inspect Element in developer mode; no selection items or spelling in a password field; no app items when the host allows none) and the choice the app receives (the selection for Search and Share, the image's and video's addresses, the page menu's Share). Its markers are `ARX_LINK_CONTEXT_SMOKE_MENU_*`.

`--document-capture-fixture` is an explicit specialized fixture behind HostSmokeConfiguration's fresh local root/marker/0700 guard. Its native run option additionally requires mock Keychain and creates native-owned fresh profile storage. The host attaches one disposable page to a visible owned window and invokes only the bounded loopback controller; native assertions decode top/middle/bottom document pixels and compare actual viewport/state preservation plus cancellation/navigation/frame/limit exits. All phase markers and clean exit are required by `make document-capture-smoke`.

`--gesture-fixture` requires the validated disposable root and fresh native-owned
mock-Keychain storage. It runs real renderer ACK/CSS and native history checks
using synthetic browser-owned points, including a ten-entry direct jump and
cancellation/invalidation. It requires `ARX_GESTURE_SMOKE_SUCCESS` and all native
phase markers. This is not public NSTouch injection or physical-device evidence.
Physical-device delivery and tuning remain manual verification items.
Document acceptance also forces a tiny fresh-recording operation budget, checks unchanged page counters, then requires a fixed cyan update to appear in actual ordinary compositor pixels. Its command is a fixed loopback fixture action, not arbitrary script execution.

The owned document fixture now includes horizontal/fractional-scroll, fixed/sticky placement, lazy/no-fetch, loading metadata, and 125% zoom cases, plus whole-result canvas/opacity-animation/child-frame rejection. All preserve before/after page reports and viewport pixels. Fixed/sticky are verified through actual pixels rather than denied by position alone. Native runtime execution is pending; negative-overflow, non-default pinch, protected/animated image cases and late-stage cancellation remain explicit coverage gaps.

`make reference-keypress-smoke` selects `--reference-keypress-fixture` after the
same disposable-root validation and uses mock Keychain. Its static loopback pages
choose initial document focus themselves, then attempt hostile redirects during
keydown, beforeinput and textInput. The host requires correct normal editing,
Unicode, exact duplicate no-replay, suppressed redirected defaults, canceled
beforeinput, Enter/change submission refusal, background cancellation, unchanged
native window focus, and clean shutdown. HTTP evidence contains only finite
labels and booleans, never keys or control values. This runner is staged for the
next matching native ABI; compiling it is not renderer acceptance.

`make extension-install-smoke` selects the separate `--extension-install-fixture` option after the same fresh-root and exact loopback guards. Native startup signs only compiled MV3 fixture files with fresh in-memory keys, then every package uses the ordinary sandboxed CRX3 verifier. Required markers cover verified-candidate refusal before mutation, explicit install, real packaged worker/DNR, permission-increasing update refusal, explicit update preserving extension storage, wrong signing identity and corrupt bytes, one-use authority, cancellation retaining the physical slot, two-profile isolation, private refusal, and clean shutdown. The runner serves only the exact index route and requires the native-owned storage marker; caller-supplied profiles remain absent. This is separate from the old unpacked fixture. Neither gate claims process-restart, native messaging, popup/options, or production Keychain acceptance.

`make webstore-install-smoke` (DEV-765) selects `--webstore-install-fixture`, the same owned signed-install storage plus a loopback Chrome Web Store. The host passes the fixture server's `http://127.0.0.1:<port>` origin as `webstore_fixture_origin_for_testing`. Native then starts Chromium with its own `--apps-gallery-url` test switch, so the fixture's store page gets the real `webstorePrivate` API, and downloads packages from `<origin>/crx/<id>.crx`. The served package is a recorded, unmodified store CRX (`Scripts/engine/fixtures/webstore`), so the publisher-proof verifier runs for real without the network. Required markers cover a declined request that changes nothing, the review prompt's ID, version, SHA-256, source and permissions, a cancelled review, the install and the store's `completeInstall`, `already_installed` on a second click, the content script running in that profile and not in another, the store's status per profile, and a corrupt package and a package with the wrong ID refused before any prompt. DEV-951 adds the item installed by ID in another throwaway profile, the path `browser_settings` `installExtension` uses: a declined review installs nothing, an approved one installs it (`ARX_WEBSTORE_INSTALL_SMOKE_BY_ID`). A just-started profile keeps moving its revision for several seconds, so the run first waits for two reads half a second apart to agree (at most ten seconds, `ARX_WEBSTORE_INSTALL_SMOKE_UNSETTLED` if they never do), for this phase and for the store-page install's profile. Each prepare by ID then retries as the Extensions sheet does: a `staleInventory` reads the inventory again (phase `install-by-id-stale-retry`), and the third in a row fails. Content scripts are checked on `localhost`, because Chromium never runs extensions on the store's own origin.

Store updates (DEV-776) add phases to the same run, against the installed item: the store serving the installed version completes with `upToDate` and changes nothing; a corrupt package is refused before any prompt and the installed version stays; another profile, which doesn't have the item, is refused before any download. When the runner has a second recorded version of the item (`fixtures/webstore/<id>-next.crx`, passed as `ARX_WEBSTORE_NEXT_VERSION`), the update itself runs: a declined review keeps the old version and an accepted one installs the new one in that profile only. The store serves only an item's latest version, so the second recording has to wait for JSON Formatter's next release; until then the smoke prints `ARX_WEBSTORE_UPDATE_SMOKE_NEWER_SKIPPED`. The signed-install smoke checks that its permission-increasing v2 prompt carries `permissionIncrease`.

The staged extension options acceptance opens the manifest-defined options page
in each of two owned ordinary profiles and requires that it read each profile’s
distinct existing chrome.storage.local count. The runner requires
ARX_EXTENSION_SMOKE_OPTIONS_IDENTITY and ARX_EXTENSION_SMOKE_OPTIONS_STALE; the
latter proves an old inventory cannot open options after disable. These are
required assertions until executed against the matching rebuilt framework.

The staged action fixture selects only the exact native Extensions menu attached
to the owned compiled-fixture page. It requires a real ExtensionViewHost popup to
read each profile’s distinct stored counter, while its source navigation stays
unchanged. Old menu objects cannot reopen a popup after host reconfiguration or
source reload. Native-owned fixture identity alone permits the fixed title proof
on the popup view; normal extensions expose no such fixture bridge. The runner
requires ARX_EXTENSION_SMOKE_ACTION_IDENTITY and ARX_EXTENSION_SMOKE_ACTION_STALE.
These owned menu commands do not claim hardware input, IME or accessibility
acceptance, and remain unverified until the matching framework executes them.

For extensions-smoke only, the development bundle also contains the signed
ArxNativeMessagingFixture executable. Ordinary engine-host builds omit it.
Native startup registers its fixed manifests under native-owned fresh storage,
with exact allowlisted and deliberately forbidden extension origins. A real
extension page must verify one-shot and persistent messaging in each of two
profiles. The host observes only those reported owned child PIDs using signal
zero, then requires one-shot exit and persistent exit after document close; it
never sends a terminating signal. Every run requires
ARX_EXTENSION_SMOKE_NATIVE_MESSAGING_SCOPE and
ARX_EXTENSION_SMOKE_NATIVE_MESSAGING_LIFECYCLE as well as clean shutdown.

The next-batch extension popup link gate dispatches mouse input only to the actual visible disposable popup’s owning NSWindow. It requires exactly one original-source child offer, the unchanged source navigation, the exact loopback target and the child’s same-profile extension storage evidence. Its `ARX_EXTENSION_SMOKE_POPUP_LINK` marker is mandatory; actual execution awaits the matching native framework.

The next-batch runtime-options gate clicks the fixed compiled popup button and accepts a separate native-origin options offer without a pending Settings request. It requires the exact second profile/extension, manifest options URL, unchanged ordinary source and profile-isolated storage count. `ARX_EXTENSION_SMOKE_RUNTIME_OPTIONS` is required; no actual run is claimed before the matching ABI18 integration.

The `app-action` phase (ABI48, DEV-828) takes the app's path, as the site menu's extension tile does, with no native menu: `runExtensionAction` must answer `unavailable` while the page hosts no content and for a private page, and `invalid` for an extension that isn't installed, then open the fixture's popup anchored within 48 points of the screen point near the window's top left, with the source's navigation unchanged, and close it when hosting ends. It emits `ARX_EXTENSION_SMOKE_APP_ACTION`. Every action phase also requires the native Extensions button to draw nothing: transparent, borderless, untitled, no tooltip, at most 1×1 (DEV-849), and `ARX_EXTENSION_SMOKE_BUTTON_INVISIBLE` follows them.

The `popup-window` phase (DEV-1316, `ExtensionPopupWindowSmoke`) gives the engine its own popup window through `setExtensionPopupWindows` and runs the fixture's action from the app: the popup must open in that window, a child of the page's window within 48 points of the anchor, and take the keyboard; asking again brings it forward without a second window; typing into the fixture's field reaches the page (its proof gains `:input=a`) and grows it to 340 × 200, which the window follows through `resizeWindow`; making the page's window key closes it; after AppKit's `NSWindowWillMoveNotification` for it (the move a drag begins; the smoke can't drag without the screen) it stays when the page's window takes focus, until it's closed; typing "!" runs the page's `window.close()`, and Escape closes it. Then, with the app's `.staysOpen` rule, making the page's window key leaves the popup open and above that window, and after the window moves 40 points a resize keeps the popup with it. It emits `ARX_EXTENSION_SMOKE_POPUP_WINDOW`.

`make inspection-smoke`'s `pdf-loading` phase (ABI48, DEV-819) loads `/inspection/slow.pdf`, which the fixture sends in two halves four seconds apart: `documentType` must read `.pdf` while the page is still loading (and `.web` for the HTML page), and once it has loaded the PDF source read returns the document's bytes. It emits `ARX_INSPECTION_SMOKE_PDF_LOADING`.

`ExtensionSmokeElementPicker` (DEV-1019) runs after the removal phase on the second profile's ordinary page, where uBlock Origin has been running a while. It calls `startElementPicker(on:)`, as ⇧⌘H does in the app, and reads back what arx.js wrote to uBlock's storage (`elementPickerStatus(on:)`, `ArxEngineCopyElementPickerStatus`). uBlock may miss an ask while it starts or restarts after its first run, so a quiet ask is repeated, up to four times five seconds. Any answer but `outcome: "opened"` with `probe: "ok"` fails with that status (ids, outcomes and error messages only), and the picker's frame must then sit at the page's root (read through the developer tier). It emits `ARX_EXTENSION_SMOKE_ELEMENT_PICKER`. It needs an engine with `extension_windows_overlay`'s DEV-1019 `tabs.executeScript` edit; on one without it the probe reports the failed injection.

`ExtensionSmokeSiteFilters` (DEV-1019) follows on the same page. It adds `127.0.0.1##.arx-hide-target` and a `remove-class` scriptlet for `#arx-scriptlet` to My filters (`addFixtureFiltersForTesting`, `ArxEngineAddFixtureFilters`, which the engine takes only in the extension fixture run), then loads `blocking.html`, which the smoke server serves from memory (the host takes a root holding only `index.html` and its marker), until the first element is `display: none` and the second has lost its class, reloading while uBlock reloads its filters (six loads, two seconds each). uBlock injects both with `tabs.insertCSS` and `tabs.executeScript`, so this checks the same engine edit as the picker. It emits `ARX_EXTENSION_SMOKE_SITE_HIDING` and `ARX_EXTENSION_SMOKE_SCRIPTLET`, or fails saying which didn't apply.

`ExtensionSmokeOwnElementPicker` (DEV-1201) follows on the same page: it opens `/picker.html`, which `smoke.py` serves with a content security policy allowing no scripts or styles, runs `pickElement`, waits for the picker's host element on the page, picks the fixture's `aside` through the picker's testing hook in the translation world (the pick a click makes; the smoke can't move a pointer), and needs `hidden(filter: "127.0.0.1##aside.arx-pick-target")`, the line in `hiddenElements`, and the aside hidden after a reload, by uBlock's filter now. It emits `ARX_EXTENSION_SMOKE_OWN_ELEMENT_PICKER`.

Its `runMode` (DEV-1298, `ARX_EXTENSION_SMOKE_HIDE_ELEMENT_MODE`) then runs Hide Element's mode on `/picker.html`: a pick of `.arx-mode-undo` saves its line while the picker stays open, Undo (`unhide` and `showHiddenElement`) shows it again and takes the line out, a pick of `.arx-mode-target` stays and `describe` names it, Done closes the picker, and after a reload only the second is hidden.

`ExtensionTabsSmoke` (ABI21) arms one extra first-profile page so its action dispatches `action.onClicked`, presses the action shortcut, and requires the worker's `tabs.get`, `tabs.query` and `tabs.sendMessage` to reach that exact page while the other first-profile page, the second profile's page and a private page stay unchanged and uncounted. It emits `ARX_EXTENSION_SMOKE_TABS_SCOPE`. With ABI22 the source shares its window with the active first-profile page at index 1, and the second profile's and the private page get windows of their own. The worker then requires its window ID and index, `tabs.query` by `windowId`, `windowId` with `index`, `{active: true, currentWindow: true}` and `lastFocusedWindow`, and `windows.get`, `getCurrent`, `getLastFocused` and `getAll({populate: true})` to see exactly that one window with its two tabs. A second action press opens the popup, whose `{active: true, currentWindow: true}` query must return the inactive source it was opened for. It emits `ARX_EXTENSION_SMOKE_WINDOW_SCOPE`. The named command title now also requires the direct `tabs.sendMessage` reply next to the storage relay.

`ExtensionShortcutSmoke` stages actual source-window native key events for the compiled extension’s active named/action commands. It checks two-profile replies, exact source identity and duplicate/rehost replay refusal before action popup tests. This is owned AppKit event routing acceptance, not physical keyboard/system ownership coverage; the two SHORTCUT_SCOPE/SHORTCUT_REPLAY markers are mandatory for the next framework batch. Before each press it waits for Chromium to have the page's focused frame, not just AppKit's first responder: the renderer reports focus asynchronously (`DidFocusFrame`), a navigation or reload clears it, and a key pressed before that reaches the page as an ordinary key with no command. A developer-world `document.hasFocus()` read, which shares the frame channel with that report, is the signal.

`SiteSettingsSmoke` (`--site-settings-fixture`, DEV-716) runs `make site-settings-smoke`: a fresh profile lists every permission default; site exceptions for every permission are set, changed and removed; pop-ups refuse ask, a default refuses allow, and javascript:, credentialed and malformed origins and out-of-range zoom are refused; a default changes and comes back; a host zoom and the default zoom change `devicePixelRatio` on an open page without reloading and report a change for the profile; a second profile's settings stay apart; and private and unknown profiles are refused.

`BrowsingDataSmoke` (`--browsing-data-fixture`, DEV-647) runs `make browsing-data-smoke`: counts after a page stores a cookie and a site setting is made, counting only the kinds asked, one site's scope (the loopback page's own host, a registrable domain for a subdomain) and site clear (ABI40, DEV-633: another site's clear keeps the page's cookies, the page's own removes them and keeps site settings, other kinds and file addresses refused), refused future times, kinds and folders, a time-ranged clear keeping an older site setting, a second clear of one profile refused while the first runs, an all-time clear leaving nothing counted, a real download landing in a chosen folder, "Ask where to save" round-tripping, another profile keeping its own folder, and private and unknown profiles refused, a site clear included. ABI45 (DEV-729) adds a private profile opened from another profile: a file opened in a private page lands in the opener's downloads folder, then in its new folder once the opener changes it, and a private profile can't be an opener.

`--background-visibility-fixture` (DEV-936, `make background-visibility-smoke`) requires the validated disposable root and loopback source. It mounts one fixture page in a window and leaves another unmounted, then reads the pages' titles: the unmounted page must start hidden and have its timers throttled, freeze once five more unmounted pages follow it, and resume, become visible and draw on its first mount. Its markers are `ARX_BACKGROUND_VISIBILITY_SMOKE_*`; `SHOWN_MS` reports how long the first mount took.

Teardown that runs in a `defer`, such as releasing a content host or removing a temporary folder, goes through `cleanUp`, which prints `ARX_SMOKE_CLEANUP_FAILED <step>: <error>` instead of dropping the error. Steps never skip on an error: the engine smoke fails at once when find can't start or stop, script results that do not decode fail with the decoding error, and polling waits print what they could not read (DEV-969).

`make hang-smoke` (DEV-1009) adds `--hang-fixture`: a loopback page loops forever on a key. The host sends it one, waits for the hang report, waits on it and sees it asked again, runs two scripts on the looping page that both time out, the second taken rather than refused as busy, and one on another site's page (the same server as `localhost`, so it has its own renderer) that answers at once (DEV-1135), ends the renderer, and loads the page again on a new one (`ARX_HANG_SMOKE_REPORTED`, `ARX_HANG_SMOKE_WAIT_ASKS_AGAIN`, `ARX_HANG_SMOKE_TIMEOUT_LETS_GO`, `ARX_HANG_SMOKE_ENDED`, `ARX_HANG_SMOKE_RELOADED`). It needs a window and the ABI58 engine.
