# Developing Arx

The reference for working on Arx: tools, Make commands, the engine, signing and the headless mode. [README.md](README.md) has the short version for building from source.

Arx is a Chromium-based browser project for macOS. Its native sidebar and command bar organize isolated profiles, spaces, nested folders, pins and Favorites across multiple windows. Split View, Peek and Little Arx share explicit Chromium session ownership. Local workspace persistence, Tab Archive, profile history, URL routing and scoped local MCP access are composed by the application.

A separate engine package contains the Swift API and independent native bridge for Helium Chromium. Features that require additional native capabilities stay unavailable until their adapter is composed; a feature package or a passing reducer test alone does not establish browser support.

The structure follows the `app-structure` skill: a thin macOS container, a root Swift package, role-based local packages, XcodeGen, and Python automation exposed through Make.

## Develop

Use macOS 27 or later and an Xcode toolchain with Swift 6.4 or later. Select the full Xcode developer directory with `xcode-select`. Install mise, then run from this directory:

```sh
mise trust
make bootstrap
make test-all
make open
```

Python 3.12.12 and XcodeGen 2.45.4 are pinned in `mise.toml`, matching the template. Bootstrap is safe to rerun: it initializes pinned submodules, resolves selected remote dependencies, and generates the workspace. Git must be able to access the recorded fork remotes. Xcode and its SDKs are installed separately. Pull request checks run on GitHub's hosted macOS 27 runner and the engine-backed jobs on self-hosted Macs; see [Public CI](#public-ci). A self-hosted runner must select a Swift 6.4 toolchain.

The `Arx` scheme builds `Arx.app`. `make build-app` produces an unsigned app and prints its resolved location. Run from Xcode for interactive development. The bundle identifier is `dev.capturecontext.arx`, registered as Arx in Apple Developer and App Store Connect. Debug builds are [Arx Dev](#arx-dev), `dev.capturecontext.arx.dev`, which runs beside an installed Arx without touching its data.

For local signing, copy `.env.example` to `.env` and set `DEVELOPMENT_TEAM`, then run `make project`. Mise loads the optional local file for Make commands. Team configuration remains outside version control; a fresh checkout or CI can generate and build unsigned without it. App Store Connect API credentials are not needed for these commands. Project generation selects the team but does not create certificates or provisioning profiles.

## Structure

- [Containers/macOS](Containers/macOS/README.md) owns the entry shim and bundle metadata.
- [Application](Sources/Application/README.md) forwards startup to the feature package.
- [Packages](Packages/README.md) describes engine, extensions, dependencies, core, services, design-system, and features.
- [Forks](Forks/README.md) explains the pinned submodules.
- [Scripts](Scripts/README.md) implements generation, checks, tests, and builds.
- [Previews/AppUI](Previews/AppUI/README.md) exercises sidebar and command-bar components in a standalone macOS app.
- [project.yml](project.yml) and [.xcodegen](.xcodegen/) define the generated project.
- [.github/workflows](.github/workflows) runs the Make gate on GitHub's hosted macOS runner for pull requests and pushes to `main`; see [Public CI](#public-ci).
- [.agents/AGENTS.md](.agents/AGENTS.md) contains project-specific agent guidance, and [.agents/skills](.agents/skills) the project's skills. The root `AGENTS.md` and `CLAUDE.md` only point there, and `.claude/skills` and `.codex/skills` are symlinks to `.agents/skills`.

Generated Xcode projects, workspaces, container Info.plist and entitlements, SwiftPM build state, and build logs are ignored. Edit generator inputs and run `make project`; do not edit generated files as the source of truth. Open `Project.xcworkspace` to see the root package alongside the eight local packages. Arx is licensed under the GNU General Public License, version 3 ([LICENSE](LICENSE)); third-party licences are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

XcodeGen 2.45.4 has no JSON project-output setting. JSON input specifications are supported, but changing the YAML input would not change the generated project format. Keep the pinned generator until a released version supports the desired output format.

## Commands

| Command | Purpose |
| --- | --- |
| `make bootstrap` | Install tools, initialize forks, resolve dependencies, and generate the workspace |
| `make submodules` | Initialize missing fork checkouts at pinned revisions |
| `make resolve` | Resolve the selected package graph |
| `make check-toolchain` | Require Swift 6.4 or later |
| `make project` or `make workspace` | Regenerate both Xcode artifacts |
| `make check` | Validate manifests, target READMEs, plist, and deterministic generation |
| `make test` | Run automation tests and any package-owned Swift tests |
| `make style` | Advisory style warnings from SwiftFormat, SwiftLint and StyleCheck against the swift-style guide; exits 0 unless a tool crashes. See [Packages/tools](Packages/tools/README.md#style-checks) |
| `make build-package` | Compile the app graph and selected infrastructure wrappers |
| `make build-app` | Generate and build the unsigned macOS app, embedding a completed local engine when available |
| `make build-app-runtime` | Build unsigned with a required engine and validate the complete runtime bundle |
| `make build-app-signed` | Build with a stable Apple Development signature |
| `make run` | Build Debug signed as Arx (`dev.capturecontext.arx`) on the installed Arx's data and open it. The installed Arx quits first: one profile folder can't be open twice. See [Run variants](#run-variants) |
| `make run-preview` | Build Debug signed as Arx Preview: Arx's bundle ID, with a data folder, agents' folder and Keychain item of its own. The installed Arx stays open |
| `make run-dev` | Quit a running Arx Dev, build the signed [Arx Dev](#arx-dev) and open it. An installed Arx stays open. `ARX_KEEP_RUNNING=1` leaves the running copies open with any of the three |
| `make install` | Build Release, sign it as `make dmg` does and install it as `/Applications/Arx.app`, quitting and reopening a running Arx. No notarization, disk image or build number bump. `ARGS=--open` opens it afterwards, and `ARGS=--no-timestamp` signs without Apple's timestamp service when it's down. See [Install on this Mac](Scripts/README.md#install-on-this-mac) |
| `make update` | The same as `make install`, but refuses when no Arx is in `/Applications` |
| `make appcast` | Sign a release disk image's Sparkle feed entry and make delta updates and the `Arx.dmg` copy into `build/release/appcast`. Publishes nothing. See [Updates and releases](#updates-and-releases) |
| `make signing-check` | Verify a matching development identity is available |
| `make signing-setup` | Restore existing shared development certificates with Fastlane |
| `make preview` | Build and launch the standalone AppUI preview without Chromium |
| `make build-preview` | Build the AppUI preview |
| `make test-preview` | Build the preview and test its organization-editing commands |
| `make engine-cache` | Package the completed local engine into ignored `.build/engine-archives/`, update the manifest and print the `gh release` command that publishes it |
| `make engine-restore` | Verify and unpack a local engine archive (built here, downloaded, or placed beside the manifest) without compiling Chromium or downloading |
| `make engine-fetch` | Use a verified local archive, or download the manifest's release asset and check its size and SHA-256, then restore it |
| `make engine-validate` | Validate the selected engine's helpers, resources, version links and architectures |
| `make app-smoke` | Build the signed app and verify disposable Chromium sessions, profiles, windows, Split View, Peek, tab moves, local MCP and clean shutdown |
| `make developer-tools-smoke` | Build the signed app and check developer-mode gating, the separate DevTools window, its binding across navigation and cache-bypassing reload, exact binding for a Split View pane, Peek, Little Arx and a private window, a cross-site move to an explicit localhost port, a WebSocket live reload, closing when every renderer is terminated and rebinding to the recovered page, and closing with its page. Console, Network, Sources and Inspect Element stay manual |
| `make local-failure-smoke` | Build the signed app and check that a closed loopback port and an untrusted loopback HTTPS certificate show the local development explanations instead of the generic page failure, and that https:// against a plain-HTTP loopback server offers the http:// page and opens it |
| `make profile-release-smoke` | Build the signed app with four profiles, one shown, and check that launch loads only the shown one, that the others load on first use (a profile setting, a page) and are released after a 4-second grace period unused and destroyed by Chromium, that a released profile loads again with its saved setting and a page's session cookie, and that a profile nothing uses never loads (DEV-880) |
| `make tab-unload-smoke` | Build the signed app and check tab unloading (DEV-873): a hidden loopback tab with a back entry unloads in place, keeps its address, title and history, looks unloaded in the sidebar, loads its page again (fetched anew) when selected, and still goes back |
| `make headless-smoke` | Build the signed app and run `Arx --headless` end to end: open, inspect and capture a loopback page through MCP, kill its renderer, meet HTTP authentication challenges with no window shown, then check shutdown, that a tab opened just before a persistent run stops is there when the profile is reopened, a run without `--timeout` that keeps accepting mutations past a shortened grant window and stops on SIGTERM, stdin EOF, launcher exit and an outer launcher's exit behind a live wrapper without orphaned helpers, the timeout exit, profile locking and usage errors |
| `make agent-evals` | Build the signed app (or `ARGS='--app PATH'`) and have scripted stand-in agents read an article, find a name on it, send a form, compare two tabs and meet a change the run didn't grant, each through MCP in its own `Arx --headless` run; prints calls, estimated tokens per task and per turn, and pass/fail against `Scripts/agent_evals/baseline.json` (DEV-1026); `ARGS='--tools all'` lists every tool instead of the core set (DEV-1021). See [Scripts/README.md](Scripts/README.md#agent-evals) |
| `make little-arx-space-smoke` | Build the signed app and a fixture app that sends two loopback links through LaunchServices, as another app would: one from the desktop Space with Arx's main window, one from the fixture's own full-screen Space. Each must open a new Little Arx on its own Space, the second without switching Spaces or moving the first (DEV-931). Needs a logged-in session with a screen and nobody using the Mac; it isn't part of `make app-smoke` |
| `make component-updates-smoke` | Build the signed app, run it headless on an isolated profile (mock Keychain) with network access, and check that the CRLSet, PKI metadata and certificate error help download within five minutes, that the CRLSet is newer than the engine build, and that no other component is installed or named in an update check (DEV-874) |
| `make sign-in-smoke` | Build the signed app and run the trusted sign-in handoff against a loopback login site with two assistants through the bundled MCP helper: consent, origin/frame swaps, revoked grants, the privacy lock, failed login, revealed password, MFA, user navigation and re-authorization, then scan every reply for the typed secrets |
| `make test-all` | Run checks, tests, package/app builds, and preview tests sequentially |
| `make test-runtime` | Run both signed Chromium smoke checks in a configured interactive macOS session |
| `make open` | Generate and open the workspace |

`CONFIGURATION=Release` selects a release app build. `DESTINATION` overrides the default `platform=macOS`. Build and package-test logs live in `build/logs/`. Commands stop on failures and preserve subprocess exit codes. SwiftPM's manifest sandbox is enabled by default; `SWIFT_DISABLE_SANDBOX=1` is an explicit escape hatch for trusted local manifests inside an incompatible outer sandbox.

`make test` runs at most 8 Swift tests at once (`TEST_PARALLELISM`, passed to Swift Testing as `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`; set that variable yourself to override both). Unbounded, Swift Testing starts every test together, and since most feature tests are `@MainActor` and share one main thread, each test's wall time becomes its wait behind the others: whenever load from an engine build stretches the run past a minute, suites with `.timeLimit(.minutes(1))` fail by the hundred (DEV-970). Run `swift test` by hand with the same variable when timing matters, for example `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=8 swift test --package-path Packages/features`.

IntegrationFeatureTests verifies navigation event ownership, cancellation, typed commands, tab closing, drag destinations and workspace restoration through injected clients. Add tests beside the owning package when introducing behavior; `make test` discovers package test targets. The automation tests cover process failure propagation and workspace membership. AppUIPreview exercises tabs, nested folders, renaming, drag and drop, and command-bar search against in-memory fixtures. `make test-preview` checks the preview's editing transactions. The Arx app composes AppFeature, MainFeature, SidebarFeature, CommandBarFeature, ViewerFeature and ViewerItemFeature. Native pages are owned by ChromiumBrowserEngine, while the engine-free preview imports the same sidebar editing operations. The engine package also has a separate development host.

## Chromium and delivery

The selected engine is Helium Chromium with an independently implemented Arx bridge. [arx-engine](Packages/engine/README.md) owns its Swift API, pinned upstream source versions, native boundary, build commands, and development host. Ardia is an implementation reference only. Engine builds run separately from `make test-all`. On another Apple Silicon Mac, run `make engine-fetch`, which downloads the prebuilt engine named by `Artifacts/Engine/arx-engine-macos-arm64.json` from a GitHub release; see [prebuilt engine](Artifacts/Engine/README.md). Alternatively, run `make engine-build` from source. Then run `make app-smoke` to check the actual app. `make engine-check` checks native bridge compilation, and `make engine-smoke` checks the separate host. Launches default to https://capturecontext.dev; `ARX_ENGINE_URL` and `ARX_ENGINE_PROFILE` override the page and profile.

CI restores and verifies the pinned arm64 engine, runs unsigned validation, and checks runtime packaging without a signing environment ([Public CI](#public-ci)). The signed engine and app smokes (`make test-runtime`) run locally, on a Mac with a signing identity and a logged-in session; see [architecture support](Artifacts/Engine/README.md#ci-and-supported-architectures). Runtime logs are retained under `build/logs/runtime/`. Only the arm64 cache has local runtime validation; Intel remains unvalidated. The current dependency graph uses TCA and the selected utility wrappers; SQLiteData and StructuredQueries are available for future persistence. Developer ID signing and notarization are in place (`make dmg`); updates go through Sparkle and GitHub Releases, described below, and no release has been published yet. Only macOS is configured; there are no Catalyst, mobile, watch, or extension targets.

### Engine updates

The engine follows Helium's macOS releases ([imputnet/helium-macos](https://github.com/imputnet/helium-macos/releases)). Each one pins a Chromium version, including Chromium's security respins.

**Cadence.** Move to each Helium minor release (a new Chromium major, such as 0.21) within a week of its release, and to each security respin (a new Chromium patch version on the same minor, such as 0.21.2 to 0.21.3) within 48 hours. A nightly check opens the bump for you; see [Automated bumps](#automated-bumps).

This is how DEV-886 moved the engine from Chromium 156 to 157. The automation runs the same steps:

1. **Pick the release.** Take the newest helium-macos release for the Chromium you want (`gh release list -R imputnet/helium-macos`). Read its changelog and Helium's for anything that reaches the network, Helium's services or a file an overlay patches.
2. **Bump the lock.** `make engine-bump ARGS='--version <tag>'` does this step. In `Packages/engine/engine.lock.json`, set `helium_macos` to the tag's version and commit, `helium` to the `helium-chromium` submodule commit at that tag (`gh api "repos/imputnet/helium-macos/contents/helium-chromium?ref=<tag>"`) and `chromium` to Helium's `chromium_version.txt`. `abi` changes only with the bridge. Update the pins in `README.md`, `THIRD_PARTY_NOTICES.md` (then `make credits`) and the allocator bootstrap's `source-manifest.json`, after checking its vendored files against the new tree.
3. **Use a fresh tree.** `make engine-prepare` refuses a tree prepared for another lock, so work in a new worktree; its `.build/engine` takes about 20 GB once prepared and 40 GB after a build, and the build stops when less than 40 GiB would stay free (`ENGINE_MIN_FREE_GIB`), so put it on the external drive. `make engine-tools engine-checkout` checks the pins, then `make engine-prepare` downloads Chromium (about 3.5 GB), applies Helium's patches and then Arx's overlays.
4. **Fix the overlays.** `engine-prepare` stops at the first changed anchor; `make engine-overlay-report` then lists every missing anchor at once. Re-anchor each overlay on the new upstream text and keep what it does; where upstream rewrote the code, redo the edit for the new code and say so in the overlay's docstring. Refresh the overlay's test fixtures (upstream excerpts) and run `Scripts/tests`; tests that check anchors against a prepared tree use this checkout's `.build/engine`. Run `make engine-prepare` again until it passes.
5. **Fix the native bridge.** `make engine-check` compiles the bridge and the patched Chromium files; fix `Packages/engine/Native` for upstream API changes until it's clean.
6. **Build and verify.** `make engine-build` (it ends with `make engine-hosts`, which fails on any Helium host), then `make build-app-runtime`, `make test-all`, the engine smokes, `make headless-smoke` and `make component-updates-smoke`. Check by hand that the Dock menu still shows Arx's items: `BrowserDockMenu.swift` replaces `applicationDockMenu:` on Chromium's app delegate. Measure memory with `make benchmark ARGS='--tabs 1,20'` before and after.
7. **Cache.** `make engine-cache`, publish the archive with the `gh release` command it prints, and commit the manifest ([Publish a new engine](Artifacts/Engine/README.md#publish-a-new-engine)).

#### Automated bumps

DEV-955 automates the mechanical part. Two workflows split it by what the machine has to do:

| | `engine-upstream.yml` | `engine-build.yml` |
| --- | --- | --- |
| Runs on | GitHub's hosted Ubuntu runner | GitHub's hosted macOS runner |
| When | nightly at 05:17 UTC once `ARX_ENGINE_BUMPS` is `on`, or by hand | by hand, or when a pull request is labelled `engine-build` |
| Does | steps 1, 2 and a first look at 4 | steps 3 to 7 |
| Takes | a few minutes | hours for a new Chromium; after re-anchoring, about 10 minutes of build plus the checks |

**The nightly check.** `make engine-upstream` asks GitHub for helium-macos's releases and reports one newer than the lock, its kind (a Helium minor release, a security respin, or a Helium-only release on the same Chromium) and the date the cadence above sets. When there is one and no `engine/helium-<version>` branch exists yet, the workflow runs `make engine-bump` on that branch, then `make engine-anchor-check`, and opens a draft pull request with the anchor report, a checklist and Helium's release notes. It never replaces a branch that exists, so re-anchoring commits on it are safe; when an earlier run pushed the branch but couldn't open its pull request, it opens it from the branch as it is. A closed pull request stays closed.

`make engine-anchor-check` runs the real overlays on a sparse copy of the tree: only the files they open (about 200), fetched from Chromium's Gitiles at the locked tag (and from the repositories `DEPS` pins, such as PartitionAlloc), plus the `deps.ini` archives Helium unpacks (uBlock), with Helium's patches and domain substitution applied. It also checks the allocator bootstrap's vendored files. It doesn't simulate Helium's name substitution, translations, version stamp or resource replacement, and names any such file an overlay touches, so `make engine-prepare` stays the authority. It needs no Chromium tree and takes about three minutes.

**The build.** Label the pull request `engine-build`, or run *Engine build* by hand with the branch. The job prepares Helium's tree for the branch's lock, lists every missing anchor if the overlays don't apply, builds the engine, runs `make build-app-runtime test-all` and the checks that need no display (`make engine-smoke headless-smoke component-updates-smoke` by default), then `make engine-cache` and commits the archive to the branch. A rerun after re-anchoring reuses the release's tree and builds incrementally, but `make engine-prepare` never takes out an earlier revision's edits, so it doesn't cache that engine; run *Engine build* by hand with `fresh` to build the final one from a new tree. It benchmarks the new engine against the default branch's (`make benchmark ARGS='--skip-chrome --tabs 1,20'` on both, compared with `make perf-gate ARGS='--compare …'`) and posts a table of the results, the anchor report and the performance gate to the pull request. Re-anchoring, the Dock menu and the display smokes stay with a person; Max reviews and merges.

Only this repository's branches build. `pull_request_target` takes the workflow from the default branch, so a pull request can't change its guards, and both jobs refuse pull requests from forks: their code must never run in a job that can write to the branch. A first job on a GitHub-hosted runner checks that whoever added the label or started the run has write access (adding a label needs only triage) and that the ref is a branch of this repository, not a `refs/pull/…` ref, before the build job starts (DEV-1281).

**Settings, variables and secrets.**

- *Settings › Secrets and variables › Actions › Variables*: set the repository variable `ARX_ENGINE_BUMPS` to `on` to turn on the nightly check. Until it's set, the scheduled run is skipped, so merging the workflow creates no branches or pull requests; running *Engine upstream* by hand always works. Any other value turns it off again.
- *Settings › Actions › General › Workflow permissions*: allow GitHub Actions to create pull requests, so the nightly check can open its draft. The token it uses can't start other workflows, so the bump pull request doesn't trigger CI until someone pushes to it.
- *Settings › Environments*: create `engine-build`. Set its variables `ARX_DEVELOPMENT_TEAM` (the Apple team ID) and `ARX_ENGINE_TREES` (optional: a directory with 150 GB free for the Chromium trees; without it they go beside the checkout), and optionally `ARX_SIGNING_IDENTITY` (the identity's SHA-1). Don't limit its deployment branches to `engine/*`: a label run comes from `pull_request_target`, which GitHub runs on the default branch. A run by hand on the default branch builds but never commits the archive there.
- Create the `engine-build` label.
- One secret, in the `engine-build` environment: `ARX_ENGINE_RELEASES_TOKEN`, a fine-grained token with *Contents: read and write* on `capturecontext/arx-browser-engine` only. The build publishes the engine archive there, and the run's own `GITHUB_TOKEN` can't write to another repository. Everything else in both workflows uses `GITHUB_TOKEN`.

**By hand.** Locally, `make engine-upstream` reports a newer release, `make engine-bump ARGS='--version 0.21.4.1'` moves the pins, and `make engine-anchor-check` checks the overlays on the locked release (`ARGS='--report anchors.md'` keeps the report). Without Xcode (as on the Ubuntu runner), `python3 -m Scripts.engine.automation engine-upstream` and the same names run them, since `Scripts.tasks` imports commands that load macOS libraries. On GitHub, `gh workflow run engine-upstream.yml` runs the nightly check now, and `gh workflow run engine-build.yml -f ref=engine/helium-0.21.4.1` builds a branch (`-f fresh=true` starts from a new tree; `-f benchmark=false`, `-f cache=false` and `-f smokes='…'` change what it runs).

### Feature flags

The engine reads its `ARX_*` feature flags once at launch, from the environment or else from Arx's defaults under the same name (`defaults write dev.capturecontext.arx ARX_IDLE_TRIM -string on`, or `dev.capturecontext.arx.dev` for [Arx Dev](#arx-dev)), and prints each one it applies to stderr. `make benchmark` records the ones set in its environment, so an A/B is one build run twice. These were measured on Chromium 157 on 2026-11-14 (DEV-682). For the beta every feature flag is on by default (DEV-1143), so `ARX_IDLE_TRIM` and `ARX_BOOTSTRAP_BACKGROUND_PAGES` are too, and `off` turns either back; [the engine's native README](Packages/engine/Native/README.md) has the tables:

| Flag | Default | Measured |
|---|---|---|
| `ARX_MEMORY_PURGE_ON_FREEZE` (DEV-942) | unset: off | With 50 tabs after the freeze wait, `on` and `limit` saved nothing beyond noise, since Blink already purges a renderer soon after it goes to the background; `on` also cost about 1 % of a core in renderers. |
| `ARX_SPARE_RENDERER` (DEV-916) | unset: Chromium keeps one spare | `off` saved one 10 to 15 MB renderer but made the first launch about 40 ms and loading ten tabs about 70 ms slower. |
| `ARX_IDLE_TRIM` (DEV-916) | unset: on (DEV-1143) | `on` took about 6 MB off the browser process at 20 and 50 tabs, under 1 % of Arx's memory, with idle CPU unchanged. |

The app reads its own the same way, each listed in BrowserCore's `FeatureFlag` and in Settings › Advanced › Feature Flags, and on by default (DEV-1143). `ARX_SIDEBAR_PRESS_SELECTS` (DEV-914, DEV-994, on) switches tabs as the mouse button goes down on a sidebar tab or Favorite; `off` selects on the click's release instead (DEV-976). A tab pressed and dragged into the page splits with the tab selected before the press. `ARX_INLINE_BUTTONS` (on) draws buttons inside a control or a row, such as the URL bar's Copy Link and Site Settings, with `ChromeInlineButtonStyle`: a shape about the icon's size, black over what's under it, so it's always a darker shade of the field or row; `off` brings back the pale `ChromeButtonStyle` square and the URL bar's former symbols and spacing. `ARX_SETTINGS_TOOLBAR_ADD` (on) puts Settings' New Profile, New Rule, New Route, New Handler and the two Add Site buttons on the window's top bar as a "+" with a hint; `off` brings back the buttons over the lists.

`ARX_SQLITE_WORKSPACE` (DEV-560, on by default since DEV-1143) keeps the workspace in SQLite instead of `arx-workspace.json`, migrated from the file at the first launch (a failed migration leaves the run on the file), and browsing history in `arx-history.sqlite` instead of `History/*.json` (DEV-984); `ARX_SQLITE_WORKSPACE=0` keeps the file. `ARX_ICLOUD_SYNC` (DEV-560, DEV-977, on by default since DEV-1143, needs `ARX_SQLITE_WORKSPACE`) adds iCloud sync and Settings › Arx › iCloud Sync, where the person still turns sync on. `ARX_ICLOUD_SYNC_MERGE` (DEV-1216, on by default) makes a Mac turning sync on with its own workspace merge what matches iCloud's after a preview, before anything uploads, and lets Settings merge synced profiles of the same name. Deletions stay on the Mac that made them (DEV-980), but the rest of ADR 0001's decisions of 15 November isn't built. Smokes that read or write `arx-workspace.json` set `ARX_SQLITE_WORKSPACE=0`. The WorkspaceDatabase and WorkspaceSync READMEs describe them.

Arx's own feature flags read the same way, from the environment or else from defaults. `ARX_LIVE_CALENDAR` (DEV-804, on by default since DEV-1143, like every feature flag) turns on Live Calendar for Google Calendar favorites; the AppFeature README describes it. `ARX_TRANSLATE` (DEV-996, on by default) turns on Translation Available in the URL bar, its popover, Settings › General › Translation (Apple or Google), sentence-level translation and private windows; the AppFeature README describes it. `ARX_SITE_PREVIEW_IMAGES` (DEV-1142, on by default; `0`, `false`, `no` or `off` turns it off) gives Settings › General › Previews a choice for pages that aren't loaded (the site's preview image, load the page, or no picture) and sends the site's preview request the cookies the tab's profile has for the page's own host; off, the two DEV-730 switches return and the request carries no cookies. `ARX_COPY_SUBMENU` (DEV-1162, on by default) puts a tab's, a link's and the Tabs menu's copy and share items in one Copy ▸ submenu with short titles; off, they stay at the top of each menu. `ARX_PAGE_PIP_ADDRESS` (DEV-1124, on by default) lets a click on Page PiP's address edit it in a command bar over it, as the main window's does, opening what's chosen in the floating page; off, the address only shows. `ARX_CAPTURE_BEYOND_VIEWPORT` (DEV-1208, on by default) makes Capture Page's frame show the whole page it took, scaled to fit, and lets Capture Area scroll the page while an area is drawn toward an edge, taking the area beyond the viewport in one image; the PageCaptureFeature README describes it. Off, the frame wraps the viewport and an area stops at its edge. `ARX_PAGE_PIP_SPACES` (DEV-1184, on by default) puts a space picker in Page PiP's header instead of the profile picker (the space's Switch to Space shortcut, ⌃1, ⌃2…, with its name on hover), moves the floating tab to a space from it or with ⌘1–9 while Page PiP is key, and asks before any move to a space of another profile, in Page PiP, Little Arx's Open in and a window's sidebar, saying the page reloads there without its sign-ins; `ARX_EXTENSION_UPDATE_REVIEW` (DEV-1210, on by default) marks a store update the automatic check turned down for asking more permissions, "Update needs review", on its Extensions row, the Settings Extensions entry and the site menu's tile, and opens its review from there; off, Page PiP keeps the profile picker and the questions keep their old words.

## Public CI

Every workflow runs on GitHub's hosted runners; none uses a self-hosted machine. Every third-party action is pinned to a commit with its version in a comment, every workflow sets `permissions:` and `actionlint` passes on all of them (`brew install actionlint`, then `actionlint`).

| Workflow | Runs on | When | Pull request code | Token and secrets |
| --- | --- | --- | --- | --- |
| `checks.yml` | GitHub's hosted `xcode-27` image | pull requests, pushes to `main`, by hand | runs it: `make check`, `make test`, `make engine-fetch engine-validate`, `make build-app-runtime`, then `make style ARGS=--github` (advisory, skipped while it doesn't exist) | read-only, no secrets |
| `engine-build.yml` | a hosted gate, then the hosted `xcode-27` image | by hand, or the `engine-build` label on a pull request from this repository | never from a fork (see [Automated bumps](#automated-bumps)) | writes the branch and comments |
| `release.yml` | the hosted `xcode-27` image | by hand only | never | release secrets in the `release` environment |
| `danger.yml` | hosted Ubuntu | every pull request (`pull_request_target`) | never: the default branch's checkout, Danger and lockfile; the pull request's commits are fetched as data | comments and labels, no secrets |
| `labels.yml` | hosted Ubuntu | pushes to `main` that change `.github/labels.yml`, by hand | never: no pull request trigger | creates and updates labels; never deletes one |
| `record-snapshots.yml` | hosted `xcode-27`, then hosted Ubuntu | a maintainer's `/record-snapshots` comment on a pull request | the first job runs the tests; the second runs none | read-only and no secrets while tests run; the second job commits PNGs only |

**The hosted runner.** GitHub's macOS 27 image is labelled `xcode-27` (`actions/runner-images`, a public preview as of November 2026): arm64, macOS 27, Xcode 27.1 by default (Swift 6.4, as here) with 27.0 and 27.2 installed, and Node; `mise` comes from `jdx/mise-action`. It's free for public repositories. Every job that runs pull request code first refuses to run anywhere but a GitHub-hosted runner, before checkout, in case a self-hosted machine is ever registered with the same label.

**Danger.** Danger JS (`.github/danger`, the `danger` npm package at an exact version with a lockfile, installed with `--ignore-scripts`) since Node is on every runner and the rules are a few file and text checks; Danger Ruby would need Bundler, which the repository no longer uses. The rules warn or leave a message and never fail: dependency changes as a table, labelled `new dependency` (from `python3 -m Scripts.dependency_diff`, which also runs locally, see [Scripts](Scripts/README.md)); changes to `Packages/engine/Native` or `Scripts/engine`, which need an engine build; a change to views or AppUI with no image or video in the description; a user-visible change whose description doesn't mention the manual; pull requests over 1,500 lines or 60 files; and changes to CI or `.agents`. Run it locally with `npm ci --ignore-scripts --prefix .github/danger`, then `.github/danger/node_modules/.bin/danger local --base main --dangerfile .github/danger/dangerfile.js`.

**Snapshots.** `/record-snapshots`, from a maintainer, records reference images with `SNAPSHOT_TESTING_RECORD=failed` and commits the changed PNGs under the test targets' `__Snapshots__` folders to the pull request's branch. Today's design snapshot tests (`Packages/design-system/Tests/AppUITests/*SnapshotTests.swift`) don't compare against stored references: they write PNGs to the folder `ARX_DESIGN_SNAPSHOTS` names, for a person to look at, and are skipped without it. So the command records nothing until tests use `assertSnapshot` from swift-snapshot-testing (1.19.7, already a dependency), which reads `SNAPSHOT_TESTING_RECORD` and keeps references in `__Snapshots__` beside the test file. `/record-snapshots <commit>` records only if the pull request's head is still that commit.

### Setting it up on GitHub

The maintainer does these once, in the repository's settings:

1. **Actions › General.** Under *Fork pull request workflows from outside collaborators*, choose *Require approval for all outside collaborators*, so a person looks at a fork's pull request before `checks.yml` runs its code. (A public repository never sends a fork's `pull_request` run secrets or a write token.) Under *Workflow permissions*, keep *Read repository contents* as the default and allow GitHub Actions to create pull requests (for the nightly engine bump).
2. **No self-hosted runners.** Nothing asks for one. If a machine is ever registered, don't give it the `xcode-27` label: that is the hosted image's label.
3. **Branch rules** (*Rules › Rulesets*, target `main`): require a pull request before merging, with one approval; require the status check `hosted-macos` (the Checks workflow); block force pushes and deletion. Leave Danger out of the required checks, since it is advisory and runs from `pull_request_target`.
4. **Environments.** Keep `release` and `engine-build` with *Required reviewers* (Max) and deployment branches limited to protected branches (`engine-build` excepted, as [Automated bumps](#automated-bumps) explains).
5. **Secrets and variables › Actions.** For `/record-snapshots` on forks, add `ARX_SNAPSHOTS_TOKEN`: a token of a maintainer or bot account that can push to a fork's branch when the author allows edits by maintainers (a classic token with `public_repo`); without it only branches of this repository take the commit.
6. **Labels.** They live in `.github/labels.yml`; the Labels workflow creates and updates them on a push to `main` that changes the file, or run it by hand once after the repository is populated. It includes `new dependency` (Danger also creates it on first use) and `engine-build`.
7. **Discussions.** Turn on Discussions for questions, so issues stay for bugs and plans.
8. **Code security.** Turn on private vulnerability reporting (`SECURITY.md`), Dependabot alerts and secret scanning with push protection.

### Owed on GitHub

Only a run on GitHub proves these: the `xcode-27` image builds Arx with `mise` and Swift 6.4; `make engine-fetch` gets the engine from its release asset there; Danger posts and labels on a fork's pull request; `/record-snapshots` commits to a fork's branch with `ARX_SNAPSHOTS_TOKEN`; the release builds, signs and notarizes there from the `release` environment's secrets; and whether the engine build fits the hosted runner's disk and its six-hour limit. Until that last one is shown, the engine is built locally (`make engine-build`, `make engine-cache`).

## Updates and releases

Arx updates itself with [Sparkle 2](https://sparkle-project.org) from GitHub Releases (DEV-859). Only `AppUpdaterClient` imports Sparkle; Settings › General › Updates and the Arx menu's Check for Updates… use it. Helium's own updater stays off in the engine build (`enable_sparkle=false`).

### Configuration

Four build settings in [.xcodegen/macOS.yml](.xcodegen/macOS.yml) become the app's `Info.plist` keys:

| Build setting | `Info.plist` key | Default |
| --- | --- | --- |
| `ARX_UPDATE_FEED_URL` | `SUFeedURL` | `https://github.com/capturecontext/arx-browser/releases/latest/download/appcast.xml` |
| `ARX_UPDATE_PUBLIC_ED_KEY` | `SUPublicEDKey` | Arx's public update key; empty turns the updater off |
| `ARX_UPDATE_BETA_FEED_URL` | `ArxBetaFeedURL` | `https://github.com/capturecontext/arx-browser/releases/download/beta-feed/appcast-beta.xml` |
| `ARX_UPDATE_CHANNEL` | `ArxUpdateChannel` | `stable`; `make dmg ARGS='--channel beta'` sets `beta` |

The updater only starts in a signed release build whose feed is a real HTTPS URL and whose key isn't empty. Debug builds, unsigned CI builds, test, smoke and headless runs, runs with `ARX_SKIP_UPDATES`, and builds with the placeholder feed or no key leave it off: Settings says updates aren't set up, Check for Updates… stays disabled, and nothing reaches Sparkle. Neither value is secret, so both are committed once they exist.

Both feeds are release assets of the Arx repository, `capturecontext/arx-browser`, which is also `make appcast`'s default `--repository`. The stable feed is `https://github.com/capturecontext/arx-browser/releases/latest/download/appcast.xml`. GitHub redirects `releases/latest/download/<file>` to that asset of the release marked latest, so every release uploads its own `appcast.xml` and the URL never changes. The repository has to stay public: Sparkle downloads the feed, disk image and deltas without credentials, and GitHub only serves release assets anonymously from public repositories.

### Update channels

Settings › General › Updates offers two channels (DEV-888), since the beta feed is a real HTTPS URL other than the stable one:

- **Stable** reads `SUFeedURL`, which lists the newest stable release.
- **Beta** reads `ArxBetaFeedURL`, which lists the newest release of either channel, so Beta gets stable releases too.

A build starts on the channel it was released for (`ArxUpdateChannel`) until the person picks one; the choice is kept in user defaults under `ArxUpdateChannel`. The updater gives Sparkle the chosen feed through `feedURLString(for:)` and resets its update cycle when the channel changes. Switching back to Stable never downgrades: Sparkle and Arx's own check only install a higher build number, so a beta build stays until a stable release passes it. Build numbers only go up, across both channels.

The Beta feed is the `appcast-beta.xml` asset of a fixed prerelease tagged `beta-feed`, replaced on every release of either channel. The Stable feed stays the `appcast.xml` of the release marked latest; beta releases are prereleases and never become latest.

### What's New

`AppUpdaterClient` remembers the release notes of an update Sparkle finds (`didFindValidUpdate`) and the build that last ran. The first launch of a higher build sends `whatsNew` on the updater's stream, and the main window shows a short sheet: the notes for that build, cut at about 1,200 characters, and a Full Release Notes link to the appcast's `sparkle:fullReleaseNotesLink`, by default the manual's [release notes](https://manual.arx.capturecontext.dev/help/release-notes). An update installed from a disk image, without notes, gets the sheet with the link only. A first install, a relaunch and Debug, unsigned or automated runs show nothing.

### The signing key

Sparkle signs every update with an EdDSA (ed25519) key and the app refuses anything the key in `SUPublicEDKey` didn't sign. Create it once, on the Mac that makes releases:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account dev.capturecontext.arx
```

(After `make dmg` the same tools are in `build/ReleaseDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin`.) `generate_keys` keeps the private key in the login keychain, under that account so it stays apart from other apps' keys, and prints the public key; put that in `ARX_UPDATE_PUBLIC_ED_KEY` and commit it. Never commit, print or copy the private key. Back it up with `generate_keys --account dev.capturecontext.arx -x <file>` to somewhere offline and delete the file afterwards; `-f <file>` restores it on another Mac. `make appcast` passes the same account to every Sparkle tool. A lost key means existing installs can't verify updates any more and need a manual download.

### Making a release

Nothing in the repository publishes a release. In order:

1. The feed (`ARX_UPDATE_FEED_URL`) and Arx's public key (`ARX_UPDATE_PUBLIC_ED_KEY`) are set in `.xcodegen/macOS.yml`. The Mac that makes the release needs the matching private key in its login keychain; `make appcast` refuses to sign with any other.
2. Production must have Arx's iCloud schema before anything is published: `make cloudkit-schema ARGS='--compare production'` lists what it lacks. A Release Arx syncs with Production, and CloudKit refuses every save of a record type Production doesn't have (see [iCloud schema](#icloud-schema)). `make dmg`'s signature check prints the same reminder.
3. `make version ARGS=<x.y.z>` to a version no release has used yet, of either channel: a release's tag is its version. Then `make dmg`, or `make dmg ARGS='--channel beta'` for a beta. Each release build gets the next build number; Sparkle compares `CFBundleVersion`, and Arx refuses any update whose build number isn't higher than its own, so data only ever migrates forward. Commit the bumped build number.
4. `make dmg-verify`.
   Then the performance gate (DEV-902): `make perf-gate ARGS='--current build/release/Arx.app --record'` on a quiet Mac, logged in, on power. It compares the release with the committed baseline for this Mac's model, `Scripts/perf-baselines/<model>.json`, and must pass, or be overridden with a reason (`--override "…"`), which the result records. Once it passes, `--record` makes the release that model's baseline; commit the file with the release. See [Scripts/README.md](Scripts/README.md#performance-gate).
5. Write the release notes as a short Markdown file, then `make appcast ARGS='--previous <folder> --channel <stable|beta> --notes <notes.md>'`. `<folder>` holds the disk images of earlier releases of both channels, as downloaded from GitHub (`gh release download <tag> --pattern 'Arx-*.dmg'`); it can be empty for the first release. Only versioned names, `Arx-<version>-<build>-arm64.dmg`, count there: an `Arx.dmg` in the folder is ignored. The notes are embedded in the feed for What's New, which links to `--full-notes-url` (default: the manual's release notes page) for the rest; add the same release to the manual's release notes page. The command checks that the staged `build/release/Arx.app` is the disk image's version and build, reads the feed for this repository and trusts the keychain's key, and that the disk image is signed and stapled (`--allow-unnotarized` skips the staple check for a dry run). It then copies the disk images into `build/release/appcast` and runs `generate_appcast`, which signs the new disk image and makes deltas from up to five earlier builds; with the app at 350 MB and more, a delta is what most people download. The feed lists only the new build, and every URL in it points at this release's tag, which is the version alone, `x.y.z` (for example `0.2.0`), with no `v` and no build number. Two builds of one version can't both be released, so `make appcast` refuses a disk image whose version is already among the `--previous` disk images with another build, and says to bump the version (`make version ARGS=<x.y.z>`, then `make dmg` again). A stable release writes both `appcast.xml` and `appcast-beta.xml`, since it's the newest build of all; a beta writes only `appcast-beta.xml`. The app must be built for the channel and read both feeds of this repository. Then `sign_update --verify` checks the new disk image's signature against the keychain's key. Last, it copies the verified disk image to `Arx.dmg` in the same folder, byte for byte, so the website can link to `https://github.com/capturecontext/arx-browser/releases/latest/download/Arx.dmg`. The copy is made after `generate_appcast` has run, because `generate_appcast` takes every disk image in the folder for an update and would find `Arx.dmg` to be a second archive of the same build. The feed, the deltas and `--previous` use only the versioned name.
6. `make appcast` prints the publishing commands without running them, like:

   ```sh
   gh release create 0.2.0 --repo <owner>/<repo> --title 0.2.0 --notes-file notes.md --latest build/release/appcast/Arx-0.2.0-5-arm64.dmg build/release/Arx-0.2.0-5-arm64.dmg.sha256 build/release/appcast/Arx.dmg build/release/appcast/Arx5-4.delta build/release/appcast/appcast.xml
   gh release upload beta-feed --repo <owner>/<repo> --clobber build/release/appcast/appcast-beta.xml
   ```

   Check the files, then run them. `--latest` matters: the Stable feed URL follows the release marked latest. A beta is created with `--prerelease --latest=false` and only uploads the Beta feed. Releases of both channels carry `Arx.dmg`, but `releases/latest/download/Arx.dmg` follows the release marked latest, which is never a beta: until the first stable release, that link finds nothing. Before the first upload, create the `beta-feed` prerelease with the command `make appcast` prints.
7. Keep the disk image for the next release's `--previous` folder.

### iCloud schema

iCloud sync (DEV-560) keeps its records in the container `iCloud.dev.capturecontext.arx`. Arx Dev uses its Development environment and a Release Arx its Production one. CloudKit creates record types on its own only in Development, for an app that saves into it; Production has exactly what someone deployed, and a deployed record type or field can never be removed. SQLiteData 1.13 drops most refused saves (`invalidArguments`, `serverRejectedRequest`, `limitExceeded`…) without telling Arx. On 18 November 2026 a Release Arx turned sync on against an empty Production: every save failed while Settings showed sync as on, and the refusals ended in data loss (DEV-1207).

- [CloudKit/arx.ckdb](CloudKit/arx.ckdb) is the schema the code needs, as `cktool export-schema` writes it: a record type per synced table, each column an encrypted field (TEXT as STRING, INTEGER as INT64, REAL as DOUBLE) with its own `sqlitedata_icloud_userModificationTime_<column>` field, and the record's `sqlitedata_icloud_userModificationTime`. WorkspaceSync's `CloudKitSchemaTests` fails when a synced table or column isn't in it.
- `make cloudkit-schema` writes it again from the current migrations, keeping what it had, since CloudKit never removes a deployed field. Commit it with the migration.
- `make cloudkit-schema ARGS='--compare development'` or `--compare production` exports that environment's schema with `cktool` and lists the record types and fields it lacks. It needs `DEVELOPMENT_TEAM` in `.env` and a CloudKit management token saved once with `xcrun cktool save-token` (CloudKit Console › Settings › Tokens). Nothing in the repository writes to CloudKit.
- Getting a new schema to Production: import it into Development (`xcrun cktool import-schema --team-id $DEVELOPMENT_TEAM --container-id iCloud.dev.capturecontext.arx --environment development --file CloudKit/arx.ckdb`), run Arx Dev against Development with every category on and check that every save succeeds, check that `cktool export-schema` shows no fields CloudKit added on its own, then deploy from the CloudKit Console (Deploy Schema Changes). The deploy is permanent.
- When iCloud refuses a category's rows anyway, Settings › iCloud Sync shows that category as failing, with how many items iCloud refused (DEV-1209). At each start WorkspaceSync queues again every row iCloud never saved (`ServerConfirmation`); when a send ends and some of those still aren't saved, iCloud refused them.

### Installing

Updates install when Arx quits. With automatic downloads on, Sparkle downloads an update in the background and installs it at the next quit. Install and Relaunch in Sparkle's window doesn't let Sparkle terminate Arx: it quits through Arx's own quit path, so pages, downloads and the workspace close as they always do, and Sparkle installs once the process has exited; Arx doesn't reopen by itself. If a page, a download or Keep Open cancels that quit, Sparkle's window closes and Settings offers Quit and Install; the update installs at the next quit either way. Before exiting, a build that updates waits up to ten seconds for Chromium's helper processes to exit, so Sparkle never replaces the bundle while a helper still runs from it.

`make dmg` signs Sparkle's framework like the rest of the app, inside out with the hardened runtime: `Autoupdate`, `Updater.app` and the two XPC services, then the framework. The Downloader service keeps its own entitlements, as Sparkle's signing guide asks. Arx isn't sandboxed, so Sparkle doesn't use its XPC services. `make dmg-verify` checks those parts like every other.

## Crash reports and Report a Problem

`DiagnosticsClient` (DEV-887) keeps every crash of Arx and its engine helpers on the Mac and never sends anything. Problems are reported as GitHub issues on the Arx repository, filed by the person with their own GitHub account:

- **Where crashes come from.** In a release build Chromium forwards the browser process's crashes to macOS, which writes `~/Library/Logs/DiagnosticReports/Arx-*.ips`. Helper crashes (renderer, GPU, network…) aren't forwarded: Chromium's Crashpad writes them as minidumps in `~/Library/Application Support/dev.capturecontext.arx/Crashpad`. The engine has no crash server, so Chromium uploads nothing.
- **What's kept.** At launch, when Settings › Privacy opens and when Report a Problem opens, Arx reduces new reports to a `CrashReport`: process, versions, exception type, the crashed thread's frames as module and offset, and module UUIDs. No URL, title, page content, memory, path or Mac identifier. They're kept in `…/dev.capturecontext.arx/Diagnostics/Crash Reports` for 30 days, at most 50. The raw files are never moved or changed. Settings › Privacy shows how many are kept and removes them. Symbolicate frames with the release's dSYM archive (`build/release/dSYMs`) for the Arx executable, and the engine's symbols for `Arx Framework`.
- **Report a Problem.** Help › Report a Problem… and Settings › Privacy open a sheet with a description, the versions filled in on the issue (Arx, Helium and Chromium, macOS, architecture) and Include diagnostics (the Mac's model and memory, and the last 7 days of crash reports). Open Issue on GitHub opens `https://github.com/capturecontext/arx-browser/issues/new` in a new tab with the issue form [.github/ISSUE_TEMPLATE/problem-report.yml](.github/ISSUE_TEMPLATE/problem-report.yml) prefilled through query parameters: the description, the versions and, with Include diagnostics on, the name of the report file. That file is saved first in `…/dev.capturecontext.arx/Diagnostics/Problem Reports` (the newest 10 are kept) and selected in Finder, so the person can drag it into the issue. The address never carries diagnostics, crash reports, paths, web addresses or page content; a description too long for an address is cut there, and the file is saved and selected even with Include diagnostics off, so the whole text can be attached. Save Report… writes the same JSON wherever the person picks. Keep the form's field ids in step with `GitHubIssue.Field`; `GitHubIssueTests` checks them. Filing issues needs the repository to be public, or the person to have access to it; until then GitHub answers with a page that can't be found, so the sheet stays after the tab opens and names the saved file and its folder (Show in Finder), or offers Save Report… when there's no file, for sending the report another way.
- **Headless.** Headless runs don't collect crash reports, and Report a Problem is only in the Help menu and Settings, which headless runs don't show.

## Developer mode

Settings → Developer turns on developer mode. The preference is app-wide: it applies to every profile and window, and is saved with the other browser preferences. Reload Ignoring Cache (⌥⌘R, revalidates only the current page) and Clear Cache and Reload (⇧⌘R, also clears the profile's HTTP cache) are always available. Developer mode adds:

- **Developer Tools** (⌥⌘I, View menu, command bar, configurable in Settings → Shortcuts) for the focused page of the key window, Split View pane, Peek or Little Arx.
- **Inspect Element** in the page context menu, on links and on other page content.

Chromium DevTools opens in its own window, one per inspected page; docking is not supported. Each inspector is created in the page's own browsing context (ordinary or private) and attached to that page's DevTools target, so it follows navigation, reloads and renderer recovery of the same page and never rebinds to another tab. Closing the page closes its inspector; ⌘W in an inspector closes only the inspector. Turning developer mode off removes the commands but leaves open inspectors attached until they or their pages close. Links that DevTools tries to open in a new tab are ignored, and there is no remote debugging port.

Local development servers work at addresses such as `localhost:3000` and `127.0.0.1:8080`, including WebSocket live reload. Developer mode never disables certificate validation, same-origin protections or Chromium's sandbox; use http on localhost or trust a development certificate in Keychain Access. 
With developer mode on, Settings → Extensions also offers **Load Unpacked…**, which loads an extension folder (the folder that contains `manifest.json`) into the selected profile only, and **Reload** for an extension loaded that way after you edit its files. Chromium's own unpacked loader reads the folder, so a missing folder, an unreadable folder and an invalid manifest each show their own message with Chromium's reason. Management policy still applies, as in Chrome, and an unpacked folder gets its declared permissions without an install prompt. Remove works as for any other extension. Loading turns on Chromium's developer mode for that profile, so unpacked extensions keep running there. Turning Arx's developer mode off hides Load Unpacked and Reload, but loaded extensions stay installed and enabled until you remove them.
## Headless runs

`Arx.app/Contents/MacOS/Arx --headless` starts the Chromium runtime for scripts, agents and CI without showing browser windows, a Dock icon or a menu bar. It composes the same AppFeature, local MCP endpoint and capture service as an interactive run, hosted in a transparent, click-through window sized so the page viewport is exactly `--viewport` points.

```sh
Arx.app/Contents/MacOS/Arx --headless --allow read,screenshots,content,manage --viewport 1280x800
```

| Option | Meaning |
| --- | --- |
| `--allow` | Comma-separated grants for the run's own MCP client: `read` (required), `screenshots`, `content`, `interaction`, `manage`. Default `read`. The client is scoped to the run's whole profile: every space, including spaces that appear while the run lasts, with their folders and tabs, and its Favorites. `manage` pre-approves mutations for the whole run, or until `--timeout` when one is given. Unlike the 15-minute temporary grant of interactive Arx, it applies only to the run's own client, only while the run lasts, and is revoked at stop. |
| `--profile <absolute path>` | Use and keep a persistent profile. Default: a fresh mode-0700 profile in a private run directory that is deleted at exit. |
| `--viewport <W>x<H>` | Page viewport in points, 320×240 to 3840×2160. Default 1280×800. Capture pixels are the viewport times the run's `deviceScale` (see below). |
| `--timeout <seconds>` | Optional run deadline, 10 to 86400, for example in CI. The run then exits `75` at the deadline and its grants end with it. Default: none; the run lasts until it is stopped. |
| `--mcp-configuration <absolute path>` | Where to write the MCP client configuration. It must not exist; it is created with mode 0600. Default: `mcp.json` in the run directory. |
| `--url <url>` | Initial page for a new profile: http(s) or `about:blank` (default). |

Stdout carries only protocol events, one JSON object per line: `ready` (with `configuration`, `profile`, `viewport`, `deviceScale`, `grants`, `grantsExpireAt`, `timeoutSeconds`, `pid`; `grantsExpireAt` is the ISO 8601 `--timeout` deadline and `timeoutSeconds` its length, both `null` for a run without one), `stopping` (`reason`: `signal`, `timeout`, `failure`, `parentExited`, `launcherExited` or `inputClosed`), `error` (`code`, `message`, `exitCode`), `diagnostic` (`code`; `shutdownSlow` also has `seconds`; `startupSlow`, sent at most twice, 30 and 90 seconds after launch while the run isn't `ready`, has `phase` (`engine`, `window` or `automation`) and `seconds`), `rendererFailed` (`tabID`), `authenticationRequired` (`tabID`), `userActionRequired` (`tabID`, `prompts`: `webAuthentication` and/or `federatedSignIn`) and finally `stopped` (`exitCode`, `suppressedDialogs`). Chromium and Arx diagnostics go to stderr, including `ARX_HEADLESS_PHASE <phase> <ms>` for each startup phase. Start an MCP client with the `mcpServers.arx` entry of the configuration file; it launches the bundled `ArxMCP` helper with the run's one-time credential. Stop the run with SIGTERM or SIGINT; it revokes its client, writes the workspace and history changes still waiting to be saved (for up to 5 seconds), closes every page and exits after Chromium's helper processes stop. Every other stop (timeout, launcher exit, stdin EOF, failure) saves the same way. Every run that reports `stopping` ends with `stopped`: a shutdown still running after 10 seconds reports `diagnostic` `shutdownSlow`, and one that does not finish within 60 seconds of Chromium's teardown (75 seconds of `stopping` at most) reports `error` `shutdownHung` and `stopped` with exit code `2` before the process is forced to exit.

Without `--timeout`, a run also stops the same way, exiting `0`, when its launcher goes away:

- **Parent exit.** The process that started Arx is watched with kqueue `NOTE_EXIT`, and its exit stops the run (`parentExited`). This covers a launcher that crashes or is killed without closing anything. A run whose parent is launchd, for example one started with `open`, has no launcher to watch.
- **Launcher chain exit.** A wrapper chain such as `npx` → `node` → Arx keeps the direct parent alive after the outer launcher exits. Arx therefore also watches the leaders of the process group and session it started in, when they are neither Arx nor its parent, and stops when either exits (`launcherExited`). An outer launcher that runs in its own process group or session, as an agent's spawned command usually does, is covered; one that shares a long-lived shell's group is not, so keep a stdin pipe open in that case. A run started with `setsid`, which leads its own group and session, watches only its parent.
- **Stdin EOF.** When stdin is a pipe or socket at startup, its end-of-file stops the run (`inputClosed`). Anything read from it is ignored. A terminal, a file or `/dev/null` is never watched, so `</dev/null` keeps a run alive until it is signalled or its parent exits. Agent launchers that spawn Arx with a stdin pipe, such as Node's default `child_process.spawn` or Python's `subprocess.PIPE`, should keep that pipe open for as long as the run should last.

Exit codes: `0` stopped on request, `64` invalid options, `69` engine or MCP endpoint unavailable, `70` startup failure, `73` profile in use or not creatable, `75` the `--timeout` deadline was reached, `2` shutdown hung and was forced to exit.

An unattended run never waits for a person. A mutation outside the run's grant fails with `userActionRequired`. A longer-than-15-minute grant is honoured only for the run's own client while the session is unattended; if a crashed persistent run leaves one behind, interactive Arx revokes it when it opens the profile and asks again. Page `alert`/`confirm`/`prompt` dialogs are suppressed with Chromium's default reply and before-unload keeps the page, so a close reports refusal. Permission requests get Chromium's default denial because consent hosting is off, and file choosers are cancelled. A site's notification never posts to Notification Center, even in a persistent profile that allowed it, and nothing waits for a click (DEV-885). HTTP authentication never shows a prompt or sends credentials: every challenge is cancelled before any prompt is built. A main-frame challenge commits the server's 401 or 407 body; a subframe or subresource challenge lets the page finish loading without credentials. Either way stdout gets one `authenticationRequired` event with the MCP tab ID for that document, and `browser_wait`, `browser_inspect`, `browser_capture` and reference actions on the page fail with `userActionRequired` until it navigates to a new document. Interactive Arx still shows its normal login prompt. A page's full-screen request (`requestFullscreen()`, a video's full-screen button) is refused at once, so its promise rejects with `TypeError`, and a site's Document Picture in Picture (Google Meet's call window) is refused as in private pages; Page in Picture in Picture has no MCP route and never opens. Casting is off (DEV-927): the engine starts without Chrome's Media Router, so nothing is searched for on the network (no mDNS, SSDP or Local Network prompt), no Cast picker opens, and a site's Cast button (`PresentationRequest.start()`) rejects at once with `NotFoundError` while `getAvailability()` reports nothing found. `make headless-smoke` clicks a full-screen button and a Cast button and checks bothe requests fails with no window. A modal WebAuthn request (`navigator.credentials.get` or `create` with `publicKey`) is cancelled before its dialog is built, so the page gets `NotAllowedError`, and a FedCM request that would show an account chooser fails; stdout gets one `userActionRequired` event naming the prompts for that document, and the same operations fail with `userActionRequired`. Conditional (autofill) WebAuthn requests show no dialog and stay pending. A WebUSB, WebHID, Web Serial or Web Bluetooth request is cancelled at once, since nobody can choose a device, so the page's promise rejects with `NotFoundError` (DEV-905). Protected media never offers WebKit: every page stays in Chromium (DEV-877). Battery Saver still follows Settings and Low Power Mode (DEV-915). Page translation runs only from a command or the site menu, or for a profile's Always translate languages; nothing in it waits for a person (DEV-904). The run's client has no sign-in grant, and any other client of a persistent profile gets `userActionRequired` from `browser_sign_in` because nobody can approve the handoff. A persistent profile that still holds an interactive sign-in privacy lock emits `diagnostic` `authenticationProtected` before `ready`, and every request is refused until a person ends the lock in interactive Arx. Disposable profiles use Chromium's mock Keychain, so no Keychain prompt can appear; a persistent profile uses the login Keychain to keep its cookies readable.

Background tabs keep Chromium's tab freezing: a loaded tab outside the five most recently shown or opened stops its timers and scripts until it's shown (`selectTab` puts it in the run's window) or loads again; Chromium also thaws it for a few seconds each minute. Reads, captures, scripts and `browser_wait` don't wake it, the inventory has no frozen state, and the `arx-browser` skill and the tool descriptions tell agents to select a tab before waiting for it to change. The run's windows fetch no missing site icon from its site (nobody sees their rows); pages' own icons and stored icons still show, and MCP reads no icons.

When a page's renderer dies, stdout gets one `rendererFailed` event with the MCP tab ID, inventory reports the tab `failed`, and `browser_wait` returns `stoppedWithError` with `errorCode` `-10000`. The run keeps going; a `reload` command recovers the page and rearms the event.

A persistent profile is locked for the run. A second headless run on it, or a profile whose Chromium `SingletonLock` belongs to a live Arx process, is rejected with `profileInUse` before Chromium starts. Do not start interactive Arx on a profile while a headless run uses it. A stale client named "Arx headless run" left by a crashed run is revoked at the next start.

Headless Arx writes no capture files. `browser_capture` returns PNG data to the MCP client, which owns any file write; the only file Arx writes outside the profile is the 0600 client configuration at the path above.

macOS hosts Chromium's compositor through WindowServer, so a headless run needs a logged-in graphical session for the same user; it does not run from a plain SSH or launchd daemon context without one. Unattended CI therefore needs a runner that is logged in to a GUI session, like the existing runtime smoke runner. `make headless-smoke` validates the actual Chromium hosting and rendering path in such a session.

What's supported: a run started inside the user's logged-in session, with or without a display (a Terminal, a LaunchAgent in the `Aqua` session, or `launchctl asuser` into it). What isn't yet: a plain SSH login with nobody logged in at the console, a launchd daemon, and the login window before anyone has logged in (DEV-869). Arx checks this first, before it locks the profile or starts Chromium (DEV-596): it asks the window server for its session with `CGSessionCopyCurrentDictionary`, which is nil outside a GUI session, and requires a completed login. Without one, the run prints `error` `startupFailed` with a message that names this section and exits with 70 at once, leaving no profile lock or Chromium helper behind. Stderr has `ARX_HEADLESS_SESSION windowServer=… loginDone=… console=…` either way. An SSH login while the same user is logged in at the console can still reach the window server, so it isn't refused, as before. Why this check and not others: [.agents/research/headless-login-session-detection.md](.agents/research/headless-login-session-detection.md).

A display is optional (DEV-865); the logged-in session is not. The host goes on the main screen, physical or virtual, at its origin, and pages render at that screen's backing scale. With no screen at all, the host goes off-screen and pages render at a fixed scale of 2. Either way the scale is chosen once at startup (`HeadlessDisplay`), passed to the engine as `ARX_UNATTENDED_DEVICE_SCALE` and forced with Chromium's `--force-device-scale-factor`, and reported as `deviceScale` in `ready`, so capture sizes don't change when a Screen Sharing display comes or goes during a run. Without it, Chromium would build its display from a nil `NSScreen` (scale 0, clamped to 0.5). Results on a Mac mini (Mac16,10) with no monitor, on 2026-11-14: with nobody connected over Screen Sharing, macOS still reports one unnamed 1920×1080 screen at 1×, and `make headless-smoke` passed with 1024×640 captures at `deviceScale` 1. While Max is connected over Screen Sharing the only screen is a 3840×2160 virtual display; a run then takes that display's scale for its whole length. Not yet checked: the smoke during a Screen Sharing session, and a MacBook with its lid closed and no external display. The no-screen fallback is covered by `HeadlessDisplayTests`.

## Keychain Safe Storage

The "Arx Storage Key" item in the login keychain holds the key to every saved password and cookie in Arx. [Arx Dev](#arx-dev) has its own, "Arx Dev Storage Key" (account "Arx Dev"). Arx never replaces it silently (DEV-900): a missing item becomes a new key only while no profile holds saved passwords, cookies or autofill data, and a key Arx can't read is explained in an alert with Try Again and Quit Arx (plus Start Over for a missing item). A headless run prints `ARX_SAFE_STORAGE_UNAVAILABLE <OSStatus>` on stderr and exits with 70, its startup failure status, instead. Smokes use Chromium's mock Keychain, so none of this is covered by automated runs. Test it by hand before a release that touches `safe_storage_*`, `keychain_*` or `os_crypt`:

Use a separate macOS user account or a VM, never your own login keychain. Install a signed Release build (`make install`), save a password on a test site, stay signed in to another, and quit Arx. Before each step, note the item's Date Modified in Keychain Access; it must not change in steps 1 to 4.

1. **Locked keychain.** Run `security lock-keychain ~/Library/Keychains/login.keychain-db` and open Arx. Cancel macOS's unlock prompt. Arx shows "Arx can't open its key in the Keychain" and says the keychain is locked; no window opens. Unlock it with `security unlock-keychain ~/Library/Keychains/login.keychain-db`, click Try Again: Arx opens, the saved password fills and the other site is still signed in. Repeat and click Quit Arx: Arx quits; opening it again after unlocking works.
2. **Denied prompt.** In Keychain Access, open the item's Access Control, remove Arx from the allowed apps and save. Open Arx and click Deny on macOS's prompt. The alert says macOS didn't let Arx use its key. Click Try Again, then Always Allow: Arx opens with its data.
3. **Changed login password.** From an administrator account, reset the test user's password in System Settings › Users & Groups (this leaves the login keychain on the old password), then log in as the test user and open Arx. The alert appears. In Keychain Access, unlock the login keychain with the old password (or use Edit › Change Password for Keychain "login"), click Try Again: Arx opens with its data.
4. **Missing item.** In Keychain Access, rename the item's Name and Where to `Arx Storage Key (moved)`. Open Arx: the alert says the item is missing and offers Start Over…. Try Again keeps failing; rename the item back and click Try Again: Arx opens with its data. Move it away again, choose Start Over…, then Cancel: the same alert returns. Choose Start Over… and confirm: Arx opens, the saved password no longer fills, the other site is signed out, and installed extensions and developer mode are unchanged.
5. **First launch.** Delete the item and `~/Library/Application Support/dev.capturecontext.arx`, open Arx: no alert, and a new item appears.
6. **Headless.** With the keychain locked, run `/Applications/Arx.app/Contents/MacOS/Arx --headless --profile <a profile with saved data> --timeout 30`: no alert, stderr has `ARX_SAFE_STORAGE_UNAVAILABLE -25308`, and the exit status is 70.

## Arx Dev

Debug builds are Arx Dev (DEV-1013): `make run-dev`, every smoke, `make cloudkit-probe` and Xcode's Run. Release builds (`make install`, `make dmg`, and `make benchmark` by default) are the installed Arx. The two run side by side without touching each other's data, sign-ins or Keychain items. `ArxEdition` (BrowserCore) tells the app which one it is.

| | Arx | Arx Dev |
|---|---|---|
| Bundle identifier and defaults domain | `dev.capturecontext.arx` | `dev.capturecontext.arx.dev` |
| Name and icon | Arx, `AppIcon.icon` and the Settings › Appearance icon | Arx Dev, the blue `AppIcon-Dev.icon`, always |
| Profiles, Chromium's data (Crashpad, native messaging hosts) and Arx's crash reports | `~/Library/Application Support/dev.capturecontext.arx` | `~/Library/Application Support/dev.capturecontext.arx.dev` |
| Built-in agents' files | `~/Library/Application Support/Arx` | `~/Library/Application Support/Arx Dev` |
| Safe Storage Keychain item | "Arx Storage Key", account "Arx" | "Arx Dev Storage Key", account "Arx Dev" |
| Updates | Sparkle | none: no feed, and Debug never starts Sparkle |
| iCloud | `iCloud.dev.capturecontext.arx`, Production with Developer ID | the same container, Development |

Chromium takes its folder from the app's `CrProductDirName` and the engine names the Keychain item from `ArxStorageKeyService` and `ArxStorageKeyAccount`, all in Info.plist, so one engine serves both. An engine built before DEV-1013 still uses "Arx Storage Key" in Arx Dev. The MCP socket is per profile folder, so it differs too.

**Signing.** Arx Dev has its own App ID and needs its own development profile, "match Development dev.capturecontext.arx.dev macos". Until that exists, `make run-dev` and the smokes print a notice and sign Arx Dev without a profile and without iCloud and push, and `ARX_ICLOUD_SYNC` does nothing in it. `make cloudkit-probe` needs the profile and stops without it. Setting it up, once, in the Apple Developer portal:

1. Register the App ID `dev.capturecontext.arx.dev` ("Arx Dev"), with iCloud (CloudKit, container `iCloud.dev.capturecontext.arx`, the same as Arx's) and Push Notifications.
2. Run `mise exec -- fastlane mac signing_profiles force:true`. It makes the profile in Match beside Arx's.
3. On every Mac, run `make signing-setup`, then `make signing-check`, which names Arx Dev's profile.

### Run variants

Three Make targets build Debug, signed, into `build/DerivedData`, and open it. Each replaces the others' bundle there, so a run quits any copy running from that folder first.

| | `make run` | `make run-preview` | `make run-dev` |
|---|---|---|---|
| Bundle identifier | `dev.capturecontext.arx` | `dev.capturecontext.arx` | `dev.capturecontext.arx.dev` |
| Name and icon | Arx | Arx Preview, Arx's icon | Arx Dev, the blue icon |
| Data folder (`ArxDataFolder`, Chromium's `CrProductDirName`) | `dev.capturecontext.arx`: the installed Arx's profiles, sign-ins and passwords | `dev.capturecontext.arx.preview` | `dev.capturecontext.arx.dev` |
| Agents' folder and Keychain item | Arx, "Arx Storage Key" | Arx Preview, "Arx Preview Storage Key" | Arx Dev, "Arx Dev Storage Key" |
| Quits first | every Arx, the installed one too | copies in `build/DerivedData` | every Arx Dev |
| Provisioning profile and iCloud | Arx's development profile, Development container | the same | Arx Dev's, once it exists |

`make run` and `make run-preview` pass their own `ARX_BUNDLE_ID`, `ARX_DISPLAY_NAME`, `ARX_APP_ICON`, `ARX_DATA_FOLDER`, `ARX_SUPPORT_NAME` and `ARX_STORAGE_KEY_*` to `xcodebuild` (`build_app.RUN_VARIANTS`), and `.xcodegen/macOS.yml` builds every other configuration from the same settings with their usual values. Debug code runs on real data with `make run`: back up `~/Library/Application Support/dev.capturecontext.arx` before trying anything that writes the workspace or syncs. Arx Preview shares the installed Arx's defaults domain, since that follows the bundle identifier: feature flags set with `defaults write dev.capturecontext.arx` apply to both.

**Not separate yet.** The `arx` command in `~/.local/bin` and the `arx` MCP server entry in agents' settings are shared: whichever app installed or set them up last wins. Both apps also register `http`, `https` and `arx` links and the sidebar drag types, so macOS picks one of them for an `arx://` link. Crash reports in `~/Library/Logs/DiagnosticReports` don't say which app they came from, so either app's Report a Problem may list the other's.

**Earlier Debug data.** Debug builds before DEV-1013 used Arx's folder and Keychain item. To carry that data into Arx Dev, quit both apps, copy `~/Library/Application Support/dev.capturecontext.arx` to `…/dev.capturecontext.arx.dev`, and copy the key into Arx Dev's item; otherwise saved passwords can't be read and sites sign you out:

```bash
security add-generic-password -s "Arx Dev Storage Key" -a "Arx Dev" -w "$(security find-generic-password -s 'Arx Storage Key' -a Arx -w)"
```

macOS asks once whether Arx Dev may use the new item; choose Always Allow.

## Dependency validation

SwiftPM commands use a project-local fingerprint store under `build/swift-security`. The published swift-associated-objects 0.3.0 tag points to a verified revision `86f01ad9b76ee4a7ec208d4dd9ddbcfe248ff9e5`; the host's shared fingerprint store had an older value for that tag. Its records are left untouched. `Package.resolved` pins the resolved graph.

The remote resource generator compiles without a fallback fork. Its snippets/catalog dependencies and FoundationExtensions' Resettable dependency are transitive only. The copied SwiftSyntax and MacroToolkit revisions compile with Swift 6.4 without changes.

The local overrides currently produce SwiftPM package-identity diagnostics for remote requirements that share the fork identities. Compiler warnings from upstream packages are retained in logs; the package build does not promote upstream warnings to errors.

## Local signing

Use `make run`, `make run-preview` or `make run-dev` for interactive development ([Run variants](#run-variants)). Signed builds and smoke tests use a valid Apple Development certificate for `DEVELOPMENT_TEAM`; missing credentials fail instead of silently falling back to ad-hoc signing. `ARX_SIGNING_IDENTITY` optionally pins a certificate SHA-1. The default selects the valid team certificate with the latest expiration. Chromium and its nested helpers receive the same identity. Keychain can ask once when moving from the old ad-hoc app to the signed app, but its code requirement then remains stable across rebuilds.

`make build-app` and CI remain unsigned. Unsigned Arx builds explicitly place products under `build/UnsignedDerivedData/Build/Products/<configuration>` and intermediates under `build/UnsignedDerivedData/Build/Intermediates.noindex`, overriding Xcode’s custom output-location preferences. Signed and preview builds retain their existing output settings and `build/DerivedData`. Build commands query Xcode with the same configuration and output overrides used to build, then print the resolved application path; `make run`, `make preview`, and app smoke use that path.

**Member number sign-in** (the identity card's member number, DEV-701 and DEV-1313). Apple signs in on the web, in a private Little Arx window (DEV-1323), so it works the same in every build, signed or not, and with Arx as the default browser. The native Sign in with Apple sheet isn't used: its entitlement is for App Store apps, and Arx ships with Developer ID. `.env` names the client, and a build without it offers no sign-in. Google's sign-in was removed (DEV-1323).

- `ARX_APPLE_SERVICES_ID`: the Services ID `dev.capturecontext.arx.auth`, grouped with the primary App ID `dev.capturecontext.arx`, with the domain `api.arxbrowser.net` and the return URL `https://api.arxbrowser.net/v1/apple/callback`. Apple posts its answer to that callback on Arx's server (`arx-browser-backend`), which hands it to the app; the backend's `APPLE_AUDIENCES` lists the Services ID.

It isn't a secret. `.xcodegen/macOS.yml` writes it into Info.plist as `ArxAppleServicesID`; run `make project` after changing it. With `ARX_BACKEND_URL` pointing at a local `pnpm dev`, Apple's sign-in can't finish: Apple returns only to a registered HTTPS domain, never to localhost. [MemberNumberClient](Packages/services/Sources/MemberNumberClient/README.md) describes the flow.

On another Mac, install the pinned tools, Fastlane included, with `mise install`, configure the ignored `.env` from `.env.example`, and run `make signing-setup`. The [Fastlane lane](fastlane/README.md) restores existing shared development certificates read-only. It does not create or revoke certificates, register devices, provision distribution, or upload builds. Existing local certificates can be used immediately without accessing the signing repository.

`make test-mcp` validates the bundled local assistant helper with two independent MCP SDK clients. It requires Python 3.10+ (`MCP_PYTHON`) for the test fixture only. The app ships a native Swift helper and starts with MCP disabled.
