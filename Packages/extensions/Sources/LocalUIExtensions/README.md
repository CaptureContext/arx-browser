# LocalUIExtensions

Exports LocalExtensions and the selected Cocoa aliases and extension libraries.

## Boundaries

May depend on the selected utility packages and forks. Must not depend on core, services, UI components, or features.

## Public surface

Re-exported modules are declared in Exports.swift.

## Validation

`make build-package` compiles this target as part of the complete local package graph. Behavioral tests belong beside this package as its implementation grows. Re-export-only targets need compilation validation rather than tests that repeat their imports.
