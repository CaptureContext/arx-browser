# _URLRouting

Re-exports the selected dependencies for URLRouting.

## Boundaries

May depend on extensions and selected external libraries. Must not depend on browser domain, services, design-system, or features.

## Public surface

The imported products are listed in Exports.swift. This target contains no copied helper implementations.

## Validation

`make build-package` compiles this target as part of the complete local package graph. Behavioral tests belong beside this package as its implementation grows. Re-export-only targets need compilation validation rather than tests that repeat their imports.
