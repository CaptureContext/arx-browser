# Security policy

## Supported versions

Only the latest release gets security fixes. Arx updates itself through Sparkle from this repository's GitHub Releases.

Arx's engine is Helium, which follows Chromium's releases. A Chromium security fix reaches Arx once Helium ships it and Arx's engine is rebuilt on that version.

## Reporting a vulnerability

Please don't report vulnerabilities in a public issue, discussion or pull request. Report them privately in either of two ways:

- **In Arx:** **Help → Send Feedback…**, kind **Vulnerability**. It goes only to Arx's maintainer, marked urgent, and stays private until a fix has shipped.
- **On GitHub,** if you don't have Arx running: GitHub's private vulnerability reporting. On this repository, open **Security → Report a vulnerability**.

There is no security email address.

Include:

- what you found and the impact you see;
- how to reproduce it;
- the Arx version (Arx → About Arx) and the macOS version.

We'll acknowledge the report within 10 calendar days and keep you updated until it's fixed. The vulnerability is disclosed only after a fix has shipped. We'll credit you in the release notes unless you'd rather not be named.

## Scope

In scope is Arx's own code, including:

- profiles and their isolation from each other, and private windows;
- saved passwords and the migration of data from other browsers;
- the local MCP server, its permission grants and the bundled `ArxMCP` helper;
- headless runs (`Arx --headless`);
- extension installation and the Chrome Web Store flow;
- iCloud sync of the workspace;
- the update feed and the signing of release builds and updates;
- Arx's own changes to the engine: the overlays in `Scripts/engine/` and the native bridge in `Packages/engine/Native`.

Bugs in Chromium or Helium that Arx doesn't change are better reported upstream: Chromium at <https://issues.chromium.org> (use the security template), Helium at <https://github.com/imputnet/helium>. If you're not sure where a bug belongs, report it to us and we'll route it.
