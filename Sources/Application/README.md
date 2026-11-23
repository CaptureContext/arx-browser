# Application

Thin startup bridge from the macOS executable to AppFeature. The root `arx-browser` package exports this single target as the `Application` library.

## Boundaries

May depend on AppFeature and AppRelocationClient. Must not own browser behavior, UI, or dependency registration.

## Public surface

`Application.run()` first prepares Chromium's allocator with `BrowserApplication.prepareAllocator()`, which must happen while the main thread is the only one: installing dependencies starts dispatch's worker threads, and the allocator then refuses to start. It then installs the relocation prompts' text and runs `AppRelocationLauncher`, which moves Arx to Applications when it's opened from the release disk image or a translocated location (see [AppRelocationClient](../../Packages/services/Sources/AppRelocationClient/README.md)). When Arx was moved, or a copy in Applications is already running, the process quits before the engine starts. Otherwise it starts `BrowserApplication` on the main actor. If the move fails, the launcher sets `RelocationRetry.isOffered`, and AppFeature's Arx menu shows Move to Applications… to try again.

Relocation is compiled out of Debug builds and skipped for test, headless and smoke runs. Set `ARX_SKIP_RELOCATION=1` to skip it in a Release build.

## Testing and previews

`AppRelocationTests` in the services package covers the decisions. The unsigned app build verifies entry wiring.

`ApplicationIntents` includes AppFeature's App Intents package so the app target's `ArxAppIntents` lists Arx's Shortcuts actions (DEV-929).
