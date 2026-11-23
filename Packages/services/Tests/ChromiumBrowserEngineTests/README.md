# ChromiumBrowserEngineTests

These suites read clients' `liveValue` directly and never resolve a dependency context or `@Shared` value, so they don't need `@Suite(.dependencies)` yet. A suite that starts using dependencies, a store or `@Shared` takes it (DEV-970): without it, every test in the process shares one set of dependency test values.

Download lifecycle reconciliation, origin preservation, private persistence exclusion, file safety, and storage failure tests. A native callback fixture verifies that initial profile and space labels are installed before event replay, without relying on async configuration. Engine callback ownership and cancellation routing are tested in ChromiumEngineTests. Real network download validation belongs to the signed app runtime smoke fixture.

Capture adapter tests reject stale/denied work before dispatch and discard results after authorization revocation, session replacement/closure, cancellation, or runtime shutdown. They preserve requested identity/limits and the protected-media warning, and map native busy errors without treating them as completed images. These tests use copied fixture bytes; actual viewport pixels require the signed native fixture gate.

Media adapter tests cover unknown/private ownership exclusion, stale revisions/generations/profiles, pre-dispatch cancellation, page closure during an uncooperative native await, source activation provenance, and typed native failures without optimistic playback changes. Actual PiP windows, playback, and private OS metadata need the ABI6 native fixture.

Media identity regressions retain/replay old Swift snapshots while independently changing native fixture generation, and require synchronous refusal. Removed/private/wrong-profile/wrong-tab/zero-generation sources and finished observation cannot reach or pass authoritative validation.

ChromiumExtensionsAdapterTests verify legacy-profile mapping, distinct permission groups, stale/forged inventory requests, permission escalation and unknown disable reasons, consumed authority, native postcondition failures, and profile deletion during native waits. Folder-load tests cover its separate capability, consumed inventory authority after a typed invalid-manifest failure, `canReload`/`sourcePath` mapping and reload reaching native management only for reloadable rows. Fixtures construct native value responses only; they do not claim actual extension execution.

Retained extension clients are checked across unavailable, ready and stopped runtime states so capability is not frozen at construction.

Authorized-close tests cover a stored client composed before runtime readiness, missing capability, revoked authority and replaced sessions across approval, cancellation, native stale-document rejection, refusal and synchronous disposal before publication. These are service/adapter checks, not native before-unload UI acceptance.

ChromiumSiteIconCacheTests cover shared subscribers, exact profile/page isolation, bounded LRU eviction and concurrency, negative caching, live invalidation, private/unconfigured identity denial, and profile disposal/recreation with uncooperative late lookup completion. With a store (DEV-809), a stream opens with the stored icon and keeps it after a miss, and a live icon, including one after a page-load refresh, replaces the stored one on disk. Rows mounted off screen read only the database until a row showing the icon asks, and at most four reads that may fetch run at once while database reads go on (DEV-940 follow-up). A bang's icon (DEV-1311): highlighted with one stored it reads nothing more; without one, its row and the field fetch it once together; when the last stream that allowed the fetch ends while a database-only one remains, the fetch is cancelled and a database read takes its place.

ChromiumSiteIconServiceTests retain the actual preconstructed engine client across runtime readiness, check successful lazy activation and stopped-runtime denial, and reject profiles removed before activation. A pre-ready client shows only the stored icon of the requested, configured profile, and nothing once that profile is removed (DEV-809). A `neverFetching` client, as a headless run's windows get, reads only the database.

Refresh tests cover cached misses under canonical/same-document saved aliases, profile isolation, burst coalescing without restarting in-flight work, and generation revocation between enqueue and refresh.

Surface tests combine real AppKit hosts, BrowserSurface coordinators and the engine registry with mock native page creation. They cover both host replacement/teardown orders, creation before and after replacement, single-session ownership, cross-window refusal, suppressed and dismantled host callbacks, and mounting of noninteractive pages. Test windows stay hidden; actual Chromium attachment is checked by the signed bang-navigation fixture.

A runtime-to-adapter-to-cache regression begins with a cached missing icon, suppresses native icon callbacks, then closes the source or completes a replacement navigation. The exact saved key refreshes from the ordinary database lookup in both cases.

MCP capture adapter tests revalidate ordinary profile, synchronous native epoch and native-host visibility at entry and completion, preserving explicit user capture defaults. AppKit mock-host tests cover visible non-key eligibility, hidden/minimized windows, detach and replacement without displaying windows or requesting focus.

Inspection adapter tests hold native completion across source/scope/document/profile/session and grant changes, cancellation and shutdown. They verify output budgets, historical-version mapping and actionable native failures without substituting a synthetic fixture for actual renderer acceptance.

The inspection factory tests retain the same pre-ready client through startup and shutdown, reject absent native tables, and prove a loaded private page with matching session/document revisions never enters native inspection.

Interaction adapter tests reject mismatched tab/snapshot/reference/source identities before native invocation, recheck live authority at submission, and preserve dispatch uncertainty after click-induced navigation or shutdown.

ChromiumInteractionFactoryTests retain the same client before readiness and after shutdown, reject an absent ABI table, missing/disposed sessions and a loaded private page with otherwise matching revisions, and assert rejected sources never reach native activation or the final authorization callback.

Wait tests use an injected clock/event stream and a mock C callback table. They verify deadlines, cancellation cleanup, event-as-wakeup semantics, stored clients across startup/shutdown, cached-publication/live-epoch mismatch, private pages, native start/commit, and same-tab-ID close/reopen without accepting the new page. These are deterministic policy tests, not evidence of actual Chromium loading.

ChromiumFormAdapterTests verify rejected identities never invoke native code, authority is rechecked at final submission, and post-submission navigation/lifecycle changes preserve dispatched, uncertain or known unchanged receipts without returning values.

ChromiumFormFactoryTests hold the same pre-ready client through readiness/private-session creation/disposal/shutdown and verify rejected ownership never reaches final authority or the C form callback.

ChromiumScrollAdapterTests reject unavailable/non-finite/out-of-range/foreign/stale sources before native invocation, recheck authority at submission, forward the exact physical axis and canonical delta, reject foreign native receipt identities with uncertainty and preserve precise known dispositions through late lifecycle failure. Native runtime fixtures remain required for actual container selection, edge clamping and no chaining.

ChromiumScrollFactoryTests retain a client across startup, private-session creation/disposal and shutdown. Unavailable or foreign ownership never reaches app authorization or the C callback; an absent native table never advertises scrolling after readiness.

`ChromiumLinkContextFactoryTests` checks original native-page/profile mapping for ordinary and private pages, unknown-page rejection, pre-ready unavailability and closed-session invalidation.

Retirement tests verify unavailable defaults, active/pending profile refusal, exact durable acknowledgments, lost/error receipt admission blocking, and distinct queued versus erased states. They use in-memory ABI fixtures without user profile paths or real cleanup.

Retirement acknowledgment tests distinguish exact durable blocked cleanup of an irrevocably retired request from rejected, active, stale, undurable or foreign requests. Production C++ CollectResult policy coverage separately proves that distinction; client snapshots do not infer durability from a generic failure status.

Guarded keypress tests deny missing capability before native work and capability
revocation at the final synchronous authorization callback.

Extension options tests exercise the real Swift runtime callback and engine
adoption path with a deterministic native transport: one exact offered page is
published, rejection removes session rows without double native destruction,
source navigation stays unchanged, and a completed request cannot publish again.
Adapter tests require a fresh opaque inventory after options opening even when
its native revision does not change.

`ChromiumSiteSettingsMappingTests` (DEV-716) covers mapping native listings to `SiteSettings` (managed defaults, sorted exceptions, names a newer engine adds left out) and native failures to `SiteSettingsFailure`.

`ChromiumProfileDataMappingTests` (DEV-647) covers mapping native counts, kinds, download settings and failures. `DownloadLedgerTests.clearingDownloadHistoryForgetsOnlyThePickedFinishedTransfers` covers `removeFinished`.

`ChromiumProfileReleaseAdapterTests` (DEV-880) check that the engine adds its pages to the app's uses, maps Default to the nil key, starts a profile's grace period when it stops being used, and tries a profile native refused again on the next sweep, and that an unloaded profile's site icons come from storage without loading it and are read from Chromium once it loads. `ChromiumDownloadsTests` and `DownloadLedgerTests` check that configuration prepares only a profile with a persisted transfer still in progress, until Chromium reports or initialization settles it.

`TabNavigationStoreTests` (DEV-878) cover a tab's saved back/forward history: it reads back before and after its write lands and after a relaunch, a removal goes, Clear History forgets only its profile's folder, and launch forgets tabs that are gone.

`ChromiumSiteCookiesTests` (DEV-877) check that a Chromium cookie keeps its domain, path, Secure, HttpOnly and SameSite when it becomes an `HTTPCookie` for a WebKit page, that an unspecified SameSite reads as Lax, and that expired or nameless cookies are dropped.

`ChromiumCastAdapterTests` (DEV-927): the engine's Cast picker maps to `BrowserCastPicker`, dropping modes the app doesn't offer and reading unknown states and kinds as unavailable and generic.

`BrowserHiddenElementsTests` (DEV-1019): a site gets its own and its parent domains' filters once, in order, and the selector is what follows the sites.
