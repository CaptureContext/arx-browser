# AppLinkClient

Carries out a page's link for another app once Air Traffic Control has decided how (DEV-857). App Links prompts reach it as `@Dependency(\.appLinks)`.

## Behaviour

- **`runScript`** runs a handler's script as `/bin/zsh -c <script> arx-link <link>`. The link is `$1` (and `arx-link` is `$0`), and it's also in `ARX_LINK`. It is never spliced into the script's text, so a page can't add commands unless the script itself `eval`s the link. The environment adds `ARX_LINK_SCHEME`, `ARX_PROFILE_ID`, `ARX_PROFILE_NAME` and `ARX_SOURCE_ORIGIN` (the page's origin, never its full URL) to Arx's own. The script is started with `posix_spawn`: standard input is `/dev/null`, the working directory is the home folder, no other descriptor of Arx's is passed on (`POSIX_SPAWN_CLOEXEC_DEFAULT`), every signal starts at its default and unblocked, and the script leads a process group of its own.
- Each run writes its standard output and error to its own file in `~/Library/Logs/Arx/App Links`, named by time, scheme and a short random suffix.
- The run gets 30 seconds (`AppLinkScript.defaultTimeout`). Past that its whole process group gets SIGTERM, then SIGKILL up to two seconds later, so commands it left running in the background stop too, and the outcome is `timedOut`. A script that finishes in time may leave background commands running. A non-zero exit is `failed`, with the last 500 characters of its log for the prompt's error. A script that can't start is `unavailable`.
- **`openApp`** opens the link with `NSWorkspace` in the app macOS assigns to its scheme, or, for a chosen `AppLinkApplication` (DEV-862), in that app with `open(_:withApplicationAt:configuration:)`, never letting macOS substitute another running copy with the same bundle ID. A chosen app is found at its path, or where its bookmark leads after a move, and only when the bundle there has the same bundle ID (`AppLinkApplications.locate`); otherwise the outcome is `applicationMissing` and nothing else opens. `didNotOpen` covers no registered app and failed launches.
- **`applicationsForScheme`** lists the apps macOS registers for `scheme://`, default first. **`installedApplications`** reads `/Applications`, `/System/Applications` and `~/Applications`, one folder deep, for apps whose `CFBundleURLTypes` declare schemes a handler may take, and asks Launch Services which apps open each scheme registered while an app ran (`LSHandlers` in the user's `com.apple.launchservices.secure` preferences, `AppLinkApplications.registeredSchemes`), wherever those apps are (DEV-1259). Apps such as Linear register their scheme only that way, with none in their `Info.plist`, so a list read from `CFBundleURLTypes` alone left them out. **`chooseApplication`** shows an open panel for one `.app` anywhere and returns it with a bookmark.
- **`copyLink`** puts the link on the general pasteboard. **`appName`** is the display name of the app that opens a link, and **`appPath`** where it is, for the prompt's icon.

The caller validates the link first (`AppLinkValidation` in BrowserCore); this client trusts it.

## Testing

`testValue` is unimplemented, so a reducer that runs or opens anything unexpectedly fails its test. `previewValue` succeeds without running anything. `AppLinkTests` runs `AppLinkScriptRunner` with the real `/bin/zsh`, so it covers the `$1` contract, the environment, logs, failures and timeouts.
