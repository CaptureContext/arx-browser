# LiveFolderFeatureTests

Every suite that uses dependencies, a store or `@Shared` takes `@Suite(.dependencies)` (DEV-970). Without it, every test in the process shares one set of dependency test values, including swift-sharing's storage and `@Shared` references. A test then reads what another left behind, so it passes alone but fails on a repeat or next to another.

DEV-926. `LiveFolderFeature` with a fake `LiveFolderClient` and a test clock: making a folder live fills it without a badge, the timer's refresh badges new pull requests until the folder is opened, a failure keeps the items, a late answer after the source changed or the folder stopped is dropped, removed folders stop, and without an account nothing is fetched.
