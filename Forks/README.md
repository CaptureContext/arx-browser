# Forks

These independent Git submodules start at selected revisions. `.gitmodules` records each fork's remote.

Run `make submodules` to initialize missing checkouts at their recorded Git revisions. Bootstrap never updates to the latest branch or resets existing local work. `.gitmodules` contains remote URLs; no sibling checkout path is required by a fresh clone.

App-owned SwiftPM manifests explicitly override these package identities with local paths. Shared remote dependencies remain remote unless the selection policy permits a compatibility fallback.

Do not push changes or publish releases from these checkouts as part of application setup. Any compatibility patches must be recorded and reproducible before this repository is distributed.
