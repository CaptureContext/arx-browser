# arx-core
Low-level package for browser domain values and contracts. Requires macOS 27 or later and Swift 6.4.
## Boundaries

May depend on extensions. Must not depend on UI frameworks, service implementations, or features.
## Targets
- [BrowserCore](Sources/BrowserCore/README.md): profiles, spaces, folders, tabs, session metadata, and organization validation.
- [BrowserCoreTests](Tests/BrowserCoreTests/README.md): deterministic domain tests.

New targets must have their own README and remain within the package role. Browser-owned code is new for Arx.

Reference scroll adds a bounded, finite axis/delta contract and value-free dispatch receipts to the existing explicit automation operation family.
