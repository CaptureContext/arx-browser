# Arx

Arx is a web browser for macOS built on Chromium. Tabs live in a sidebar instead of a tab strip, organised into profiles, spaces, folders, pinned tabs and Favorites. On top of that sit a command bar (⌘T), Split View, Peek for links you only want to glance at, and Little Arx for links opened from other apps. Each profile is its own sandbox: passwords, extensions, cookies and sessions never cross between profiles.

Arx can also be driven by AI agents. A local MCP server, off until you turn it on, gives an assistant access to the browser only within the grants you approve.

The engine is [Helium](https://github.com/imputnet/helium), a privacy-focused Chromium by imput, built with Arx's own patches into an embeddable framework. The app around it is written in Swift with the [Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture).

Arx is in beta. Download it from [Releases](https://github.com/capturecontext/arx-browser/releases); it keeps itself up to date from there. The [user manual](https://manual.arx.capturecontext.dev) describes what it does.

## Requirements

- macOS 27 or later on Apple silicon. The prebuilt engine is arm64 only; an Intel build needs its own engine build.
- Xcode 27 with Swift 6.4 or later, selected with `xcode-select`.
- [mise](https://mise.jdx.dev), which installs the pinned Python, Ruby, Fastlane and XcodeGen.

## Build from source

From a clone of this repository:

```sh
mise trust
make bootstrap                  # tools, Forks/ submodules, Swift packages, Xcode workspace
make engine-fetch engine-validate   # download, verify and unpack the prebuilt arm64 engine
make build-app-runtime          # unsigned Arx.app with the engine; prints where it is
```

`make open` opens `Project.xcworkspace` in Xcode. Generated Xcode files aren't checked in: change `project.yml` or `.xcodegen/` and run `make project`.

### Unsigned builds

`make build-app` and `make build-app-runtime` build without signing. They need no Apple account, no `.env` file and no certificates, which is how CI builds Arx. `make build-app` also works without the engine, for work on the Swift side only.

### Signed development builds

The smoke tests and `make run` sign with an Apple Development certificate. Copy `.env.example` to `.env` and set `DEVELOPMENT_TEAM` to your own team ID, then run `make project`. `.env` is ignored by Git; keep it, certificates and provisioning profiles out of commits. These are Arx Dev builds, `dev.capturecontext.arx.dev`, with their own data beside an installed Arx ([DEVELOPMENT.md › Arx Dev](DEVELOPMENT.md#arx-dev)). The bundle identifiers and their iCloud container belong to CaptureContext's team, so with your own team you may need to change them in `.xcodegen/macOS.yml`.

### The engine

`make engine-fetch` downloads the prebuilt engine archive from the release of [`capturecontext/arx-browser-engine`](https://github.com/capturecontext/arx-browser-engine) named in [Artifacts/Engine](Artifacts/Engine/README.md)'s manifest and checks it against the manifest. To build the engine yourself instead, which is a full Chromium build and takes hours:

```sh
make engine-tools      # pinned Python and the engine build environment
make engine-checkout   # helium-macos, Helium and Chromium at the revisions in Packages/engine/engine.lock.json
make engine-prepare    # download Chromium, apply Helium's patches and Arx's overlays
make engine-build      # build Arx Framework.framework
```

The pins are helium-macos `da5fcc2`, Helium `a2d96a7` and Chromium 157.0.8103.78. Arx's changes to Chromium are overlays in [Scripts/engine](Scripts/engine/README.md) and native code in [Packages/engine/Native](Packages/engine/README.md).

## Tests

```sh
make test       # script tests and every package's Swift tests
make test-all   # checks, tests, package and app builds, preview tests: what CI runs
make style      # advisory swift-style warnings; never fails on findings
```

To test one package:

```sh
mise exec -- swift test --package-path Packages/features --scratch-path .build --security-path build/swift-security
```

Smoke tests such as `make app-smoke` start the real browser in a signed build and need a logged-in macOS session. [DEVELOPMENT.md](DEVELOPMENT.md) lists them all.

## Repository layout

- `Containers/macOS`: the app target's entry point and bundle resources.
- `Packages/`: the app's Swift packages by role: engine, extensions, dependencies, core, services, design-system and features. Each has a README.
- `Forks/`: pinned forks of upstream packages, as Git submodules.
- `Scripts/`: the Python behind every `make` command.
- `Previews/AppUI`: a standalone app for the sidebar and command bar without Chromium (`make preview`).
- `Artifacts/Engine`: the prebuilt engine's manifest.

[DEVELOPMENT.md](DEVELOPMENT.md) covers every Make command, signing, release disk images, developer mode and headless runs.

## Licence

Arx is free software, licensed under the GNU General Public License, version 3: see [LICENSE](LICENSE). Arx is built on Helium, whose own code is under the same licence, and on Chromium and ungoogled-chromium code under the BSD 3-Clause License. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists every dependency and its licence; the app shows the same list under Arx → About Arx. The name and icon are not part of that licence: see [TRADEMARKS.md](TRADEMARKS.md).

## Contributing

Bug reports and feature requests are welcome as issues, and questions and ideas in [Discussions](https://github.com/capturecontext/arx-browser/discussions). Pull requests aren't accepted yet; [CONTRIBUTING.md](CONTRIBUTING.md) says why, and describes the contributor agreement that will come with them. Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md); [GOVERNANCE.md](GOVERNANCE.md) says how decisions are made. Report security problems privately as described in [SECURITY.md](SECURITY.md), not in public issues.
