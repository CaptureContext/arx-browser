# BrowserCoreTests

Tests BrowserCore's organization rules with Swift Testing and CustomDump. Fixtures use explicit deterministic IDs. Coverage includes ordered nested folders, profile-wide Favorites, saved/current URL separation, duplicate ownership and cycles, session isolation, serialization, and in-memory edit rollback. No Chromium runtime, UI, or database is required.

`LinkTransformationTests` verifies raw URL preservation, the narrow cleanup allowlist, signed/authentication bypass, IDNA and exact-host matching, proxy template validation, ordering/overrides, and Markdown escaping without network access.
Tab Archive model tests cover older snapshots, grouped order, fresh restoration identities, renamed/deleted spaces, stale close metadata, profile isolation and invalid archive records.

`URLRoutingTests` covers host case/IDN and domain boundaries, ports, encoded path matching, first-match ordering, overrides, deleted destinations, profile defaults and preference compatibility.

`AppLinksTests` covers App Links (DEV-857): scheme, host and path matching and first-match order, default and per-profile handling, private windows that never run scripts, link validation (scheme, control characters, 8 KB), Always allow per site and handler, refused definitions with the rule each breaks, and routing preferences saved before App Links. For the app picker (DEV-862) it checks that rules saved before it decode as System Default and System Default still encodes as before, that chosen apps round-trip, that private windows and a script's fallback open the handler's app, and the scheme rules and the "Catches …" example.

OrganizationMoveTests cover nested cross-space/profile moves, ordered insertion, identity/URL preservation, cycle/unpin rejection and persistence round trips.

AutomaticPiPPreferenceTests cover BrowserPreferences round trips and older saved
settings defaulting to no automatic PiP origins. Existing media preference tests
retain exact-origin/profile and private-source isolation checks.

`OnboardingPreferencesTests` cover older settings decoding as an undismissed introduction with no completed steps, dismissal and step completion persisting independently, and a retired step (`crashReports`) being dropped rather than failing the decode.

`ChromeAppearanceTests` cover the space → profile → global cascade one setting at a time, clamping, clearing overrides to nil, persistence round trips and older files without tints, and `ChromePalette`: the default tint reproduces the shipped stops, neutral is grey at their lightness, and every hue and intensity stays in gamut at the same lightness.

`SplitGroupTests` cover Split View's layout rules (equal shares, the 280 pt minimum, capacity, neighbour-only resizing), group joining up to four open tabs, pruning of closed or moved members, persistence of groups, and four-pane presentations that still read two-pane `proportion` snapshots.

`ContentBlockingSiteTests` (DEV-884) covers which sites have content blocking off, the per-site edit's `holds` and validation, and the content blocking preferences' defaults for older saves.

`SiteSettingsTests` (DEV-716) covers origin and zoom-host normalization, what each permission's sites and defaults take, `holds` for edits that change nothing, sorting, profile-scoped sections, the automation edits and that allowing a site anything but pop-ups always asks.

`BrowsingDataTests` (DEV-647) covers each range's start, counting and removing history by range, counting a profile's finished downloads, and merging engine counts with the app's own.

`ProfileReleaseTests` cover the idle profile release policy (DEV-880): only a loaded profile nothing uses and nothing has used for the whole grace period goes, every kind of use (app, page, download, engine work) keeps one, and the sweep runs four times per grace period, at most once a second.

`TabUnloadingTests` cover tab unloading's eligibility (each app fact that keeps a tab loaded), the delay and its ordering (longest hidden first, a tab without a clock isn't due, `never`), critical memory pressure's grace, and the saved delay's default, round trip and fallback for unknown or missing values (DEV-873).

`KeptLoadedSiteTests` cover DEV-932's sites: reading a typed site or a URL, subdomains and lookalikes, per-profile matching, the sorted list, the organization change and profiles saved before the list existed.

`TabGroupTests` (DEV-911): grouping gathers tabs where the first is (after the group they came from, when taken from its middle), a move plan takes its tabs out of their groups and its undo puts them back, a tab between two members joins and closed members leave, groups round-trip and older workspaces have none, pinning makes a folder, ungrouping keeps the order, and tabs outside the space's open tabs are refused.

`UnreadBadgeTests` (DEV-907): titles' counts and dots, titles that only look like counts, the Badging API's dot, count and clear, and a site's host without "www.".

`UnreadBadgeVisibilityTests` (DEV-1258): all 54 combinations of the tab, site and profile levels (inherit, show or hide) and the browser default resolve to the most specific choice, for the bare resolution and for a tab by its site's host; DEV-907's hidden sites read back as sites set to hide and aren't written again; every level round-trips; a profile chooses or inherits through its organization change; agents read and change the browser default.

`ChromeGradientTests` (DEV-919): a space's gradient wins over its profile's and `.plain` chooses the tint's own, gradients are repaired or refused (falling back to the level above), and appearances saved before gradients still decode.

`OrganizationUndoTests` (DEV-1030): taking a step back on top of the workspace as it is now. A tab moved to another space goes back while tabs opened and names changed since stay; a tab moved again since stays put; a deleted space comes back with its tabs and folders; a closed tab comes back while Recently Closed holds it and is passed over once ⇧⌘T reopened it; a new tab goes unless moved since; a deleted folder comes back with its tabs; a Favorite goes back into its folder; a pinned tab gets back its open state but keeps the page it loaded since; and a step already taken back has nothing left. Codex's cases too: a closed tab with nowhere to go stays in Recently Closed, a profile the step made goes, a space moved to another profile goes back, a new folder moved since stays, a separated split comes back unless its tabs were split again, a tab split again since stays in its newer split, a tab grouped again since stays in the group that took it in, new or not, and a moved pin keeps a saved page changed since. Taking back a space's creation never leaves the workspace without a space, and a saved address goes back while a name given since stays.

`StreamingAppLinkTests` (DEV-1000) covers Spotify player pages mapping to the app's `spotify:<kind>:<id>` links (with `intl-` prefixes and queries), pages that aren't one item opening the app as it is, and other sites having no app.

`InstallDateTests` (DEV-1323): when this Arx was first installed. A recorded date never changes, a new install is today, an existing one takes the earliest of its data folder and profile folder, dates in the future are ignored, the folders are the edition's own, and preferences keep the date while older saves have none.
