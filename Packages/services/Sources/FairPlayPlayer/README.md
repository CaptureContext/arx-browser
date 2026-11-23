# FairPlayPlayer

Arx's FairPlay helper (DEV-1144), the code behind the `ArxFairPlay` helper app (`Sources/ArxFairPlay`), which the app starts from `Contents/Helpers`.

- `FairPlayHelperProcess.run()` is the helper's run loop: an accessory app (no Dock icon, but Now Playing names it), commands as JSON lines on standard input, events as JSON lines on standard output, a position report every 0.5 s. It exits when its input closes, which is how the app ends it, and on a line too long to be the app's.
- `FairPlayHelper` plays one track at a time with one `AVPlayer`. It publishes Now Playing (title, artist, album, https artwork of at most 4 MiB, elapsed time, rate) and sends the media keys and Now Playing's controls (play, pause, toggle, next, previous, seek) back to the page, whose own media session handlers act on them. `ARX_FAIRPLAY_SYSTEM_CONTROLS=0` leaves Now Playing and the media keys alone and `ARX_FAIRPLAY_SILENT=1` mutes it, for unattended runs.
- `FairPlayTrack` is one track: an `AVURLAsset` on the private `arx-fairplay:` scheme whose resource loader serves the page's playlist (the segments come from its https URLs), and an `AVContentKeySession(keySystem: .fairPlayStreaming)` with the asset as recipient. Each key request becomes an SPC (`makeStreamingContentKeyRequestData(forApp:contentIdentifier:)`, the `skd://` URI's host as the content ID) for the page to exchange; the page's CKC answers it within 30 s, or the track fails at `license`.

Keys are streaming keys only; nothing persists. The helper app is sandboxed with outgoing network only; FairPlay Streaming needs no entitlement.
