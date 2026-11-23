# BrowserWorkspaceClient

Owns versioned, validated browser-organization snapshots. Versions 1–3 migrate in memory to version 4; the file changes only after a successful save. Version 2 adds a monotonic revision. Version 3 records the original Chromium Default directory’s owner independently of profile ordering. Version 4 stores Tab Archive with live organization in one atomic snapshot, preventing older builds from silently dropping archive records. Removing the original profile retains its storage identity; a surviving profile never inherits its cookies or credentials. Unknown versions are never downgraded.

Saves serialize under a lock, reject unexpected on-disk changes, preserve the previous validated snapshot in `.backup`, then atomically replace the primary. A backup-write failure prevents primary replacement. Corrupt primary files can recover from a valid backup; the original is preserved before saving recovered edits. Export never acknowledges a primary save.

AppFeature retains unsaved edits, clears them only for the matching successful save, and offers retry/export with explicit discard on quit. A corrupt workspace without a usable backup fails startup without overwriting either file. Credentials and live page sessions remain in Chromium's profile storage.

## SQLite workspace (feature flag)

`ARX_SQLITE_WORKSPACE=1` (environment, then user defaults) selects `Storage.sqlite`: the workspace lives in `WorkspaceDatabase` beside the file (ADR 0001, phase 1, DEV-560). The first load migrates the file, through the same recovery path, into the database in one transaction; later loads and saves use only the database, writing just the rows that changed. The file and its backup are never written, renamed or replaced while this is a flag, so turning it off returns to the workspace as it was at migration. A database that can't open or migrate leaves the run on the file. Off, the client behaves exactly as before.

With `ARX_ICLOUD_SYNC` as well (`separatePreferencesConnection`), the store writes preference rows through the preferences file's own connection, which the Preferences sync engine watches, and `workspaceDatabase` hands its connections to `WorkspaceSync`. `reloadDatabase()` reads the store again after sync changed it, and validates before the store takes the read rows as its diff base; AppFeature calls it through `WorkspaceDocument.reloadDatabase()` only when no edit is waiting to be saved. Don't turn `ARX_ICLOUD_SYNC` on for anyone yet: deletions stay local now (DEV-980), but the rest of ADR 0001's decisions isn't built.

Failures (`BrowserWorkspaceClient.Failure`, `BrowserProfileRetirementStore.Failure`) are structured and carry no user-facing text; AppFeature maps them to localized messages.

## Shared preferences

`WorkspaceDocument` is the one in-memory copy of the file for the whole run. The app builds it at launch from `loadWithRecovery()` and installs it with `prepareDependencies` before any state exists. AppFeature mirrors the organization into it after every change. `WorkspacePreferenceKey` is a `SharedKey` for one preference domain: `@Shared(.workspacePreference(\.routing))` reads and edits that slice of the document, and readers of other domains aren't notified. Named domain keys are declared in `WorkspacePreferenceKey.swift`. `.installDate` (DEV-1323) is `BrowserPreferences.installedAt`, when this Arx was first installed on this Mac, which AppFeature records once at launch; `InstallDateEvidence` is the dependency that reads the creation dates of the edition's data folder and its profile folder for an install from before then.

`.iCloudRemoval` (DEV-1336) is an in-memory `ICloudRemoval` that AppFeature keeps from iCloud sync's status: whether removing a synced profile or space asks "Delete from This Mac Only" or "Remove from iCloud", and the profiles and spaces another Mac removed from iCloud (`DeletionMark`, with the day "sync deletions after" removes it here, if it will). Windows and Settings read it; `BrowserOrganization.itemsCovered(by:)` names what a Keep covers. `keepRemovalOnThisMac(_:)` passes through to the store.

Keys never write the file. Edits that request saving yield on `changes()`, and AppFeature saves on its own coalesced schedule, so tickets, the backup and the quit flush stay in one place. `$shared.save()` writes at once through `flush()`. Write validated domains only from reducers after validation: an invalid value makes every later save fail. Automation preferences aren't a key; AppFeature owns them.

Requires macOS 27 and Swift 6.4. Verify with `make test-all`.

Appearance and local search preferences share the snapshot and save-recovery flow. Older snapshots without preferences restore defaults. Both decoded and outgoing preferences are validated; failed preference saves remain pending in AppFeature.

Proxy Link rules use the same validated preferences snapshot and backup recovery. Older preferences decode to an empty rules list; no proxy provider presets are implicitly enabled.

`BrowserProfileRetirementStore` owns the private `.arx-installation-v1` identity and `.arx-profile-retirement-intents-v1` consent record under the actual physical Chromium root. These files are separate from exportable workspace preferences and backups. Initialization is exclusive, owner-only and fsyncs the file and root directory; the identity binds the canonical POSIX path, volume UUID, inode and permanent legacy profile owner. Version 1 stored `st_dev`, which macOS renumbers across reboots; it migrates to version 2 when path, inode and owner still match. Native independently validates its installation/root binding. Existing native journals cannot be adopted by generating another UUID. Intent updates preserve the original request and revision, atomically publish a fresh attempt revision before dispatch, and permanently retain acknowledgments. Root replacement, malformed records and failed writes preserve prior consent.

The application persists an explicit legacy profile mapping before opt-in startup. If initial identity setup fails before any native ledger or consent exists, ordinary retain-data browsing remains available with cleanup unavailable. Unknown or unreadable existing retirement history requires recovery because admitting those profile IDs could reopen retired storage.
