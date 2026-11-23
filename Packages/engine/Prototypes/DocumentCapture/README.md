# Full-document native capture

This implementation is linked by the ABI16 adapter and exposed through the
Swift capture service, app feature and MCP. Its historical Prototypes directory
is included in native artifact inputs. `Scripts.engine.document_capture_prototype`
can also prepare an isolated source copy and refuses the configured runtime
checkout. The production build uses `document_capture_overlay`.

The renderer samples the exact pixel-snapped Blink document rectangle, including
negative overflow, visible rectangle, fractional scroll, document token, focus
node, zoom and pinch scale. A read-only Blink accessor exposes the rectangle;
there is no CSS-dimension flooring, DevTools emulation, viewport resize or scroll
command. The same values must match before/after Paint Preview recording and
again after browser composition/encoding. A layout flush inside Paint Preview
may reveal a changed extent; that result fails instead of being clipped to the
old extent. The implementation rejects child frames and pinch scale other than 1.

Paint Preview records current non-paginated layout with scrollbars retained, so
removing layout-affecting scrollbars cannot change the capture width. Chromium's
Start/EndPaintPreview temporarily invalidates capture paint properties and
restores saved nested scroll offsets synchronously. Real fixtures must still
prove that no scroll, focus, form, selection or observable resize state changes.
This is not PDF output or an infinite/lazy-content traversal.

The renderer returns an in-memory SKP. The browser uses the existing sandboxed
Paint Preview utility's `BeginMainFrameComposite` and `BitmapForMainFrame`,
rejects partial/incorrect geometry, then encodes PNG. Output uses one raster pixel per Blink layout pixel, independent of display
backing scale. Metadata reports zoom, device scale and raster scale separately.
The owned fixture checks 125% zoom and the current display backing scale.

## Limits and lifetime

The caller's limits are constrained to 8192 pixels per dimension, 16M raster
pixels, 16 MiB of retained paint records, 100,000 paint operations, 32 MiB of
aggregate decoded images, 32 MiB of serialized recording, 64 MiB PNG and 10 s.
Raster dimensions are checked before recording and again before requesting the
bitmap. The serialized stream rejects each oversized write before retaining it.
Before SkPicture conversion, a metadata-only recursive admission pass caps
record operations, record depth (32), save depth (64 per record), referenced path/font-table
bytes and glyphs. Glyph count shares the 100,000 operation ceiling. At most 256
unique typefaces and 256 tables per typeface are admitted, using fixed arrays;
font table payload/directory accounting precedes subsetting or stream opening.
Images are charged per use, including repeated references, for at least N32
storage even when their resident source uses a smaller format. Oversized input
images fail before GPU readback. The callback before each conversion op checks
the remaining deadline; failed readback is a failed capture, not a blank image.

The first admission policy rejects lazy/generated/animated/gainmap images,
filters, image/record/SkSL and non-linear gradient shaders, path effects, draw
loopers, offscreen layers, frame custom data, Skottie, vertices and GPU text slugs.
It can admit simple shapes, paths, ordinary text, resident raster/texture images,
and solid-color or linear-gradient shaders, each charged 4 KiB of referenced
bytes. Linear gradients cover macOS classic scrollbar tracks, which the recording
retains, and CSS `linear-gradient`. Both the recording-time admission and the
browser's record admission apply the same shader rule. An unadmitted recorded resource returns unsupported
for the complete capture; it is never knowingly dropped. This is a conservative
supported subset; unsupported pages can use viewport or region capture.

Both embedded-image PNG serialization and final-output PNG encoding use the same
pinned Chromium SkPngRustEncoder backend through a fixed-capacity SkWStream.
Every write is rejected before retention, and each row checks deadline and (for
the browser worker) cancellation. This replaces the earlier post-encoding vector
size check. Transparency is retained. An input that cannot expose admitted
resident pixels, or any image/encoding budget failure, invalidates the complete
result; the normal Paint Preview policy of silently dropping images is avoided.
All intermediate data is memory-only, including in off-the-record contexts.

There is one shared physical capture operation. Cancel, timeout, navigation, closure,
document/frame replacement, visibility and view geometry changes complete the
logical request once. The physical slot stays occupied until its outstanding
renderer/compositor/encoder stage returns or disconnects. A hung stage leaves
capture busy rather than admitting unlimited replacement work. Immutable
operation tokens protect deferred cleanup from a newer operation. Final shutdown
is the only unconditional reset. The adapter unifies this slot with viewport capture and retains the existing
Swift live authorization and document/session checks against queued late callbacks.

## Recording admission and acceptance boundaries

- Fresh capture recording now has cooperative admission at its retaining seams.
  A pending renderer budget becomes active only inside PaintPreviewContext after
  UpdateLifecyclePhasesForPrinting, before its fresh transient PaintRecordBuilder.
  A metadata-only layout preflight caps 4096 laid-out objects, 10,000 fragment
  entries, 100,000 original text code units and parent depth 64. It includes the
  actual flattened layout tree rather than assuming DOM node count bounds paint.
  Every preflight step and retaining seam checks the remaining deadline.
- Before RecordPaintCanvas constructs/pushes an op, it charges the operation,
  buffer/canvas descriptors and referenced nested-record/path/blob/image metadata.
  Before transient PaintController retains an item/subsequence or PaintChunker
  grows a chunk/hit-test/selection container, it charges the corresponding entry.
  The aggregate container policy is 16 MiB; each entry is conservatively charged
  4096 + 4*descriptor bytes to cover initial cc buffers, growth/release-copy slack
  and small container capacity overhead. Canvas entries include PaintOpBuffer and
  RecordPaintCanvas descriptors; item entries include the largest slot descriptor.
  This deliberately admits fewer than the 100,000 operation ceiling on many
  pages. Referenced payload admission has a separate 16 MiB ceiling; image use
  retains the 32 MiB aggregate N32 ceiling. Expensive flags/layers, foreign layers,
  tracked/region metadata and the earlier unsupported-op set fail the whole image.
- Rejection is sticky. No further guarded retention occurs, logical save/restore
  depth still unwinds, denied subsequence indices are ignored, and every denied
  chunk caller returns before indexing back(). A failed fresh builder is discarded
  before EndRecording; a failure during final record conversion is checked again
  before the renderer publishes anything. Ordinary lifecycle/persistent-cache
  painting runs outside the active scope. The owned fixture must prove a tiny
  recording budget rejects cleanly, leaves page state unchanged and permits an
  actual subsequent ordinary compositor repaint.
- This bounds the specified capture record containers before growth, not renderer
  RSS or every painting allocation. Printing lifecycle/layout runs first as page
  rendering work; text shaping/font/backend workspaces, fixed builder/artifact
  descriptors and delayed Oilpan collection are not an allocator sandbox. A long
  single backend call cannot be interrupted by the per-seam deadline. Physical
  capture ownership remains busy until that stage returns after logical timeout.
  Native memory/latency/fidelity acceptance is still required; no exception,
  longjmp or global allocator veto is used.
- Explicit retained capacities are 16 MiB for the admitted cc record, 32 MiB
  for serialized recording, 32 MiB aggregate decoded image payload (with up to
  another payload during readback fallback), and 64 MiB final PNG. Fixed byte
  streams may coexist with an equally bounded result copy. A 16M-pixel N32
  output is 64 MiB; utility/browser bitmap transfer may retain two copies.
  These are per-stage buffer bounds, not an exact total RSS claim. One physical
  operation and its outstanding stage remain owned through cancellation.
- Child frames are rejected, not omitted. Multi-frame atomicity, shared budgets,
  frame clipping and independently scrolling frame preservation need a separate
  extension after the single-document path is demonstrated.
- Protected video/WebGL omissions are not reliably detectable by this path.
  Pixel fidelity, fixed/sticky behavior, animation, lazy content, scaling and
  utility-process packaging have not been executed against a built prototype.
- Loading/incomplete metadata, production error mapping and capability gates,
  progress/cancel presentation and full-document preview metadata remain outside
  this native-only slice. Existing viewport/region behavior is unchanged.

The focused Python suite compiles the actual budget/byte-buffer, record-admission
and PNG-control bodies. ASan/UBSan resource peers prohibit readback/font-stream
APIs and cover aggregate image/path/glyph/font accounting, unsupported resources,
nested/state limits and sticky deadlines. Encoder peers test fixed-capacity
header/row rejection, cancellation/deadline boundaries and invalid geometry
before encoder creation. They do not encode actual pixels.
Overlay tests cover repeatability, changed anchors and refusal to touch the shared
runtime. Thirteen isolated native units, including the recording canvas/controller/chunker
and native adapter, pass syntax with generated Mojo against pinned headers. These are preparation
checks only; no prototype framework or pixel fixture has been executed.
Required runtime fixtures must include long/horizontal/negative-overflow layouts,
focused forms and scroll/resize/selection counters on every exit, cancellation
and stale documents, oversized records/images, canvas/video, fixed/sticky content,
Retina/fractional zoom and lazy sentinels that remain unfetched.

## Owned native acceptance fixture

The explicit `:fixture` target provides `OwnedCaptureFixture`. Its owner must
create a fresh disposable profile, WebContents and visible window under the
existing host-smoke storage guard, start the loopback routes from
`Scripts/core/document_capture_fixture.py`, and keep the controller alive until
completion. The fixture itself creates no windows, has no shipping C symbol and
is not started automatically. The staged native fixture entry and `make document-capture-smoke` supply those
guards and linkage. Running it remains separate acceptance work; syntax and
deterministic peer tests do not establish native pixel success.

The positive case starts at CSS scroll Y=550 in a 2400-CSS-pixel document with
three 800-CSS-pixel color bands. The fixture checks actual layout coordinates
against CSS coordinates multiplied by backing scale and page zoom: at Retina 2x,
the document is 4800 layout/raster pixels high. Its owned 900x400-point window
keeps the lazy sentinel outside the default loading margin without exceeding
the unchanged raster budgets. It decodes the returned PNG and checks top, middle
and bottom probes against those bands. It compares actual viewport pixels before
and after, plus owned page reports of document/layout/viewport dimensions, scroll,
focus, selection, device/pinch scale and resize/scroll event counts.

Additional owned native cases require horizontal 1200-CSS-pixel overflow with a
fractional scroll request; fixed/sticky black markers at their actual document
position without duplication; and 125% zoom with exact layout raster height,
reported zoom and preserved root viewport/device scale. Pixel, scroll and
fixed/sticky marker coordinates all use CSS-to-layout scale, independently of
the declared one-raster-pixel-per-layout-pixel output scale. At 2x backing and
125% page zoom, the CSS-to-layout factor is 2.5 and raster height is 6000. Canvas 2D, active CSS
opacity animation and existing child-frame pages must return whole-result
unsupported and preserve state/viewport. Canvas/video/embedded objects, filters
and current compositable animations are rejected during layout preflight because
their resource/fidelity semantics are outside this initial policy. Fixed/sticky
positioning has no blanket rejection: the actual composition must pass.

The lazy case keeps its sentinel far below the viewport and checks the server's
request counter stays zero. Capture must not fetch it. The loading case holds a
fixed empty async script, starts from DOMContentLoaded while the native page is
still loading, verifies captured loading metadata and unchanged state/pixels, then
releases the owned hold. No arbitrary script is evaluated. All cases are prepared
inputs; none has run against a built candidate yet. Negative document overflow,
non-default pinch rejection, animated image/protected media behavior and late
encoder-stage cancellation still need additional native runtime coverage.

Negative cases verify fresh recording-budget rejection followed by ordinary
compositor repaint, immediate cancellation plus busy-until-drained behavior,
navigation invalidation, frame-tree mutation after inspection and dimension-limit
rejection before recording. A prototype-only before-record continuation makes
frame mutation deterministic without arbitrary script evaluation. Releasing it
still revalidates the current document and frame tree. The HTTP fixture accepts
only fixed routes, UUID run identifiers, bounded value-free evidence and one
fixed add-frame command; it cannot fetch profile files or another page's state.
Success requires every phase and named variant marker in the smoke runner,
ending in `ARX_DOCUMENT_CAPTURE_SMOKE_VERIFIED`. The fixture and its patched recording dependencies pass isolated syntax;
no built-prototype pixel run has occurred.


Alpha-only paint groups retain Chromium/Skia isolation semantics. They are not
collapsed to plain saves, including at alpha 1. The browser's dedicated composite
request supplies the original absolute deadline and validated output dimensions;
ordinary Paint Preview requests retain their existing path. Before every actual
N32 pixel allocation, a capture-only `SkRasterHandleAllocator` checks the requested
dimensions independently of paint bounds hints. The base is at most 16M pixels
(64 MiB); simultaneous additional layers total at most 64 MiB with at most eight
live layers. Each surface is no larger in either dimension than the base. The
resulting base-plus-layer pixel bound is 128 MiB, separate from existing record,
image-decoding, PNG, and IPC limits. All byte arithmetic is checked before a
fallible zeroed `base::UncheckedCalloc` allocation, paired with `UncheckedFree`
so Chromium's normal OOM-termination shim cannot turn a refused pixel allocation
into a crash. Release callbacks retain/account the base until the
returned bitmap releases it, even after the canvas is destroyed.

A layer budget failure, allocation failure, or cooperative playback deadline is
sticky and rejects the whole bitmap before publication. Skia's silent NoPixels
fallback cannot publish partial pixels after a refused allocation. Playback
unwinds saves before inspecting status. Filters, arbitrary layer paint,
backdrops, and active compositable animations remain unsupported. Skia's abort
callback and allocator boundaries are cooperative: they do not preempt an
individual font/path/backend operation, and this is not a renderer/process-RSS
bound. The explicit owned fixture executes actual Skia alpha-group pixels,
base/layer release, refused allocation after base ownership, depth/aggregate
rejection and timeout checks before the document cases.

After recording rejection, the ordinary repaint check binds the same primary
WeakDocumentPtr, requires unchanged fixture state except its repaint flag, then
waits for renderer visual submission and observes Viz pixels for at most one
second/twenty copies. A late/missing frame, changed source, invalid red baseline
or missing cyan samples fails; timeout never counts as a successful repaint.
First/final bounded numeric RGB diagnostics distinguish pipeline lag from an
incorrect ordinary repaint.

Viewport repaint probes compare opaque colors after explicit sRGB conversion
with a fixed maximum error of two encoded 8-bit steps per RGB channel. Every
probe must pass and alpha must equal 255; there is no average-error allowance.
This addresses GPU/display-compositor conversion quantization (the actual owned
readback returned cyan `ff02ffff`). Unchanged red, partial updates, missing alpha
and errors beyond 2 LSB still fail. This tolerance applies only to repaint
readback, not full-document PNG color checks or unchanged-viewport equality.

The browser rejects an already-present child-frame tree as unsupported before
creating capture work. A tree change after single-frame admission remains a
changed-document failure. Both preserve an empty PNG result. Fixture drain
probes distinguish unsupported existing frames from a busy physical slot.
