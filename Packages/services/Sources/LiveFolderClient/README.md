# LiveFolderClient

Fetches the items of live folders, pinned folders that fill themselves (DEV-926). Depends on BrowserCore, whose `LiveFolderSource`, `LiveFolderItem`, `LiveFolderContents` and `LiveFolderFailure` describe sources, items and refreshes.

- `LiveFolderClient` (`liveFolders` dependency): `isAvailable(source)` and `fetch(source)`, which throws a `LiveFolderFailure`.
- `LiveFolderAccounts` is the seam for accounts: a token per `LiveFolderService`, or nil. Arx ships with `.none`, so `liveValue` fetches nothing and every live folder reports `notSignedIn`. How a user signs in (a pasted token in Arx's own Keychain item, a GitHub app, or something else) is Max's decision; plugging it in means giving `running(accounts:transport:)` a real `LiveFolderAccounts`.
- `GitHubPullRequests` is the first source: GitHub's REST search (`/search/issues`) for open pull requests the account opened (`author:@me`) or is asked to review (`review-requested:@me`), most recently updated first, 50 at most. The request carries only the token and the query, through an ephemeral session without cookies or stored credentials. 401 is `unauthorized`, 429 or a 403 with no requests left is `rateLimited`, any other 403 `unauthorized`. Items keep GitHub's IDs (`github-pr-<id>`), so a refresh can tell new pull requests from listed ones, and only `https://github.com` pages are kept.

Tests (`LiveFolderTests`) use a fake transport; nothing reaches GitHub.
