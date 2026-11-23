# AppRelocationClient

Moves Arx into Applications when it's opened from the release disk image or from a translocated location (a path under `/AppTranslocation/`), then relaunches it from there. `Application.run()` calls it before `BrowserApplication.main()`, because the engine locks its profile folders once it's running.

## Behaviour

- **From a disk image:** moves without asking.
- **Translocated from anywhere else,** such as Downloads: asks "Move Arx to Applications?" with Not Now and a Don't ask again checkbox, remembered in `UserDefaults` (`AppRelocation.suppressPrompt`). After the move, the copy it was opened from goes to the Trash.
- **Translocated but already in `/Applications` or `~/Applications`** (a quarantined copy put there without Finder): stays where it is.
- **Destination:** `/Applications`. When it isn't writable, macOS's own administrator prompt appears; when that's declined, `~/Applications` is used.
- **An existing copy:** if it's running, it's brought to the front and this copy quits without replacing anything. Otherwise the old copy goes to the Trash, never deleted, and the new one is copied in with `ditto`, keeping the code signature and stapled ticket. The quarantine flag is cleared on the copy so it isn't translocated again.
- **Afterwards:** a detached shell waits for this process to exit, ejects the disk image and opens the copy in Applications.
- **On failure:** Arx keeps running from where it is, explains briefly, and shows Move to Applications… in the Arx menu to try again (`RelocationRetry` in AppFeature).

## Skipping it

Relocation never runs in Debug builds, test runs (XCTest environment keys), headless runs (`--headless`), smoke fixtures (`ARX_ENGINE_PROFILE` or `--arx-…` options), or when `ARX_SKIP_RELOCATION` is set to any value.

## Structure

`relocate(askFirst:)` holds every decision on top of the client's closures, so `AppRelocationTests` covers each case with doubles. `live` implements them with `hdiutil info`, `SecTranslocateCreateOriginalPathForURL`, `NSRunningApplication`, `FileManager.trashItem`, `ditto`, and `do shell script … with administrator privileges` for the authorization prompt. Prompts use `CFUserNotification` because no `NSApplication` may exist before Chromium's `BrowserCrApplication`.

The prompts' text is `Texts` (DEV-1291): services have no string catalog, so `Application.run()` installs `live(texts: .localized)`, AppFeature's text from AppUI's `relocation.*` keys, with `prepareDependencies` before the launcher runs (after Chromium's allocator is prepared, since installing dependencies starts threads). `live` alone uses `Texts.untranslated`, the same English.
