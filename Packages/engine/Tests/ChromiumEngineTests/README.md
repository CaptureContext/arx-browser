# ChromiumEngineTests

Boundary tests for missing/incompatible frameworks, runtime single-use semantics, page invalidation, callback copying, and close behavior using a test C function table. These tests do not load a Chromium runtime.

Capture tests cover borrowed byte/document copying, limits, wrong-page callbacks, cancellation before and after native submission, late delivery, page closure, shutdown, and typed native failures. They exercise continuation ownership but do not assert compositor pixels or native physical-work drainage.

Run-option tests prove that the default path invokes ordinary startup, explicit test mode passes the mock option, and an incomplete ABI is rejected. Host fixture ownership and path validation is tested separately in `ChromiumHostTests`; neither suite accesses Keychain services.

Bootstrap observation tests query real process thread/zone metadata and verify that an existing allocation, its owning zone, and zone count remain unchanged. Fresh-process automation separately covers silent ordinary startup and distinguishing one from multiple threads.

Loader tests preserve the typed missing-framework error and reject loading before host allocator preparation. Actual registration is confined to fresh native automation subprocesses; the Swift test runner never replaces its allocator.

Media tests copy borrowed metadata, replay snapshots, reject unowned/old callback revisions, validate activation generations, drain pre-canceled/in-flight/closed requests exactly once, and map native failures without inventing playback. They also distinguish manual and automatic capability bits and reject unknown native bits. They load no native framework or PiP window.

Extension tests cover profile/runtime/revision ownership, copied metadata, pending and unknown disable reasons, inconsistent capabilities, stale native revisions, wrong-profile delivery, cancellation, late callbacks, shutdown, byte caps, typed native failures, explicit startup options and complete ABI tables. They use C function-table fixtures and do not claim real MV3, policy, or storage behavior; `extensions-smoke` owns those acceptance checks.

Synchronous media identity tests change the C fixture generation before any updated Swift callback, then replay an obsolete callback. Native validation still refuses the old source. Tests also cover unavailable/missing table functions, foreign/closed/private pages, zero generations and absent native sources. These deterministic boundary tests do not execute the actual Chromium observer; isolated syntax checks and later packaged native fixtures remain distinct gates.

Document-close tests verify cached epoch use before queued navigation delivery, runtime/page/request ownership, cancellation and late callbacks, refusal, stale native consumption, replay, shutdown drains and disposal without duplicate native destruction. Native event scheduling and document behavior are separately exercised by the disposable close host.

Missing optional close-generation functions preserve navigation callbacks without trapping and provide zero close authority. The generation query also rejects foreign, closed and stopped runtime ownership.

ChromiumSiteIconTests cover exact profile/page correlation, bounded PNG metadata, missing-icon fallback, native failures, queued completion after cancellation, completion-before-task-resume cancellation/disposal, profile removal/recreation, private identity denial, and shutdown draining. They use a fake native function table; real profile database/network behavior requires the owned signed favicon fixture.

Notification regressions close the source before consuming its queued change, then remove/recreate the profile. The valid write survives source closure; old profile generations and old live pages cannot refresh the replacement profile.

Lifecycle refresh regressions cover close, completed/failed loading, terminal document replacement, repeated progress/title/history snapshots, private pages and removed/recreated profile generations without a native favicon notification.

The screenshot document-stamp regression advances the mock native epoch while the published page/navigation epoch stays unchanged, then verifies that the synchronous query observes the new document and returns nil after close. Missing native callbacks also fail closed; these injected tests do not establish real screenshot rendering.

Reference-click tests exercise the exact synchronous authorization/submission
order, revocation inside authorization, pre-cancellation, cancellation after
submission and late receipts, duplicate requests after close/revoke, binding
isolation, malformed callbacks, per-page pending admission, input/receipt limits,
and unavailable/private/foreign runtime ownership. No native framework is loaded;
these tests do not establish actual event dispatch or user-activation behavior.

Reference-form tests exercise unchanged receipts, cross-kind/payload duplicate
privacy, click/form shared physical slots after cancellation, late receipt
refinement, shared scope exhaustion, payload byte boundaries, final authority,
malformed callback kind/status and page/scope/runtime disposal. They use the
same C-table fixture as clicks and do not establish real form event behavior.

Reference-scroll tests exercise shared click/form/scroll admission, canonical
axis/delta receipt bindings, bounded finite deltas, exact authorization order,
cancellation with late unchanged receipts, wrong callback families and invalid
statuses. They use the same C-table fixture; native movement, clamping, container
selection and focus/activation behavior require `reference-scroll-smoke`.

`ChromiumLinkContextTests` covers malformed/oversized/unsupported native inputs, unavailable observers, exact payload authority, dismissal and private observer replacement. Owned `link-context-smoke` supplies separate actual renderer acceptance.

Retirement boundary tests copy bounded typed callback payloads, preserve irreversible receipts after caller cancellation, reject invalid states/denied consent, distinguish restart and erasure, and reject stale callbacks after shutdown. They use fake ABI tables and perform no real profile mutation or reboot.

Capture tests include full-document callback separation, geometry distinct from viewport/device scale, native capability denial before submission and cancellation with late borrowed payloads. These wrapper peers do not establish native pixel/resource acceptance.

Gesture fixture startup tests require explicit mock mode and verify an ordinary
runtime cannot call the native fixture driver. Native renderer arbitration and
actual history jumps belong to the separately rebuilt signed gesture fixture;
these boundary tests do not claim trackpad behavior.

Guarded keypress tests require the separate capability, distinct kind4 exact
payload binding, unsupported-key refusal before authority, duplicate receipt
reconciliation after capability loss, and cancellation retaining the physical
lane until the native reply. They do not substitute for hostile renderer fixtures.

Unpacked tests cover folder path standardization, inventory profile/revision binding, missing capability, foreign-runtime and non-file URLs, typed missing/unreadable/invalid-manifest failures with a bounded control-free reason, and reload only for native `canReload` unpacked rows.

Focused-link tests (ABI37, DEV-713) cover a link coming back with its document revision, nil for no link, other schemes, credentials, a reply for another page and a zero revision, stopping with a read pending, a late reply after stop, and an engine without the call. `focused-link-smoke` covers the real Chromium read.

Site-settings tests (ABI38, DEV-716) cover decoding a listing, what each permission and zoom call passes to native (origin, setting, host, factor, and the empty default), edits refused before reaching native, failures mapped from native statuses, change notifications reaching every observer, and stop failing a pending request and ending observers.

Profile-data tests (ABI39, DEV-647) cover what counting, clearing and the downloads calls pass to native (kinds mask, start time, 0 for all time, folder or none), decoding counts, failed kinds and download settings, requests refused before native, failures mapped from native statuses, and stop failing a pending request.

`ChromiumProfileReleaseTests` (DEV-880) check that a released profile is prepared again on its next use, that one native refuses stays prepared, that a download start holds its profile until native answers and finishing counts as a use, that `isLoadedInChromium` asks native and is nil without the export, and that private profiles and engines without the export release nothing.

`ChromiumPageUnloadTests` (DEV-873) cover the tab unloading exports with fake function pointers: engines without them can't unload, each native status and blocker mask maps to its outcome, the reason reaches native, and closed pages or a stopped runtime are never asked.

`privateWindowSwitchNeedsTheNativeCapability` (DEV-889) covers the inventory's `allowedInPrivate`/`canAllowInPrivate` and the two private-window actions.

`ChromiumRuntimeTests.navigationStateIsOptionalAndReadsOnlyOwnPages` (DEV-878): back/forward history is optional on older engines and never read from a page the runtime doesn't run.

`ChromiumCastTests` (DEV-927): the picker's JSON decodes, reports reach their page and an unreadable one is closed, answers reach only their page, clearing the handler reaches the engine, and older engines cast nothing.

`ChromiumElementHidingTests` (DEV-1019): an engine without the exports neither picks nor lists; the picker and Show reach the engine for the page; the hidden elements decode, dropping what isn't a list of filter lines, and a refused read is nil.

`ChromiumElementHidingTests` also cover `ArxEngineHideElement` (DEV-1201): an older engine has no picker; the picked line, and the ask without one, reach the engine for the page, and a refusal answers false. `ChromiumElementPickerTests` (DEV-1201) run the picker's script in WebKit's client world, an isolated world as the engine's translation world is, on pages loaded offscreen: the selector each pick makes (an id, a lasting class past a made-up id, a sibling's place, up to an ancestor's id, a test id, hashed and state classes left out, tags alone anchored at `body`) finds only that element; a pick in a same-origin frame is named in its own document and ↑ widens to the frame; the chip's names; the outline (2 px, 6 px corners, halved at 200% zoom) and the chip above its top-leading corner, or inside it at the top of the page, on a page whose policy allows no styles or scripts; a dark page; a pick told once and the element gone; ⇧⌘H again closing it and leaving nothing behind; a pick not yet told surviving the next open; the page's own events neither picking nor closing; `site(of:)` and `filter(site:selector:)`. DEV-1206: a pick made through commands, as the app's view over the page sends them, never reaches the page's own capture-phase listeners on its window and document, and a click one of them would turn into a navigation doesn't navigate; keys from the view widen, narrow, pick and leave, and act on a move that came with them, and a secondary click leaves; the view's points become the page's at its pixel ratio. `ChromiumElementPickerInputTests`: the view covers the page as its topmost subview and takes its clicks (a drag picks nothing, a secondary click leaves) and keys (other keys go nowhere) so the page's own view gets none, gives the keyboard back when it goes, takes it back from the page's own views but not from the rest of the window until the page is clicked, tells a pointer over something covering the page, such as Hide Element's toast, as having left it (DEV-1315), coalesces moves, puts back what a busy page didn't take, and passes the wheel on to the page. `ChromiumElementPickerSnapshotTests` write `element-picker-light.png` and `element-picker-dark.png` when `ARX_DESIGN_SNAPSHOTS` names a directory.
