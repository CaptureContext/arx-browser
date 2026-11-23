# _Sparkle

Exports [Sparkle 2](https://sparkle-project.org), the updater Arx uses to install new versions from GitHub Releases (DEV-859). Only `AppUpdaterClient` in services imports it; features use that client.

Sparkle ships as a signed binary `Sparkle.xcframework`. Xcode embeds `Sparkle.framework` in `Arx.app/Contents/Frameworks` with its `Autoupdate` tool, `Updater.app` and XPC services, and `make dmg` re-signs them inside out with the rest of the app. Arx isn't sandboxed, so the XPC services aren't used.

Helium's own Sparkle integration stays disabled in the engine build (`enable_sparkle=false`).
