# BrowserHistoryTests

Profile isolation, exact URL round trips, bounded stable identity, write failure/retry, external modification, corrupt/future versions, explicit scoped clearing, and merging imported history by URL with the newest visit, written at once. All persistence uses disposable directories; no browser profile is opened.

`clearingSinceKeepsOlderEntriesAndWritesAtOnce` (DEV-647) covers `clearSince`.
