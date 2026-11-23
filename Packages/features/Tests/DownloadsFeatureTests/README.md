# DownloadsFeatureTests

Every suite that uses dependencies, a store or `@Shared` takes `@Suite(.dependencies)` (DEV-970). Without it, every test in the process shares one set of dependency test values, including swift-sharing's storage and `@Shared` references. A test then reads what another left behind, so it passes alone but fails on a repeat or next to another.

Reducer tests cover profile/private filtering, picking profiles in the filter pane and removing them from the header (DEV-770), progress and terminal events, explicit cancellation, unsafe or hidden actions, file-open failures, and observation cancellation without cancelling background transfers.

`DownloadSoundTests` cover the outcome watch's sounds (DEV-1256) with a recording `SoundFeedbackClient`: a finished download plays `done`, private ones too, and one first seen finished does when it started since watching began; a failed one plays `couldNot`; cancelling, and Chromium's user-cancelled and shutdown interruptions, are silent; history and transfers over before watching began are silent; progress and pausing are silent and several finishing in one snapshot ask once; a resumed download that fails, then finishes, sounds each time.

`DownloadStatusTests` covers a row's status line: an interrupted download Resume continues, such as one a quit stopped, says so without Chromium's reason (DEV-1152); one that can't keeps the reason, and paused and blocked ones keep theirs.

`DownloadsHeaderSnapshotTests` writes the panel header with no filter, two filters, the filter pane open and a narrow panel whose chips wrap, in light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
