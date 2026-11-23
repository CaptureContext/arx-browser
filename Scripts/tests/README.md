# Automation tests

Python unittest tests for task dispatch and generation helpers. They verify that project failures stop workspace generation, full validation stops before builds when tests fail, exit codes survive log capture, and workspace generation includes real packages in deterministic order. They also cover XML escaping, preservation of workspace settings, unsigned project generation, and signing-team validation without changing the caller's environment. Tests use temporary directories and require no running Xcode process, external network access, or signing credentials. Native bootstrap probes use the installed Xcode command-line compiler.

Run with `make test`.

Agent eval tests (`test_agent_evals`, DEV-1026) check the usage accounting (rounding, instructions, tool descriptions without annotations, arguments, text results, images and error codes, and the listing each call was made with, for the per-turn figures), the loopback fixture's pages and form posts, each stand-in agent's calls against a fake MCP session that answers as Arx does (one read for an article; adding the find group with `browser_more_tools` only when `browser_find` isn't listed; a form batch aimed at the controls beside their labels, finished one call at a time when a step uses up the snapshot, typing a field that refuses a whole value and taking a dispatched click as sent; an email field that nothing fills; the cheaper kettle; and stopping when interaction isn't granted or is refused), known-issue statuses, the recording relay and its tool listing, the report and baseline with the per-turn columns, and Claude Code's arguments and stream parsing. They don't launch Arx; `make agent-evals` does.

Load ladder tests (`test_load_ladder`, DEV-1027) check the stop rule (each limit breaks only past its value, reasons come in a fixed order, an unread value breaks nothing), that a ladder stops at its first broken or failed step and keeps the one before as its ceiling, that a step past MCP's mutation budget ends it without failing it and that the default awake ladder fits that budget, that switches never reselect the selected tab and that a long stall counts for each probe interval it held, the options (`--quick`, rising steps, known ladders, and an unloaded step's settle past uBlock's post-launch list update, DEV-1180), reading swap use, rewriting a workspace's unpinned tabs for the unloaded ladder, the report and the per-model baseline. They don't launch Arx; `make load-ladder` does.

Sidebar scroll tests (`test_sidebar_scroll`, DEV-1238) check the options (the ticket's tab counts and pointer positions by default, `--ref` or `--app`), that each scroll leg turns back before the list could reach its end, that runs which lost the front or whose own clock stalled are left out of the medians, the table, the before and after comparison and the results files, and that the driver builds once per source and passes its own self-test (frame gaps, dropped frames and missed intervals at 60 and 120 Hz, the scroll script's legs and pace, and reading another process's main-thread CPU). They don't launch Arx or touch the screen; `make sidebar-scroll` does.

Developer tools smoke tests check that every binding page has its own title, that live page loads count up and are not cached, the RFC 6455 handshake, that only the first live socket receives one reload and only after it is requested, the renderer child selection from `ps` output, the localhost fixture environment, and that phase markers must appear whole and in order and are all printed by the Swift runner. They do not launch Chromium; `make developer-tools-smoke` checks the inspectors.

Local failure smoke tests check that the plain-HTTP loopback fixture answers `http://` with its title and fails a TLS handshake, and that the app environment names it with an `https://` loopback URL. They do not launch Chromium; `make local-failure-smoke` checks the real `ERR_SSL_PROTOCOL_ERROR` and the http:// suggestion.

Little Peek smoke contract tests require both exact lifecycle markers, reject diagnostic-only marker text, preserve exclusive fixture creation, and verify that its document nonce is generated on load without persistent storage. The post-exit history check rejects temporary Little Peek visits in any profile index. These tests do not launch Chromium; native view, document and responder preservation are checked by the signed app fixture.

Engine overlay tests reject changed or ambiguous upstream anchors, check repeated application, and verify Arx uses its own bundle, team, and keychain identities.

Engine upstream tests (`test_engine_upstream`) pick the newest published helium-macos release past the lock, classify it as a minor release, security respin or Helium-only release with its due date, resolve a tag's commit, submodule and Chromium version, write the bump pull request, and move the lock and every file naming the pins. Anchor check tests (`test_engine_anchors`) parse and apply unified diffs as GNU patch does (offsets, whitespace, fuzz, new and deleted files), route files to Chromium, its `DEPS` repositories or Helium's `deps.ini` archives, fetch each file the overlays open once, and report missing anchors and changed vendored files. GitHub, Gitiles and the archives are fakes; no test reaches the network.

Inspection tests compile production shadow-including privacy, exact-name, retained-node reference and retirement policies under ASan/UBSan. They verify repeated expiry sends only one renderer retirement message while retaining physical capacity, reject changed overlay anchors, and include renderer/Blink objects in the native compilation gate. Owned HTTP fixture tests preserve secret controls, excluded surfaces and synchronous replacement cases; these tests do not establish actual Chromium semantic output.

The dedicated inspection runner rejects mixed fixture modes, incomplete phase evidence and unsuccessful shutdown. Its HTTP handler refuses directory listings and profile files. Host tests check semantic sentinels and owned input coordinates; real inspection/reference behavior requires `make inspection-smoke` against the matching framework.

Engine cache tests run with no completed source build and cover restoring links/permissions, repeat restores, corrupted archives, fetching from a `file://` URL with no local archive, size and checksum mismatches of a download, a missing release asset, the archive lookup order, `make engine-cache` output, stale source/architecture metadata, escaping paths and links, incomplete frameworks, and source-build precedence.

Engine bundle tests reject missing helpers/resources, misplaced version links, missing execute permissions, wrong framework metadata and incompatible Mach-O architectures. They cover fetching and validating an engine from a `file://` URL, offline reuse, required runtime builds, and keeping engine requirements out of preview builds. Runtime smoke tests preserve diagnostics on preflight failure, timeout and an early exit without the success marker; a failed host prevents the app smoke from starting.

Signing tests enforce team filtering, fail-closed missing certificates, explicit development signing, and unsigned builds that avoid Keychain access and preserve the signed app output. Profile tests select the newest Match profile by name for the identity, reject profiles of another team, app, kind, or certificate, expired ones and ones without the iCloud and push grants, install override and legacy-directory profiles where Xcode looks, honour the override paths, and check that signed builds pass the profile and environments to Xcode, stop before Xcode without a profile, and fail when the built app has no embedded profile. `test_appcast` covers `make appcast` with stand-in tools: disk image names, refusing previous builds at or above the new one and a version already released with another build, the tag as the version alone, ignoring an `Arx.dmg` among the previous disk images, staging the `Arx.dmg` copy only after `generate_appcast` and listing it on both channels, the repository and app checks (version, build, key, feed), a keychain key that isn't the app's, `generate_appcast` limited to the new build and never given a key, reading the new image's signature from the feed, and that the `gh release create` command is only printed. It also checks that `.xcodegen/macOS.yml` takes `SUFeedURL` and `SUPublicEDKey` from build settings whose defaults (an empty key and the placeholder feed `AppUpdaterClient` refuses) keep updates off, and that the engine build keeps Helium's Sparkle disabled. `test_privacy` (DEV-861) checks that `.xcodegen/macOS.yml` declares exactly the usage descriptions in `Scripts/core/privacy.py`, which the engine host also uses, and, when the engine source is checked out, that the table covers every usage description Chromium declares, since macOS terminates Arx when Chromium asks for a permission without one. Release tests also check that the newest disk image is never an `Arx.dmg` copy, and sign a Sparkle framework inside out with the hardened runtime and keep `Downloader.xpc`'s entitlements. Release tests check that the Developer ID and development identities each embed their own profile with the matching iCloud and push environments, that only the app gets those entitlements, and that the release check rejects a missing or foreign profile. `test_cloudkit_probe` covers the probe's output parsing and refuses to launch an app without a profile or the container entitlement.

Standalone smoke contract tests inspect the explicit disposable-root argument, private fresh fixture, loopback URL and selected profile, then require exact native mock-mode and success markers. These tests mock process execution and do not validate Chromium or Keychain behavior.

Build-product tests cover custom signed output paths, explicitly isolated unsigned products/intermediates, configuration and signing arguments shared by build/settings queries, missing products, launch and preview path propagation, and stopping after build failures. A simulated global custom output location verifies that unsigned output does not replace the signed fixture. Shared option tests cover preview-test concurrency, invalid limits rejected before preparation, and absent limits preserving Xcode defaults.

Process smoke tests reject unrelated PIDs, unknown/unsandboxed helpers, external executable identities hidden by packaged-looking argv, missing executables and explicit sandbox bypass flags. A symlink to the actual bundled executable remains valid. Runtime success requires separate packaged renderer, GPU and network observations; transient pre-sandbox startup samples never count as positive evidence.

Bootstrap probe tests use Xcode clang to build a tiny temporary C executable and inspect fresh single-threaded and deliberately multi-threaded processes. They verify explicit smoke-only output without loading Chromium or changing allocator zones.

Allocator bootstrap tests compile the exact pinned upstream stub and wrapper into temporary C++20 subprocesses. They verify allocation preservation, idempotence, unsafe-state refusal, source hashes and pin/license retention. No Chromium framework is loaded; real allocator replacement requires signed app smoke.

Engine overlay tests include idempotent unique-OTR media privacy policy replacement; native object-gate tests reject a missing media bridge before compilation. These tests do not validate actual video PiP or macOS Now Playing redaction.

Extension runner tests require every native fixture marker, the explicit developer argument, an untouched caller profile path and clean exit. All process execution is mocked; actual MV3 acceptance requires the separately built ABI7 framework.

Media fixture tests verify the checked-in synthetic VP8 hash, exact HTTP range reconstruction and rejection, bounded fixture routes, exclusive owned-root setup and all-phase completion markers, of which only PiP over a full-screen window may be replaced, by its exact no-full-screen-Spaces skip line. Actual playback, PiP windows and private metadata policy require the separately built ABI6 framework.

The media activation contract harness compiles the production runtime callback body with both overlay-generated manager branches against counted controller doubles. Accepted and rejected owned callbacks suppress fallback focus; unowned sources and an unset callback preserve Chromium’s default. It tests control flow, not an actual PiP window.

`test_fairplay_bridge_script.py` runs the FairPlay bridge script (DEV-1144) under node against a stand-in DOM, skipped without node. A `<source>` given a FairPlay playlist before it joins a player goes to that player as it's inserted (`replaceChildren`, `replaceWith` and a comment placeholder's too, and by any other route, at once or later), none once its `src` is removed, even one made after the keys went to another or one holding the previous track, a clear playlist's `<source>` keeps its `src`, and a FairPlay playlist from a page without FairPlay keys makes the page give up (`failed`), so the app falls back. An element playing an ordinary source that the bridge takes over pauses its own player, in or outside the document, and the page hears none of its trusted `pause` or `timeupdate` events, not even through capture listeners on the element or on a detached ancestor; an idle element's player isn't touched, and one that leaves the bridge is heard again (DEV-1158). It doesn't run Chromium or Spotify.

`test_loopback_server.py` checks that the app smoke's fixture answers on both `127.0.0.1` and `::1` at one port with one shared state, so a phase can open its pages on `localhost` (DEV-1000); it skips a port taken on `::1` and serves `127.0.0.1` alone without IPv6 loopback.

`test_media_freeze.py` compiles extracted production lease ownership, reference
counts, actual-PiP notification, native eligibility and terminal cleanup. It
checks weak-page destruction, policy removal/replacement, nested scopes, missing
PM, private/paused/ineligible sources, metadata replacement without a lease gap,
timeout/cancel quarantine and observer teardown. Four separately injected
Chromium graph tests cover already-frozen acquisition, connected pages, actual
PiP handoff and pre-hide protection with more than five visible tabs. The Python
tests do not execute that graph suite or establish real PiP acceptance.

The private-profile lifetime harness compiles production retirement and download-observer bodies under AddressSanitizer/UndefinedBehaviorSanitizer. Queued Chromium doubles exercise immediate fresh reopening, retained-transfer cancellation, terminal delivery ordering, stale retirement generations, storage-kind reservation, reentrant callbacks and shutdown. The site-icon shutdown double verifies that observation stops exactly once after the runtime is marked stopped. Private preference regressions also verify manager-before-reset and reset-before-publication ordering, inherited false/true and managed values, later parent updates, untouched ordinary preferences and no reset on repeated prepare or observation. Real storage isolation and download continuity still require the rebuilt signed app fixture.

Extension fixture identity tests compile the native startup and path-accessor bodies against a real temporary filesystem. They require symlink aliases to match UnpackedInstaller's canonical path, fail startup when the created path cannot resolve, and keep ordinary startup free of fixture filesystem access.

Close policy tests compile the production one-use document grant and the overlay-generated RFH identity, completion, reset and no-handler bodies with ASan/UBSan. They cover reset without ACK, waiting=false posted completion, owned→ordinary→owned transitions, old tagged and unowned ACK rejection, other initiators, cancellation, replay and a surviving vanilla manager after RFH replacement. Every pinned overlay anchor is independently mutated to ensure preparation fails closed; repeat application must be identical. Close runner tests require each stage marker but do not execute Chromium. `make close-smoke` exercises actual granted-token invalidation and one-use destruction; pending renderer/reset interleavings remain covered by the production policy harness rather than claimed as real-browser evidence.

Engine build checks require the site-icons bridge object alongside the existing native units, so a missing favicon implementation cannot silently pass the native object gate.

`test_site_icon_smoke.py` verifies the disposable favicon marker contract, exact opaque PNG fixture pixels, cookie-required loopback image delivery and mandatory native phase markers. The signed app fixture owns real Chromium page/database acceptance.

Favicon restart checks require every startup/success marker and zero image/page requests; the HTTP fixture denies all site-icon paths during the second process. Timeout tests verify only the newly owned host is killed and crash injection is not inherited.

The app-smoke result verifier now requires `ARX_MCP_CAPTURE_NATIVE_SMOKE_SUCCESS` independently of the generic MCP and organization markers. Removing only this marker fails even when exit status, allocator evidence and every other feature marker succeed. These Python tests verify the gate, not native pixels or MCP authorization.

The app-smoke verifier requires the independent `ARX_MCP_INSPECTION_NATIVE_SMOKE_SUCCESS` marker even when all older phases and allocator evidence pass. Reusable semantic HTTP fixtures are tested separately from renderer behavior.

Reference-click native tests compile the exact Blink dispatch body and browser
admission/cancellation/delivery methods with deterministic peers. They cover
post-layout document/node/authority changes, hidden/inert/disabled eligibility,
website mutation during dispatch, one-use receipt caps and isolation, and
physical capacity retained through cancellation until late callback drainage.

The reference-click runner tests require all anchored native phase markers, the
explicit mock-Keychain marker and a clean exit. Fixture HTTP tests verify exact
routes, trusted-event count/title evidence and the bounded slow-handler variant;
none of these unit checks claim real native click execution.

The app verifier also requires `ARX_MCP_CLICK_NATIVE_SMOKE_SUCCESS`; a zero exit with any prior markers cannot hide an omitted bundled-helper activation phase.

Reference-form policy tests compile the production Blink helper with deterministic
control peers and real SHA-256 under ASan/UBSan. They cover original-baseline
checks after property/layout changes, unchanged/no-event behavior, shadow/password
eligibility, exact/ambiguous select values, hidden option styles, reentrant setter
completion and cached-length/tree caps. Overlay tests enforce pinned anchors,
idempotence and fingerprint coverage; isolated syntax checks use real pinned
Blink declarations. Actual event and browser behavior requires owned native
form fixtures against the matching framework.

Form HTTP fixture tests bound run/event admission, reject raw-value or unknown
fields, preserve property-only mutation acknowledgements and test exact owned
routes. Runner tests require every native phase, explicit form mode and clean
shutdown; they do not launch Chromium.

App-smoke validation rejects a run missing the mandatory MCP form marker; reusable reference-form HTTP tests independently bound owned run records and value-free event evidence.

`test_reference_scroll_native` compiles the exact Blink scroll helper under
ASan/UBSan with deterministic layout/authority peers. The shared reference-click
harness also exercises scroll/form physical serialization and late receipts.

`test_pointer_policy_native` compiles the ABI27 pointer payload parser and the
DEV-669 rule that only hover is non-consuming. The reference-click harness's
`pointer` scenario runs the browser's exact keep-or-forget code: a dispatched,
successful hover keeps its snapshot; a failed, uncertain or cancelled hover and
every other kind forget it. It also compiles the ABI28 key chord payload parser.

Scroll fixture tests cover finite report limits, allowed fields, owned run
admission/reuse and profile-file exclusion. Runner tests reject every omitted
native phase, missing mock-Keychain evidence or failed teardown. The compiled
scroll helper traps any extra lifecycle-flushing convenience method and checks
fresh disabled/ARIA/editable state after its one explicit layout update.

App-smoke validation also rejects a missing MCP scroll marker while retaining every earlier wait/click/form requirement. Shared scroll fixture tests bound and validate the exact loopback geometry and boolean reports.

Link-context policy tests run the production token/coordinate admission body under ASan/UBSan and enforce browser-only typed coordinate proof/idempotence. Runner tests require every renderer source/root-coordinate, source-frame/navigation/replacement and private-close phase, exact success/mock-Keychain markers and clean exit, while excluding profile-file routes. These tests do not substitute for `make link-context-smoke` against the rebuilt framework.

Erasure worker-result policy checks distinguish a durable same-request retired tombstone with blocked cleanup from an active rejected request or an undurable ledger. Only the former acknowledges irrevocable retirement; no policy test removes actual user profiles.

Full-document prototype tests compile its actual fixed-capacity recording buffer and resource accounting. They check exact pixel/byte boundaries, negative overflow, integer overflow, aggregate image accounting and sticky rejection before retaining excess bytes. Isolated overlay tests cover repeatability, changed anchors, and refusal of shared or unmarked source trees. This unexposed prototype is not a shipping capture capability; these checks do not validate Blink's earlier paint allocation or real full-document pixels.

Full-document prototype resource tests compile the production admission and incremental PNG-control bodies under ASan/UBSan. Metadata peers prohibit readback and font stream APIs; encoder peers cover write-before-retention limits, row cancellation/timeouts and invalid geometry before encoder creation. These isolated tests and pinned syntax checks do not enable full-document capture or establish pixel/layout preservation.

Document-capture infrastructure tests now cover the staged production build/overlay and explicit owned fixture routes. Actual decoded full-document pixels and unchanged native viewport remain a separate signed-framework gate. Scoped Swift tests cover full-mode callback/cancellation, independent document/image geometry and availability denial.

Gesture ownership tests compile the staged per-Page production policy under
ASan/UBSan for first-update admission, consumed/browser replies, CSS refusal or
absence, foreign pages, stale gestures/epochs, inversion, reversal, vertical and
Escape-equivalent cancellation, boundaries, edge reservation and one-use release.
The exact patched browser event queue and reply block additionally verify that
coalescing preserves the oldest proof, deferred moves retain its owner, foreign
identities cannot coalesce, and the exact reply reads its own CSS before legacy
forwarding moves it. Later tagged CSS may admit an earlier unconsumed update; a
later consumer or containment cancels that ownership. Overlay tests reject changed
anchors and require byte-identical repeated preparation. These tests do not run
Chromium or claim physical trackpad, native focus or scrubber UI acceptance.

`test_profile_retirement_smoke` validates the owned signed runner's oracle without launching an app. It rejects missing native/mock-Keychain evidence, unexpected phases, root-binding/consent changes, recreated original paths, replaced or removed same-boot quarantine inodes, symlinked/private record violations and invalid kernel boot identities. A passing simulated oracle does not establish native acceptance; `make profile-retirement-smoke` must actually run against the matching signed ABI16 app. It also checks the `clearForImport` oracle (DEV-833): every fixture profile retired and acknowledged, none restored to the saved workspace, and no storage moved before restart.

Gesture selection policy tests additionally cover admitted edge promotion,
vertical selection, long-list bounds, reversal and containment after reveal,
stale selection identities and one-use direct-entry release. Runner tests reject
every missing native gesture phase, mixed modes, caller-profile use, diagnostic-
only success text and nonzero exit. Fixture HTTP tests bound query values and
never serve directories or profile files. These tests do not run the signed
native fixture or claim physical trackpad acceptance.
The cooperative recording suite executes patched upstream canvas push/save/restore, display-item retention, chunk creation and subsequence admission prefixes under ASan/UBSan. Denial cannot construct/retain ops, mark/process items, allocate chunks or index a denied subsequence; scope exit restores ordinary recording. Nested record/path/blob/image and expensive flags, deadline, layout count/depth/text limits are adversarial inputs. The owned native fixture adds actual ordinary repaint after budget rejection; these peers do not substitute for that pixel gate.

`test_extension_install` applies the real opt-in CrxInstaller overlay to pinned method fixtures and compiles their prompt/commit/cancel branch under ASan/UBSan. It verifies unchanged ordinary updates, explicit update refusal before mutation, missing-client/preapproved refusal, and exact one-use native package/profile/inventory consent proof. These peers do not establish full Chromium package/runtime acceptance.

`test_sign_in_smoke` covers the leak scan and the runner's driver contract: the store and interface drivers' exact marker lists (the interface run must report pressed controls before success), complete-line marker matching, the app environment selecting the driver without inherited `ARX_` variables, unknown drivers rejected, the `sign-in-interface-smoke` task dispatch, and reading the console lock from `ioreg`. They do not launch the app; the signed smoke must run to show the panel's buttons are reachable through accessibility.

`test_pip_motion.py` compiles `Packages/engine/Native/pip/arx_pip_motion.h` with sanitizers and checks the Picture in Picture window's projection, release velocity, corner positions on one and several screens, pinch scaling and clamping, and its springs, Reduce Motion included (DEV-825); since DEV-852 also that the bounded projection reaches only a neighbouring display, the carried velocity and squeezed bounce keep every settle frame on the target screen for any release velocity and direction, 20,000 pt/s flings toward each edge, side-by-side, stacked and offset display layouts, re-snapping after a display change, and keeping a two-finger drag on a screen. `test_pip_overlay.py` applies the PiP overlay to anchors and to a tree patched before the hunks it replaced (DEV-540's, DEV-825's inset and motion lifetime), checks they're swapped out rather than added beside the new ones, and checks DEV-852's full-screen, time-label and display-link wiring, and that each time label is as tall as its line, with the 16-point hunks put back first in a tree patched before.

Install tests cover `make install` and `make update` without `/Applications`: only the installed copy is asked to quit and only politely, a quit that times out stops before anything changes, the new bundle swaps with the installed one in one rename (and never overwrites an app that appeared meanwhile), failed checks, quits and swaps leave the installed app untouched, `make update` refuses without an installed app, the relaunch decision, and that the build keeps the current build number.

Back/forward cache fixture tests (DEV-943) check that each page counts how often it was served and reports `pageshow` with its token, that nothing it serves sends `Cache-Control` or an unload handler, that its media page plays its video once on a trusted click, pauses it and reports the playback state, reports it again when restored, that its icon is a PNG, that the runner's handler serves only the fixture video besides and records each answer, and that other paths and queries are refused. The runner tests require every phase marker and clean shutdown, the request lines in the log, and the host's own failure line (such as a stored-icon time out with its page, icon and last read) in the runner's error. They do not launch Chromium; `make back-forward-cache-smoke` checks a real restore.

Benchmark tests serve the fixture pages and check timed beacons, read this process's own `proc_pid_rusage` counters, compute CPU and disk deltas across processes that start and exit, and render the results table with skipped browsers. Since DEV-939 they also cover process roles from command lines and costs per role, naming the busy start-page renderer among spare and extension renderers, extensions read from profile preferences (names from manifests and locales), launch signposts parsed from `log stream` output, frozen-page counting from lifecycle beacons (including posted `sendBeacon` requests), same-site fixture hosts, the native driver's reply matching against a stand-in process, the native, freezing and per-process report tables, tab steps whose pages didn't all load, restarting the inventory listing when its cursor goes stale, keeping earlier launch numbers when a warm launch fails, treating a browser that exited as a failed sample rather than an empty one, counting native switches slower than 3 s, and ending the browser's process when the quit request itself fails. They don't launch a browser; `make benchmark` does.

Helium services tests (`test_services_overlay.py`, DEV-930) apply the services overlay twice with the same result, check that no Helium host and no consent or origin pref read is left, that a changed anchor stops the build, and that every anchor matches the pinned source when it's on the Mac. That check, and the startup metrics overlay's (`test_startup_metrics_overlay.py`, DEV-894), skip with both versions named when the prepared tree came from another `engine.lock.json` (`config.prepared_mismatch`, read from `.build/engine/prepared.json`; `test_engine_config.py`). Engine host tests (`test_engine_hosts.py`) scan synthetic framework binaries: a clean framework passes and lists every URL host, Helium hosts fail in URLs and bare, `.pak` resources aren't read, an unlisted Google URL host fails, allowlist entries need a reason and can't allow Helium, and `make engine-build` checks hosts before it marks a build complete.

Performance gate tests (`test_perf_gate.py`, DEV-902) read every metric from a benchmark result and fall back when the windowed step was skipped, treat a failed benchmark as an error, need both thresholds to call a regression, never fail on improvements, fail a metric the release didn't measure but not one without a baseline, require a reason to override and record it, alternate the apps across sessions and take medians, and write `gate.json` and `gate.md` in compare mode.

`test_native_messaging_overlay.py` (DEV-889), `test_extension_uninstall_overlay.py` (DEV-889) and `test_content_blocking_overlay.py` (DEV-884) pin their overlays' anchors; the last also runs uBlock's `arx.js` under Node against a stand-in uBlock when Node is installed. For Hide Element (DEV-1019) it checks that the bridge and `arx.js` agree on the keys, that My filters' element-hiding lines for one named site are listed by site (an internationalized one under its ASCII name) (lines for several sites or with exclusions, scriptlets, exceptions, wildcard and network filters left out), that the picker opens only in the instance with the tab, and that Show waits for a reload already running, takes a line out, reloads the filters and only then lists the site again.

`test_badge_overlay.py` applies the Badging API overlay (DEV-907) to its anchors, checks that applying it again changes nothing, and that both setting and clearing a badge reach `arx::PageBadgeChanged`.

Localization tests (`test_localization`, DEV-1291) check placeholders (a missing, extra or retyped specifier, unnumbered specifiers moved and numbered ones out of the English order), each language's plural categories (Polish, Russian and Ukrainian one, few, many and other; Japanese and Chinese other only; French and Spanish may add many), that an import with any bad entry (unknown key, empty, shouldTranslate false, wrong placeholders or plurals) writes nothing and lists each key, that a good one touches only its entries and languages, keeps the catalog's formatting byte for byte (both `"key": ` and Xcode's `"key" : `) and is idempotent, that export takes missing, needs_review and stale entries (stale against `Localization/sources.json`) and not entries with nothing to translate, that the check fails only shipped languages, requires `CFBundleLocalizations` to match and English copies of untranslated entries (a bundle returns the bare key for a key its language lacks), warns about copies of the English, whitespace and glossary terms, and marks stale translations needs_review. Against the repository, the catalogs render unchanged, the shipped languages pass, and every planned language's glossary keeps Arx's coined names in English and gives an Arx space a word different from macOS Spaces.

String catalog tests (`test_string_catalogs`, DEV-1143) fail when a key appears twice in any tracked `.xcstrings` file. JSON keeps only one of the values, so a duplicate builds and silently loses a string.

Dependency diff tests (`test_dependency_diff`, DEV-1281) build throwaway Git repositories and check that a new, bumped or removed package shows up from every `Package.resolved`, the `Package.swift` manifests (nested parentheses and `path:` packages included) and `THIRD_PARTY_NOTICES.md`, that a moved fork submodule shows, that the working tree compares too, that the comparison starts at the merge base so the target branch's own changes stay out, and that a broken `Package.resolved` is an error.
