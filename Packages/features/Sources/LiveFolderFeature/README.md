# LiveFolderFeature

Live folders (DEV-926): pinned folders that fill themselves from a source, refresh every 15 minutes while `ui(.task)` runs, and badge new items until the folder is opened.

- `ui(.makeLive(folder, source))` makes a folder live and refreshes it at once; a different source starts over. `ui(.stopLive)` and `foldersChanged` (the folders that still exist) stop it and cancel its fetch. `ui(.refresh)` refreshes one folder; a folder already refreshing isn't asked twice.
- Each refresh goes through `LiveFolderClient` and lands in `event(.fetched)`, which applies BrowserCore's `LiveFolderContents.refreshed(with:at:)`: the first fill has no badge, later new items are unseen, items that leave take their badge with them. A failure keeps the items and records the `LiveFolderFailure`. An answer for a folder that stopped or changed source is dropped.
- `ui(.opened)` clears a folder's badge; `State.badgeCount(for:)` reads it.

It isn't composed into the sidebar yet, and sources aren't saved with the workspace: both wait, with how a user signs in to GitHub, for Max's decisions on DEV-926. `LiveFolderClient.liveValue` has no account, so until then every refresh reports `notSignedIn` and sends nothing.

Tests: `LiveFolderFeatureTests`.
Headless runs need nothing from it: a refresh is a network request with no UI, and the feature isn't composed into any run yet.
