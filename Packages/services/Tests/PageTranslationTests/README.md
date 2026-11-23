# PageTranslationTests

Covers `PageTranslationScripts`: the pieces and translations each script carries, batches that fit the engine's source limit and a piece too large to send, and `PageTranslationClient.baseLanguage`. The scripts themselves run in a page only in the app.

`PageTranslationSegmentsTests` (DEV-996) covers sentences with their runs: Apple's attributed text marking each run and skipping kept ones, translated words going back to their runs and the runs taking the translation's order (`arrange`), or keeping theirs, Google's HTML markers and entities both ways, Google's answers with and without the detected language, requests without cookies and under the character limit, and the segment scripts and their batches.
