# AppUpdaterTests

Covers `AppUpdaterClient.Configuration`: which builds may update (Debug, automated, unsigned, a missing, placeholder or non-HTTPS feed, a missing key), which launches count as automated, the no-downgrade build-number comparison, and the helper wait's deadline. Sparkle itself, the signature check and the process listing need the signed app and aren't exercised here.

`UpdateChannelTests` (DEV-888) covers each channel's feed, builds without a beta feed, the `ArxBetaFeedURL` and `ArxUpdateChannel` keys, the chosen channel winning over the build's own, no downgrade when switching back, and What's New: shown once for the first launch of a higher build, never for a first install, relaunch or downgrade, notes only for the matching build, long notes cut at a line break, HTML notes made plain, and the launch record keeping notes for a build not yet installed.
