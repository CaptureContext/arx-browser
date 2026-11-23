# AppLinkTests

`AppLinkApplicationsTests` (DEV-862) builds fixture app bundles in a temporary folder: schemes are read from `CFBundleURLTypes` without web schemes or repeats, a chosen app gets its name, bundle ID and a bookmark, installed apps are listed one folder deep when they declare schemes, and `locate` follows an app that moved but never returns another app at the old path or one that's gone.

Runs `AppLinkScriptRunner` with the real `/bin/zsh` in a temporary log folder: a link with `;`, `$(…)`, quotes and spaces reaches the script as one argument, unchanged, in both `$1` and `ARX_LINK`; the context variables are set; output lands in the run's log; a non-zero exit reports its error; a script past a short timeout is stopped and reported as timed out, a background command it started that ignores SIGTERM is stopped with it, and the script reads empty input in the home folder.
