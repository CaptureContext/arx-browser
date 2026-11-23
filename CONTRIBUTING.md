# Contributing to Arx

Thanks for your interest in Arx. Right now the most useful help is reports: bugs, crashes, sites that break, and ideas.

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md), and [GOVERNANCE.md](GOVERNANCE.md) says who decides what. Report security problems privately as [SECURITY.md](SECURITY.md) describes, not in an issue.

## Issues and discussions

- **Bugs:** open an issue with the bug report form. In Arx, Help › Report a Problem fills in the versions for you and saves a diagnostics file you can attach.
- **Feature requests:** open an issue with the feature request form. Say what you're trying to do; the problem matters more than a proposed design.
- **Questions and ideas:** use [Discussions](https://github.com/capturecontext/arx-browser/discussions). An idea that gathers a clear shape there can become a feature request.

Search the existing issues and discussions first, and add to one that matches instead of opening a new one.

## Pull requests: not accepted yet

Arx doesn't accept pull requests for now. A pull request will be closed without review, however good it is. Two reasons:

- Arx is early. Its structure, engine patches and features change quickly, and there is one maintainer, who can't review outside code well while that lasts.
- The contributor agreement below isn't in place yet, and no outside code can come in without it.

If you've fixed something, open an issue that describes the bug and the fix. A clear description of the cause is often all that's needed.

## The contributor agreement to come

Arx's own code is licensed under the GNU General Public License, version 3 ([LICENSE](LICENSE)), and stays that way. When pull requests open, contributors will sign a Contributor License Agreement (CLA) before their first one is merged.

The reason, plainly: Arx's maintainer wants Arx to stay GPL for everyone, and also to keep the right to license his own code to others under different terms. A contribution made under the GPL alone would prevent that, because any version containing it could then only be distributed under the GPL. A sign-off such as the Developer Certificate of Origin (`git commit -s`) only confirms you may contribute the code; it doesn't grant that right. The CLA does, while your contribution also stays available to everyone under the GPL.

The agreement's text and how to sign it will be published here before pull requests open.

## Building and testing

You can build and test Arx without an Apple developer account. The [README](README.md) covers building from source, and [DEVELOPMENT.md](DEVELOPMENT.md) is the full reference: every Make command, the engine, signing, smoke tests and releases. In short:

```sh
make bootstrap                      # tools, Forks/ submodules, Swift packages, Xcode workspace
make engine-fetch engine-validate   # the prebuilt arm64 engine
make test-all                       # what CI runs: checks, tests and builds
```

## Code style

The Swift style guide is the `swift-style` skill in [.agents/skills/swift-style](.agents/skills/swift-style/SKILL.md), written for people and coding agents alike. Indentation follows [.editorconfig](.editorconfig): tabs for Swift. Style checks are advisory: a review may point out where code departs from the guide, but style alone doesn't block a change. Compiler warnings and failing tests do.

Project rules for agents, and the structure every change follows, are in [.agents/AGENTS.md](.agents/AGENTS.md).

## Dependencies

A new dependency needs a licence compatible with GPL-3.0, such as MIT, BSD, Apache-2.0, LGPL or MPL-2.0. It gets a row in `THIRD_PARTY_NOTICES.md`, and `make credits` regenerates the credits About Arx shows; a test fails if a resolved package has no row or the credits are stale.

## Name and icon

The name "Arx", the app icon and the wordmark are reserved: a fork you distribute needs its own name and icon. [TRADEMARKS.md](TRADEMARKS.md) says what is and isn't fine.
