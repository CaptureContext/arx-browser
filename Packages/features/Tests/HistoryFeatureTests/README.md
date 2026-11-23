# HistoryFeatureTests

Every suite that uses dependencies, a store or `@Shared` takes `@Suite(.dependencies)` (DEV-970). Without it, every test in the process shares one set of dependency test values, including swift-sharing's storage and `@Shared` references. A test then reads what another left behind, so it passes alone but fails on a repeat or next to another.

Reducer tests for the Library's History page (DEV-817): grouping by day in a fixed calendar, search, opening an entry, and deleting an entry, a day and a site, with confirmation and cancellation.

`HistoryPanelSnapshotTests` writes PNGs of the page with history, searching, empty and with no matches, in light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory. It uses fixture entries only.
