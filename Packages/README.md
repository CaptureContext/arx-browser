# Packages

Arx has eight macOS-only packages. Their Swift package names use the `arx-` prefix. Directory names, role helpers, and module names remain unprefixed. Local dependency declarations explicitly associate each package name with its directory. All app-owned manifests use Swift 6.4 and macOS 27.

- [arx-engine](engine/README.md): independent Helium bridge and Swift runtime API.
- [arx-extensions](extensions/README.md): foundational utility re-exports.
- [arx-dependencies](dependencies/README.md): external library wrappers.
- [arx-core](core/README.md): browser domain values and contracts.
- [arx-services](services/README.md): browser effects and persistence boundaries.
- [arx-design-system](design-system/README.md): shared native UI and resources.
- [arx-features](features/README.md): TCA screens and application composition.
- [arx-tools](tools/README.md): developer tools such as `make style`'s checker; nothing in the app links it.

The executable connects `Application -> AppFeature -> MainFeature`, composing SidebarFeature, CommandBarFeature and ViewerFeature. ViewerFeature hosts one ViewerItemFeature without split logic. ChromiumBrowserEngine owns live pages and exposes BrowserEngineClient commands plus BrowserSurfaceClient attachments. Services depend on core, the engine adapter and shared dependency wrappers. AppUI uses shared UI extensions and wrappers without interpreting domain state. Core does not depend on UI or services. Dependencies may depend on extensions, never the reverse.

The current slice reports that the engine has not been integrated. The selected SQLiteData and StructuredQueries wrappers are available for future history, bookmark, and session storage; no schema or persistence behavior is created by this setup.

Selected local forks live in [Forks](../Forks/README.md). App-owned manifests declare the same fork overrides to prevent transitive remote dependencies replacing them. Each target has a README. Tests belong beside the owning package. Generated workspace membership follows the manifests directly under this directory.

## Manifest conventions

Each manifest starts with its package graph, followed by project-specific helpers and the SwiftPM helper DSL. Declare forks with `.fork("swift-navigation")` and local packages with role properties such as `.core`, `.services`, and `.features`.

Group targets alphabetically with `// MARK: - <Letter>` sections inside `producibleTargets`. Ignore a leading `_` when choosing the letter for dependency wrappers.

The six application-layer packages retain the same role helpers. A helper definition adds no dependency until used in a dependency list; its availability does not change the package boundaries above.

Group target dependencies with `.group(...)`. Use `.core("BrowserCore")`, `.services("BrowserEngineClient")`, `.feature("ViewerItemFeature")`, and `.dependency("_SQLiteData")` to express ownership. These helpers resolve to a target within its owning package or a product across packages. Both paths preserve dependency conditions. Shared products have named properties such as `.localExtensions`, `.appUI`, `.composableArchitecture`, and `.testSupport`.

Native product declarations belong in the helpers and the third-party wiring in extensions and dependencies. Keep the generic SwiftPM helper section aligned with the swiftpm skill. Package helper paths are relative to each manifest, with the root using `Packages/` and local packages using sibling paths.
