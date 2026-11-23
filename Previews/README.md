# Standalone previews

Generated macOS application targets for testing components without Chromium or live services. Run `make preview` to build and open AppUIPreview. `make build-preview` only builds it. Shared bootstrap is in [Shared](Shared/README.md); each preview owns its fixtures and state.

- [AppUI](AppUI/README.md): browser sidebar and command bar.

XcodeGen includes `previews.yml` from the root project. Preview targets link component products directly and do not link Application or ChromiumEngine.
