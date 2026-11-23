# Prebuilt development engine

This directory holds the manifest of the prebuilt Arx Helium framework, `arx-engine-macos-<architecture>.json`. The archive it describes (about 160 MB) is published as a release asset of [`capturecontext/arx-browser-engine`](https://github.com/capturecontext/arx-browser-engine), or built locally; the manifest stays in git and is what every copy is checked against.

The current archive is for **Apple Silicon (`arm64`) and macOS 27 or later**. It includes the complete framework, helper apps, libraries, and runtime resources. It is a development artifact, not a notarized app or production distribution. Intel Macs require a separately built `x86_64` archive.

## Another Mac

From the checkout:

```sh
make bootstrap
make engine-fetch engine-validate
make build-app-runtime
```

Xcode 27 with Swift 6.4 and the repository's mise setup are still required for the Swift app. None of the engine commands needs a Chromium source checkout, Chromium toolchain, or Helium Python environment.

`make engine-fetch` first checks that the manifest matches the current engine sources and architecture, so a stale manifest fails before any download. If the matching engine is already restored, it stops there. Otherwise it takes the first archive that matches the manifest's size and SHA-256, in this order:

1. `.build/engine-archives/<source fingerprint>/arx-engine-macos-<architecture>.tar.gz`: built here by `make engine-cache`, or downloaded earlier.
2. `Artifacts/Engine/arx-engine-macos-<architecture>.tar.gz`, a copy placed beside the manifest by hand. Git ignores it.
3. The manifest's `url`, downloaded into the folder of step 1. The download needs no credentials, follows the release asset's redirect, and is checked against the manifest's size and SHA-256 before anything is unpacked. Only `https` and `file` URLs are accepted.

`make engine-restore` is the offline half: it unpacks the first verified archive from steps 1 and 2 and never downloads.

What fails, and how:

- **The asset isn't published** (HTTP 404, or a missing `file` URL): the error names the URL, says to build the engine with `make engine-build` and `make engine-cache`, or to put an archive for this engine at the path of step 1 and run `make engine-fetch` again.
- **Size or checksum mismatch**: the download is deleted and the error says `size mismatch` or `checksum mismatch`. Nothing is unpacked. A local archive that doesn't match is skipped, with the reason printed, and the next source is tried.
- **Stale manifest** (engine sources or architecture changed since the archive was built): `does not match the current engine sources/architecture`, before any network access. Build the engine and run `make engine-cache`.
- **No `url` in the manifest**: run `make engine-cache` to record one.

Restore checks the archive SHA-256, size, architecture, and current engine source fingerprint before unpacking, and never runs anything from the archive. It preserves framework symlinks and executable bits, and rejects paths or links escaping the extraction directory. The restored framework lives under ignored `.build/engine/prebuilt/<architecture>/<source fingerprint>/`. Repeating restore reuses the matching copy. The app embed script and standalone host use it when no matching local source build is available.

`make engine-validate` checks the selected framework's version links, helper executables and metadata, required libraries/resources, execute permissions, and Mach-O architectures. Embedding validates both the source and copied framework. `make build-app-runtime` is unsigned but requires a matching engine and validates the resulting app bundle; `make build-app` and `make test-all` can still run without an engine or signing environment. AppUI preview builds do not need the engine.

Run `make test-runtime` to validate both signed hosts, or `make app-smoke` / `make engine-smoke` individually. These commands require a configured Apple Development identity, an unlocked keychain and an interactive macOS login session. Runtime stdout/stderr and failure summaries are retained in `build/logs/runtime/` even when setup fails. Build logs remain in `build/logs/`.

## Release URLs

The archives live in a repository of their own, `capturecontext/arx-browser-engine`, which holds releases and no source: the engine's sources are here. Each engine is one release there, tagged by its source fingerprint, and each architecture is one asset of it:

```text
https://github.com/capturecontext/arx-browser-engine/releases/download/engine-<first 16 hex digits of the source fingerprint>/arx-engine-macos-<architecture>.tar.gz
```

The fingerprint is `identity.sources` in the manifest, the same value that decides whether a restored engine is current, so a tag never names two different engines. This repository's own releases are the app's only, so the release marked latest here is always the one the Stable update feed follows. The manifest records the full URL; `make engine-fetch` reads it from there, so a later change of scheme only needs a new `make engine-cache`.

## Publish a new engine

After a complete source build:

```sh
make engine-build
make engine-cache
```

`make engine-cache` writes the archive to `.build/engine-archives/<source fingerprint>/`, updates the manifest (fingerprint, checksum, size, URL), and prints the `gh` command that uploads the archive. It uploads nothing itself. The command looks like this:

```sh
gh release create engine-<fingerprint> .build/engine-archives/<fingerprint>/arx-engine-macos-arm64.tar.gz \
  --repo capturecontext/arx-browser-engine --title '…' --notes '…'
```

When the release exists already because another architecture was published first, `gh release upload engine-<fingerprint> <archive> --repo capturecontext/arx-browser-engine` adds the asset. Publish the asset, then commit the manifest: a manifest whose asset is missing fails `make engine-fetch` everywhere except on the Mac that built it.

`ENGINE_ARCH=arm64` or `ENGINE_ARCH=x86_64` selects the intended architecture for the engine commands. Export verifies the Mach-O architecture and requires a matching completed source build.

The manifest records the pinned Chromium version, source fingerprint, architecture, archive checksum/size, download URL, minimum macOS version, packaging Xcode version, and hash of the source build's GN arguments. Xcode provenance is recorded for diagnostics; restoring does not require an identical Xcode build. The source build's existing completion stamp and fingerprint remain unchanged.

Only engine changes require a new archive. Swift UI changes do not. Restored files stay separate from the Chromium checkout so they cannot be mistaken for a prepared source tree.

## CI and supported architectures

The Checks workflow on GitHub's hosted macOS runner (pull requests and `main`) restores the exact arm64 engine with `make engine-fetch engine-validate`, runs the unsigned checks and tests, and validates required runtime packaging with `make build-app-runtime`. It needs no `.env`, signing team or certificate, and doesn't claim that Chromium has launched. See [Public CI](../../DEVELOPMENT.md#public-ci). A fork's CI fetches it the same way, without credentials.

The signed smokes aren't part of CI: `make signing-check` and `make test-runtime` run locally, on a Mac with an Apple Development signing identity and a logged-in GUI session. The Checks job uploads `build/logs/` on failure as well as success.

| Architecture | Prebuilt archive | Runtime validation |
| --- | --- | --- |
| `arm64` | Pinned archive available as a release asset | Locally validated on macOS 27; explicit CI smoke job available |
| `x86_64` | No archive | Planned only; requires its own source build and runtime validation |

The architecture values in `engine.lock.json` are build selections, not a claim that both architectures have passed runtime acceptance. No universal app or Intel runtime is currently validated.
