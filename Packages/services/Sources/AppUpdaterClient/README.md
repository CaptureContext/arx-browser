# AppUpdaterClient

Updates Arx from GitHub Releases with [Sparkle 2](https://sparkle-project.org) (DEV-859). Settings' Updates section and the Arx menu's Check for Updates… use it as `@Dependency(\.appUpdater)`. It's the only target that imports `_Sparkle`.

## When it runs

`live` builds a `Configuration` from `Info.plist` and the running process, and only reaches Sparkle when `availability` is `.available`. Otherwise it returns `unavailable(reason)`, whose `start()` yields one unavailable status and ends. In order, the reasons are:

- `debugBuild`: a Debug build.
- `automatedRun`: XCTest keys, `ARX_ENGINE_PROFILE`, `--headless`, `--arx-…` options or `ARX_SKIP_UPDATES`.
- `unsigned`: no team identifier in the app's signature, as in unsigned CI builds.
- `missingFeed`: `SUFeedURL` is empty, isn't HTTPS, or still contains `ARX_RELEASES_REPOSITORY`, the placeholder the build settings had before the feeds moved to the Arx repository's releases.
- `missingPublicKey`: `SUPublicEDKey` (the `ARX_UPDATE_PUBLIC_ED_KEY` build setting) is empty.

If Sparkle itself refuses to start, the status is `failedToStart(message)`. Sparkle's own error alert isn't shown at launch.

## Behaviour

- **`start()`:** starts `SPUStandardUpdaterController`'s updater once and streams `Status` whenever `canCheckForUpdates`, `sessionInProgress`, `lastUpdateCheckDate` or either automatic setting changes, and after each update cycle. The settings themselves live in Sparkle's user defaults.
- **`checkForUpdates()`:** Sparkle's user-initiated check with its standard windows, only while `canCheckForUpdates` is true.
- **Automatic checks and downloads:** `setAutomaticallyChecks` and `setAutomaticallyDownloads` set Sparkle's properties. Downloads only change while Sparkle allows automatic updates.
- **No downgrades:** `updater(_:shouldProceedWithUpdate:updateCheck:)` refuses any release whose `sparkle:version` isn't a higher build number than this app's `CFBundleVersion` (`isUpgrade(candidate:current:)`). Sparkle's installer also refuses downgrades.
- **Installing:** updates install when Arx quits. Install and Relaunch doesn't let Sparkle terminate Arx: the delegate postpones the relaunch and the stream yields `quitRequested`, which AppFeature turns into its usual quit, so pages, downloads and the workspace close normally. Sparkle installs once the process has exited; Arx isn't reopened by itself. If a page, download or Keep Open keeps Arx open, AppFeature calls `quitCancelled()`: Sparkle's Ready to Install window, whose button has already been used, is dismissed. Sparkle has no call that ends that session and keeps the staged update, so `canCheck` stays false until Arx quits, and Settings offers Quit and Install, which goes through the same quit. `isReadyToInstall` is set only once Sparkle's installer can finish without Arx (an update scheduled for quit, a postponed relaunch, or one dismissed while installing), and cleared when the update is skipped, dismissed before installing began, or its cycle fails.
- **Engine helpers:** `prepareForTermination()` runs after Chromium has stopped and before `exit`. In a build that updates it always waits, up to 10 seconds, for Arx's child processes that run from inside its bundle (Chromium's helpers) to exit, so Sparkle never replaces the bundle under a running helper. `waitForHelpers(deadline:interval:sleep:running:)` holds the loop for tests.

## Channels and What's New (DEV-888)

- **Channels:** `Channel` is `stable` or `beta`. `Configuration` reads `ArxBetaFeedURL` and `ArxUpdateChannel` too; `offersBeta` is true only for an HTTPS beta feed that isn't the stable one and isn't the placeholder. `Channel.resolve(stored:buildDefault:offersBeta:)` picks the person's choice (user defaults `ArxUpdateChannel`), else the build's own; the first launch stores that channel, so a beta install stays on Beta after the Beta feed brings it a stable build. The live updater hands Sparkle `feed(for: channel)` through `feedURLString(for:)`. `setChannel` stores the choice and calls `resetUpdateCycleAfterShortDelay()`. `Status` carries `channel` and `offersBeta`. Switching back never downgrades, because only higher builds install.
- **What's New:** `didFindValidUpdate` keeps the item's version, build, notes (`releaseNotesText(_:format:)`: Markdown and plain text as they are, HTML without tags) and `fullReleaseNotesURL` in `LaunchRecord`. At the first start of each launch, `LaunchRecord.launch(version:build:)` records the running build and returns `whatsNew(currentVersion:currentBuild:lastLaunchedBuild:pending:)`: nothing for a first install, a relaunch or a downgrade; otherwise the notes if they're for this build, cut by `shortNotes` to `whatsNewNotesLimit`, and the full notes link, or `releaseNotesPage` in the manual. The first stream gets it once as `Event.whatsNew`.

`testValue` is unimplemented. `previewValue` reports a configured updater that checked an hour ago.
