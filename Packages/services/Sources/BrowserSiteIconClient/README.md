# BrowserSiteIconClient

Presentation-only site icons keyed by ordinary profile and page URL, with a per-profile cache that survives relaunches.

## Boundaries

Depends on BrowserCore and dependency support. It owns no renderer or network loader. Images are bounded PNGs supplied by the Chromium adapter; with no live or stored icon, rows draw a placeholder. `configureProfiles` synchronously revokes removed profile membership. A private profile is never included in the ordinary allowlist.

## Public surface

`BrowserSiteIconClient` supplies per-key image streams and synchronous profile configuration. `icons` is for a view showing the icon on screen: a missing one may be fetched from its site. `cachedIcons` gives the same stream to a view mounted off screen and never fetches; a view showing the key later fetches it. When the last `icons` stream of a key ends while `cachedIcons` streams of it remain, a fetch under way stops and a database read takes its place, as when the command bar's scoped search for a bang ends while its row is still listed (DEV-1311). `neverFetching` answers `icons` with `cachedIcons`, for a headless run's windows (DEV-940 follow-up). `BrowserSiteIconKey` uses the saved destination, not a tab's current restoration URL. Changing or undoing a saved URL selects another key; cross-profile moves query the destination profile independently. Chromium's profile favicon database answers live lookups; decoded or encoded images are not written to the organization or Undo history.

`BrowserSiteIconStore` (DEV-809) is the app's own soft cache, so a tab whose page isn't loaded (restored after a relaunch, or unloaded) still shows its icon. It keeps one binary property list per profile, `<directory>/<profile UUID>.plist`, mapping page URLs to the last PNG the page showed. A live icon always replaces the stored one, and a missing or failed live read never erases it. It holds at most 512 entries / 4 MiB per profile, evicting the least recently used; writes change the loaded profile in place and keep a running byte total, so only a write that crosses the budget searches for the oldest entry, and accepts only http(s) pages and PNGs up to 64 KiB. Writes are coalesced for half a second and run on a serial queue with atomic replacement. `seed(_:for:)` (DEV-897) stores an icon another browser showed for a page that has none, and never replaces one; the client's `seed` stores imported icons this way after an import and shows them to observers while Chromium has none. `retain(_:in:)` drops pages no tab points at, `remove(_:)` deletes a removed profile's file, and `removeProfiles` on the client forwards to it. Profiles are sandboxes: no entry is read across profiles, and private profiles never reach it because Chromium refuses their lookups.

## Testing

Cache isolation, eviction, cancellation and late replies are tested by ChromiumBrowserEngineTests; the store's persistence, profile isolation, pruning and bounds by BrowserSiteIconTests. Native callback bounds and private denial belong to ChromiumEngineTests; the owned runtime fixture is the native acceptance gate.
