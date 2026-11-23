# HistoryDatabase

Browsing history in SQLite through SQLiteData (ADR 0001, section 2 and decision 5, DEV-984): `arx-history.sqlite` beside the workspace databases, one file for every profile. `BrowserHistoryClient` uses it only while the `ARX_SQLITE_WORKSPACE` feature flag is on; otherwise each profile keeps its JSON file in `History/`.

- **Local history:** `historyEntry` (one row per page with its visit and typed counts and latest space for command bar ranking (DEV-1015), the same 2,000-page limit per profile as the JSON store), `historyProfile` (each profile's write revision, and whether its entries came from its JSON file), `historyRemoval` (what Delete from History and Clear History took here, so a visit they cover doesn't come back) and `historySyncState` (the sync window while History sync is on, when the mirror was last pruned). None of these ever sync.
- **Synced tables** (the History `SyncEngine`'s, in the `history` zone): `historyVisit` mirrors the visits of the sync window, one record per profile and page (`visitID(profileID:url:)`, the same on every Mac, so the later visit wins; its title is stored with the visit time in `titledVisit`, because the library merges columns one by one and only stamps changed values, so a separate title column could end up with another Mac's earlier title); `historyClear` is a clear made on one Mac (profile, up to `before`, from `after`, one site or one page), which every Mac applies to its own history. They follow the synced tables' rules: UUID primary keys, no foreign key, no other unique index, nullable or `NOT NULL ON CONFLICT REPLACE` columns. Replace with the Account's Data sets `mirrorsFrom` in `historySyncState`: visits from before it are never mirrored, so the new account doesn't get this Mac's earlier history (local history stays).

The mirror is separate from local history, so deleting a mirror row, by pruning here or by another Mac, never removes a page from this Mac's history. While History sync is on (`setMirrorWindow`), every local write mirrors its changed entries from the window, in the same transaction, and a clear or removal writes `historyClear` and deletes the mirror rows it covers. Turning it on mirrors every profile's entries from the window; turning it off leaves the mirror and iCloud's copy as they are. Mirror rows older than the window are pruned at most hourly, and removal rules and clears after 400 days, longer than any window.

Times are seconds since the reference date, so a date reads back exactly. Never edit a registered migration, and never drop or rename a synced column. Tests use temporary directories only.

## Clears and the mirror after a fetch (DEV-1091, DEV-1088)

- A clear ends at its own time, so browsing after it is never covered. A visit dated later than that (a clock that ran fast) is cleared as itself: one page clear from and up to its own time, for each such visit here or in the mirror.
- No sync window is shorter than `minimumWindowDays` (7): a shorter one is used as 7. After a fetch, a missing mirror row of a visit from the last `restorableAge` (6 days) that no clear or removal covers is put back, since no Mac prunes that recent a row: only a clear sent late, which didn't cover the newer visit, can have taken it. Older missing rows stay gone.

## Merged profiles (DEV-1216)

`moveRemovals(_:from:to:)` moves a merged profile's removal rules to the profile it merged into; `BrowserHistoryClient.moveProfile` merges its entries. The mirror and clears stay: they belong to the other Macs too.
