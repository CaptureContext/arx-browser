# BrowserWorkspaceClientTests

Every suite that uses dependencies, a store or `@Shared` takes `@Suite(.dependencies)` (DEV-970). Without it, every test in the process shares one set of dependency test values, including swift-sharing's storage and `@Shared` references. A test then reads what another left behind, so it passes alone but fails on a repeat or next to another.

Tests for the in-memory workspace document and its shared preference keys. Every test writes to its own temporary directory, never the user's home folder.
