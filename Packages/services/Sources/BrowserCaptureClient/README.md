# BrowserCaptureClient

Explicit-session viewport capture boundary, immutable-image cropping and native local export. Depends on BrowserCore and dependency support; it does not depend on browser features or AppUI. PageCaptureExportClient owns the Save dialog and Finder reveal, and for MCP captures a separate choose-destination step and a write of already encoded bytes, so the caller can recheck authority between them.

BrowserCaptureClient starts unavailable until a Chromium adapter provides capture. A request binds tab identity, session revision and hard upper bounds (8192 pixels per edge, 16 megapixels, 64 MiB encoded data, ten-second maximum timeout). captureAuthorized also receives a live grant predicate for future MCP requests. The adapter must recheck it and the revision immediately before native copy and after asynchronous completion, invalidate on page/document replacement, and copy borrowed callback bytes before returning. Frame documentID is the engine document token. Native pixels are required before enabling the feature in production.

`PageCaptureCodec.frame` (DEV-757) draws a captured image in a device on a gradient for the developer header's device capture: a phone in portrait, else a window, laid out by BrowserCore's `DeviceCaptureLayout` and drawn with CoreGraphics; no artwork is bundled or taken from another app. The whole image is scaled down to stay within the capture limits.

`scrollAuthorized` (DEV-1208) scrolls the request's page by an offset in viewport points, for Capture Area's drawing beyond the viewport, and returns how far the page moved: less at its ends. The Chromium adapter checks the request as a capture does, before and after, and refuses hidden and offscreen pages. `scrollIsAvailable` says whether the engine can.

PageCaptureCodec validates PNG metadata before decoding, maps top-left viewport points to the actual pixel dimensions with outward rounding, and crops only the frozen capture. PNG export preserves exact captured bytes; JPEG composites onto opaque white with explicit quality. Native Save chooses the destination and overwrite behavior; writes are atomic, cancellation/failure retain the feature preview. No upload, clipboard, hidden archive or full-document mode is provided.

BrowserCaptureTests use generated image fixtures and temporary destinations. Full-document rendering, protected content, zoom/display behavior and the production viewport adapter need Chromium fixture validation independently.

The pinned Chromium compositor replaces secure-output textures with black for copy requests (`surface_aggregator.cc`), while `CopyOutputBitmapWithMetadata` has no protected-content completeness flag. A CopyFromSurface adapter must report `protectedMediaMayBeMissing` unless it can positively establish completeness, and reject known unsupported rendering. A successful bitmap must not be described as proof that protected pixels were captured.

PageCaptureAuthorizationClient gives the UI flow a live originating-host check. Production defaults deny access; the application installs a predicate that checks utility/request identity, source placement and native session revision.

`PageCaptureRequest.mode` defaults to viewport. Full-document requests require the additive `fullDocumentIsAvailable` predicate, default false, and retain the same live authorization and session/document/profile checks. `PageCaptureFrame.documentGeometry` preserves exact laid-out extent, visible rectangle, fractional scroll and zoom separately from viewport DIP. Frozen selection uses image points relative to the document origin, including negative overflow, and cannot accidentally crop a full-document image using viewport dimensions. The initial explicit raster scale is one pixel per layout pixel; another scale is rejected.
