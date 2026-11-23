# BrowserPageInspectionClient

Fail-closed dependency for a bounded historical semantic snapshot of one explicitly granted existing ordinary page. The app supplies trusted profile, session, document and per-connection scope identities. The implementation rechecks live authorization at entry and completion; the host checks it again before IPC release.

`documentIsCurrent` verifies native page/document/scope liveness only. It cannot prove that the DOM still equals the historical renderer version. Opaque references never authorize actions and must be resolved in the renderer on each future use. No action or public validate-only API is exposed here.

The default dependency is unavailable. Runtime composition must explicitly provide the native implementation after readiness; private pages, loading saved pages, navigation, focus, scrolling and raw DOM/script access are excluded.
