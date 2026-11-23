# ExtensionsFeatureTests

Every suite that uses dependencies, a store or `@Shared` takes `@Suite(.dependencies)` (DEV-970). Without it, every test in the process shares one set of dependency test values, including swift-sharing's storage and `@Shared` references. A test then reads what another left behind, so it passes alone but fails on a repeat or next to another.

Host Swift Testing and TCA tests for ExtensionsFeature and its SettingsFeature composition. Deterministic clients exercise ordinary-profile loading, authoritative mutation completion, exact removal confirmation, permission escalation, profile switching/deletion, cancellation and stale callback rejection. No real Chromium framework, extension installation or user profile is used. Native extension behavior has its separate packaged fixture gate.

Options tests bind actions to the displayed profile, inventory and revision,
refuse stale/disabled/unavailable/dismissed actions, and require refreshed
authority after completion. NativeContentsPresentationTests separately prove
that an adopted options session opens in a Little Arx on a space of its
authorized ordinary profile (DEV-1185), outside the workspace, without replacing
an existing viewer or leaving a window for a rejected offer.

Signed-package consent cases cover explicit picker intake, one-use verified prompt approval, declined permission escalation, stale picker/profile completion rejection and dismissal cleanup. Native package signature verification and physical cleanup are exercised by the separate owned engine fixture, not inferred from reducer tests.

Developer folder cases cover the developer-mode and capability gate, a folder result bound to its exact inventory and consumed once, rejection after a profile change, each actionable folder failure, reload through a revision-checked request and turning developer mode off without touching inventory. Real folder reading is exercised by `extension-settings-smoke`.

The private-window switch tests (DEV-889) check that `setAllowedInPrivate` sends only the action a row allows and nothing for an engine without the switch.

Icon tests (DEV-824 follow-up) check that each load reads its icon paths again, so a changed icon at the same path shows, keeps a letter for an icon that can't be read and forgets the icons of extensions it no longer lists. `ExtensionsViewSnapshotTests` writes the list with icons and a letter fallback, light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
