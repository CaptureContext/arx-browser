# _TestSupport

Re-exports the selected dependencies for TestSupport.

## Boundaries

May depend on extensions and selected external libraries. Must not depend on browser domain, services, design-system, or features.

## Public surface

The imported products are listed in Exports.swift. This target contains no copied helper implementations.

`Settling.swift` holds the waits tests share (DEV-972):

- `pollUntil(_:within:_:)` polls a condition until it holds and fails the test if it never does.
- `waitWhile(within:_:)` waits while a condition holds, up to a deadline, and leaves the verdict to the caller's assertion.
- `Task.settle(count:)` gives started work a few turns at the test's own priority. Use it instead of `Task.megaYield`, whose `.background` hops a busy Mac or a full test run starves.

Wait on a condition with a deadline, never a fixed number of polls, yields or a fixed sleep: those run out early on a busy Mac.

## Validation

`make build-package` compiles this target as part of the complete local package graph. Behavioral tests belong beside this package as its implementation grows. The re-exports need compilation validation rather than tests that repeat their imports; the waits are exercised by the tests that use them.
