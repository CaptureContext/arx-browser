# ChromiumHostTests

Tests the standalone host's explicit disposable-smoke configuration: ordinary launches keep the real Keychain; only a fresh, private, owned fixture directory inside the runner's work directory may request mock storage. Existing profiles, alternate destinations, missing markers, symlinks, oversized fixtures and non-loopback URLs are rejected before runtime startup. No native framework or Keychain API is called.

Extension smoke sequencing tests advance a simulated native inventory revision during the disabled-page wait and require a fresh inspection before enabling. They retain the intentional stale-revision rejection and verify that immediate mutation failures, permission changes and cancellation do not silently proceed. No native runtime or UI is launched.

Inspection fixture tests enforce exact loopback origins, trusted-input URL/geometry guards, positive author-shadow semantics, every excluded sentinel and unique explicit button references. The native runner separately requires each lifecycle/privacy/reference phase and clean shutdown. These tests use synthetic snapshots and never launch a browser.

Form fixture contracts require exact owned run URLs and positive input geometry,
value-free bounded evidence, exactly one trusted input/change pair with no granted
activation/focus, and explicit unchanged versus uncertain outcomes. The HTTP
runner additionally requires every anchored native phase and clean shutdown.

Reference-scroll contract tests reject invalid/unbounded effect evidence,
focus/activation or untrusted events, and navigation receipts outside the exact
known-dispatch/document-invalidation alternatives. A validated unchanged receipt
cannot substitute for movement evidence. These tests do not launch Chromium.

Stored site icon wait tests (DEV-943) drive the back/forward cache smoke's icon
wait with scripted store reads and a clock that sleeps at once. They require it
to keep reading through misses, failed lookups, another favicon or an empty
bitmap, to stop at the first stored icon, to time out after its bound with the
page, the icon, the last read, the read count and the caller's icon changes, and
to stop on cancellation. They do not launch Chromium.
