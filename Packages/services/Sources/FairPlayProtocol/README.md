# FairPlayProtocol

The messages of FairPlay in Chromium tabs (DEV-1144), shared by the app's `FairPlayBridge` and the helper's `FairPlayPlayer`.

- `FairPlayPageMessage` and `FairPlayPageEvent`: what the bridge script in a FairPlay site's page sends the app, and what the app sends it, as JSON text through the engine's page media bridge.
- `FairPlayHelperCommand` and `FairPlayHelperEvent`: what the app and Arx's FairPlay helper app say to each other, one JSON object per line over the helper's standard input and output (`FairPlayLineBuffer`).
- One wire shape for all four: `op` names a command, `event` an event, bytes are base64. Decoding checks every range and size (`FairPlayLimits`) and reads a malformed, oversized or unknown message as nil, which every side drops.
- `FairPlayTrace`: the steps of a page's playback the bridge script reports (`op: trace`), such as which key system the page asked for, whether its playlist reached an element with Arx's keys, and the `encrypted` event. Only these names cross; anything else reads as nil.
- `FairPlayLog`: the diagnostics log of the app and the helper, subsystem `dev.capturecontext.arx`, category `FairPlay`. It logs each step a track takes or misses (bridge on or off and why, the page's traces, the helper's launch, key request, licence, readiness and errors with their domain and code, the fallback) and never a URL, title or key.
- `FairPlayPlaylist.isAcceptable` admits only an `#EXTM3U` playlist of at most 2 MiB whose resources are https and whose key URIs are https or `skd://`, so a page can't point the helper at a local file or another scheme. `hasFairPlayKey` requires an `skd://` key.

No platform frameworks: Foundation only.
