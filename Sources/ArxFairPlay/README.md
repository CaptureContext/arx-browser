# ArxFairPlay

Arx's FairPlay helper app (DEV-1144), embedded at `Contents/Helpers/ArxFairPlay.app`. It plays the protected audio of a Chromium tab on a FairPlay site (Spotify's web player) with AVFoundation, and owns Now Playing and the media keys while it plays. The app starts it on first use and speaks to it over its standard input and output; closing its input ends it.

This target is the thin container: everything lives in `Packages/services/Sources/FairPlayPlayer`, and the app side in `FairPlayBridge`. The XcodeGen target (`.xcodegen/macOS.yml`) is an `LSUIElement` application, sandboxed with outgoing network only (`Distribution/Entitlements/fairplay-helper.plist`, which `Scripts/release.py` signs it with too), signed with the app's identity and hardened runtime. FairPlay Streaming needs no entitlement.
