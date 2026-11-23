# PageCaptureFeatureTests

Every suite that uses dependencies, a store or `@Shared` takes `@Suite(.dependencies)` (DEV-970). Without it, every test in the process shares one set of dependency test values, including swift-sharing's storage and `@Shared` references. A test then reads what another left behind, so it passes alone but fails on a repeat or next to another.

Tests for PageCaptureFeature with generated PNG pixels and injected capture, inspection and export clients. No Chromium process or native dialog is required.

- `PageCaptureGeometryTests` cover which nodes can be picked, hit-testing the innermost block, arrow-key movement, drag regions, the click/drag threshold, menu placement and media regions.
- `PageCaptureFeatureTests` cover reading node bounds in windows and revoking the scope, hover and click, drag, Retina crops, visible-area capture, Copy, Save, Edit, canceling Save, Retake, Escape, clicking away, the arrow keys and Return, re-reading bounds after scrolling, drawing without bounds, bounded stale retries, the protected-media note and Capture Full Page.
- `PageCaptureSoundTests` cover which captures make a sound (DEV-1256) with a recording `SoundFeedbackClient`: Copy and Save play `capture`, canceling the Save panel and Edit are silent, and a capture or a copy that fails plays `couldNot`, while a page that changed is retaken quietly until Arx gives up.
- `PageCaptureSnapshotTests` render the overlay offscreen in light and dark (hover, drag, menu, protected-media note) and write the PNGs when `ARX_DESIGN_SNAPSHOTS` names a directory.
