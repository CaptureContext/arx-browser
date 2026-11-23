# BrowserPageWaitClient

Read-only observation of loading in one existing ordinary native page generation. The app supplies the validated entry identity and a live authorization predicate. The client never opens, focuses, navigates or mutates a page. Default clients fail closed.

A primary navigation start or commit invalidates the wait, including identical-URL reload and same-document navigation. This cannot follow a navigation through commit or prove network idle, DOM readiness, HTTP success or website-action completion. A stopped observation preserves any native error code. The result is historical metadata; `sourceIsCurrent` revalidates native lifetime and publication at final response release.
