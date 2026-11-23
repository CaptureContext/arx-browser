# MediaFeatureTests

Every suite that uses dependencies, a store or `@Shared` takes `@Suite(.dependencies)` (DEV-970). Without it, every test in the process shares one set of dependency test values, including swift-sharing's storage and `@Shared` references. A test then reads what another left behind, so it passes alone but fails on a repeat or next to another.

Exercises capability-disabled behavior, authoritative snapshots, one-window validation, source generations and revisions, profile/private isolation, automatic opt-in, stale operation completion, observation teardown and Return-to-Tab dispatch. DEV-1213: a tab left while its video's Picture in Picture folds back onto the page, during the return's exit or just after it, floats it once a snapshot shows it inline, and a video floating on its own is owed nothing when its tab leaves. These tests use injected media effects and do not establish native PiP, playback, protected-content or accessibility behavior.

Native activation tests exercise stream subscription/cancellation and reject old observation epochs, replaced generations and other-profile identities before Return-to-Tab routing.

`theSidebarPlayersBarSeeks` (DEV-906): the sidebar player's bar seeks to a time only when the page offers seeking.
