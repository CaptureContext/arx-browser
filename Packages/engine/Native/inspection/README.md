# Semantic inspection boundary

ABI11 inspects only an already loaded, ordinary HTTP(S) HTML main document. The
browser neither navigates nor focuses it. Private, error, privileged, unloaded
and child documents are refused. The renderer builds a one-time local AX tree
and projects it before IPC; the browser's renumbered cross-frame snapshot and
delayed AX events are never reference authority.

The result is historical semantic accessibility data, not exact visible text or
a complete DOM. Main-document author shadow content follows Blink's flattened
semantics. All subframes (including same-origin, cross-origin and fenced frames),
canvas pixels, generated/unresolvable text, computed names, form values and
password subtrees are declared omissions. The omission list describes policy,
not the presence or count of excluded content. Only connected DOM-backed static
text outside shadow-including form-control, editable, UA-shadow and canvas
ancestry is copied. Names must exactly equal the same node's explicit aria-label,
alt or title attribute; a name-source enum alone cannot exclude embedded input
values or appended file descriptions. Actual and former-password controls and
AX-protected subtrees are wholly omitted regardless of masking settings. No
value, description, HTML attribute dictionary or raw DOM is returned. Page text
and labels remain untrusted website data.

The exported `blink::DomTreeVersionForArxInspection` function reads the pinned
Document's mutation version without changing WebDocument's public layout or
broadly included header. Document token and DOM version are checked in the same
renderer task before/after snapshot and projection. References use random opaque
tokens bound to a client/grant scope, main frame, document, snapshot nonce and
DOM version. Strong WebNode handles and `FromDomNodeId(id) == retained_node`
prevent recycled integer IDs from resolving to replacement nodes. Every later
resolution checks the current renderer revision, connection and same document.
Any DOM mutation conservatively invalidates the snapshot. This is a read-only
validation seam: it must never authorize a later separately scheduled action.
Form property, CSS, animation or selection changes are not all DOM mutations;
future actions require their own same-task eligibility check and dispatch.

Output is fail-closed at 512 nodes, 64 KiB aggregate UTF-8 text, 4096 bytes per
string, 256 references and 256 KiB serialized JSON. Smaller caller budgets are
honored. Escaping and fixed structural overhead are reserved before constructing
output. Snapshot error flags or soft-budget overflow reject the entire result.
Blink's initial AX work still uses its documented soft node/time limits; these
are hard output/IPC/retained-handle bounds, not a hard pre-allocation cap for
Blink's temporary AX cache. Timeout is at most 2 seconds.

Whole-browser admission reserves at most 16 snapshots (four per page), at most
4096 retained handles, and 16 physical requests. Each renderer independently
enforces the same snapshot/handle cap. References expire after 30 seconds and
are cleared on receiver disconnection, document replacement, page close,
navigation/deactivation, scope revocation and shutdown. Logical cancellation or
timeout replies promptly but holds the physical reservation until callback or
disconnect. A frame entering the back/forward cache counts as disconnected
(DEV-943): its pipe, work and reservations are dropped at once, since its
renderer frame stays alive, and a restored document binds a fresh pipe with no
snapshots. Forget is sent at most once per snapshot, including repeated expiry
of a hung request. Browser and Swift release recheck native document/page/scope;
they do not pretend a browser-side synchronous query can observe a newer DOM
mutation before renderer IPC arrives.

Compiled ASan/UBSan policy tests execute production ancestry/name, reference and
retirement code. Swift tests cover scope/page lifetime, queued callbacks,
cancellation, parser budgets and native failures. Isolated syntax checks compile
the renderer, browser bridge, engine table, Blink export and Chrome renderer
registration against the pinned generated headers. Unit and syntax checks alone
do not establish actual-page acceptance. The owned native fixture gate must cover
direct/derived password labels, UA/author shadow ancestry, subframes,
canvas, same-document replacement/remove-reinsert before AX delivery, scope
isolation, navigation/reload/BFCache invalidation, expiry and output rejection.

ABI25 lifts the whole-page node cap into windows. The renderer snapshots up to
16384 AX nodes, projects them in one fixed order, and emits only projected
indices in `[window_start, window_start + nodes)`. Parents keep their global
index; text, output and reference budgets apply to the window. Every window of
one DOM version therefore concatenates without overlap. Child frames are read
by their own Inspector: the browser selects the frame, and the renderer no
longer refuses non-main frames. Opt-in form values read only the control's own
value or checked state outside password ancestry, never file, hidden or
payment/one-time autocomplete fields, and drop `formValues` from the omission
list. Opt-in bounds are `BlinkSpaceToEnclosedDIPs(BoundsInWidget())` for
same-widget frames only.

ABI12 adds one accessibility-style reference click. Browser and renderer admit
only the latest created snapshot for the exact scope/page; a newer read retires
older references even when that read fails or is never released. App permission
code additionally requires the latest snapshot actually released to its client.
The retained node, main document, DOM version, scope and snapshot are checked in
one renderer task, including after target layout and immediately before the
first event. Password/former-password ancestry, file inputs, disabled, inert,
hidden, fully transparent and empty-layout targets are rejected. No transient
user activation, app/window activation, explicit scrolling or explicit focus is
added. Website event handlers/default actions may themselves focus, scroll,
navigate, submit a form or cause other effects; generic clicks require approval.

The browser retains at most 4096 operation receipts for the runtime lifetime,
with at most 256 per trusted scope. Receipts are never evicted on expiry, page
closure, scope revocation or reconnect. Exhaustion fails closed and requires a
new runtime; a new grant or connection does not reset the global capacity. An
identically bound duplicate returns its recorded disposition without dispatch;
a differently bound duplicate returns only uncertainty. At most one physical
click per page and 16 globally remain admitted until renderer callback or pipe
disconnection, including after logical cancellation/timeout. A late renderer
reply can refine the retained receipt but never dispatch or complete twice.

`dispatched` means the event sequence was initiated, not that the website
accepted it or navigation completed. Once renderer IPC is sent, cancellation,
revocation, timeout or document loss is `possiblyDispatched` unless a renderer
reply already established a more precise disposition. The Swift/app layers must
retain that uncertainty and recheck current grants before exposing page state.
No automatic replay or undo of website effects is promised. The actual native
fixture must establish owned-page dispatch, stale/duplicate refusal, privacy,
no transient activation and no app window activation; extracted policy/syntax
checks alone do not establish that acceptance.

ABI13 adds `replaceText` for text/search inputs and textareas, and `selectValue`
for a traditional single native select. It uses the same receipt ledger, latest
snapshot rule and physical queue as clicks: switching action kinds cannot replay
an operation or admit overlapping work. The receipt binding includes the action
kind and a domain-separated, length-prefixed SHA-256 payload digest. Receipts and
logs never retain supplied values. The request's bounded bytes exist only while
executing or awaiting renderer IPC.

Each retained eligible control has a renderer-only fixed SHA-256 baseline of its
current value/option state, control kind, disabled/readonly state, maximum length
and text selection metadata. Cached string lengths are checked before scanning
or conversion. Traditional select traversal is capped at 1024 visited nodes,
512 options, 4096 UTF-16 units per option value and 32768 aggregate UTF-16 units
for option values and separately for descendant text. Unsupported controls and
oversized eligible baselines are distinct failures. Values and baseline hashes
are never added to the inspection response. Actual/former-password, file and
editable ancestry remain excluded, including shadow hosts.

Dispatch validates retained node/document/DOM version, eligibility and the exact
original baseline in one renderer task, after layout. Property-only changes to
value, selection, control type, readonly/disabled state, maxlength or option
selection/value therefore stale the operation even when the requested value now
matches. Matched options and optgroups must be enabled, lack `hidden`, and have
non-hidden, nontransparent computed style. Resolving their lazy style is followed
by a final control lifecycle update and another authority, baseline and cached
control/ancestor/option geometry/style check. No popup is opened.

Replacement accepts at most 32768 UTF-8 bytes; exact option values at most 4096.
Empty strings are allowed. NUL is rejected. Text/search inputs reject CR and LF;
textareas accept LF and reject CR. There is no silent newline normalization or
maxlength truncation; maxlength is checked in UTF-16 units. An exact unique option
must exist; duplicate values are ambiguous even if one duplicate is disabled.
Multiple and customizable selects are unsupported.

After every authority/baseline check, an already equal value/selected option
returns `unchanged` without a setter or events and consumes the operation receipt.
Otherwise Blink's exact native setter initiates its input/change event sequence
and returns `dispatched`. This is value replacement, not typing, paste, IME,
autofill, real keyboard input or a promise that website handlers accept the value.
No transient user activation, explicit focus, scroll or app activation is added.
Native setter behavior and site handlers may affect selection, focus, navigation
or later value state. Event handlers can destroy the page; dispatch code does not
inspect the observer or DOM after invoking the setter. Cancellation/timeout after
submission remains `possiblyDispatched` until a more precise native reply arrives.

Compiled policy tests exercise production setter/baseline code with bounded
Blink peers and real SHA-256, including post-layout/property-only edits, stale
node identity, reentrant dispatch, unchanged, hidden options, newline/maxlength
rules and output bounds. Actual native acceptance must use owned HTTP controls
to prove event effects, no granted activation/focus, private/password exclusion,
receipt non-replay and cancellation uncertainty against the matching framework.

## Reference-scoped scrolling

Scroll uses the same one-use receipt ledger and physical admission queue as click
and form actions. Its binding includes action kind 3 and SHA256 of the axis and
canonical IEEE-754 delta (fixed little-endian fields under a distinct domain).
Non-finite values and magnitudes above 8192 CSS pixels are rejected before
serialization/admission; negative zero is canonicalized to positive zero.

The renderer completes layout, checks the retained ordinary main-document
reference and sensitive ancestry, then walks at most 512 containing-block boxes
starting with the reference's enclosing box. It selects the first same-document
box with native user-scrollable overflow and positive extent on the requested
physical axis. Fixed/positioned and slotted content follow Chromium's layout
containment, not a guessed DOM parent or focused element. An already-saturated
container remains the target: residual delta never scrolls an outer container.
Current native offsets are used; snapshot-time user position is not an authority
baseline. Native CSS zoom and minimum/maximum offsets determine the destination.

Final document/version/node/scope checks occur after layout and container
resolution. The helper calls the existing ScrollableArea primitive directly with
instant behavior, without another layout flush, focus, user activation, wheel
synthesis, or script evaluation. A clamped no-op returns `unchanged` without
calling the setter, which could otherwise interrupt animation/scroll markers.
`dispatched` acknowledges the native offset request; scroll handlers, snap,
compositor movement and lazy loading may subsequently alter page state. The
result is deliberately value-free and does not promise website completion.
Cancellation and lifecycle races preserve known dispositions or uncertainty.

The compiled production-helper tests cover bounds, negative/zoomed offsets,
axis-specific containment, saturation without chaining, sensitive ancestors,
reentrant layout, identity replacement and shutdown-safe post-dispatch behavior.
The shared browser queue tests exercise scroll/form overlap, timeout retention,
late unchanged receipts and posted-delivery invalidation. Syntax/unit checks do
not establish actual-page acceptance; the owned fixture must verify native
movement, clamping, no residual chaining, and no focus/window activation.

## Pointer input (ABI27)

Hover, pointer clicks and drags share the form action entry point, receipts and
physical admission, as kinds 8, 16 and 32. The payload is canonical ASCII
`key=value;` fields in a fixed order (`pointer_policy.h`), parsed by both the
browser and the renderer; anything else is `invalidValue`. Points are viewport
points of the main frame's widget. A point needs the snapshot's own ID as its
reference and is refused for out-of-process frames, whose widget has its own
space. A real reference never takes a point.

The renderer validates scope, snapshot lifetime, document, retained handles and
DOM version, lays out, resolves the reference's visible centre and hit-tests it
with child frame content. The hit node must be the reference or a
shadow-including descendant; for a point it must belong to the snapshot's
document. Password ancestry, file and color inputs, selects and labels of those
controls are refused. Mouse events then go through `WebWidget::HandleInputEvent`
of the frame's local root, so Blink's own event handling, hover state, pointer
events and user activation apply. Between events only identity is rechecked:
website handlers may legitimately mutate the DOM once input has begun, and a lost
identity returns `possiblyDispatched`.

`WebFrameWidgetImpl::StartDragging` hands a drag to an active pointer action
instead of the browser. The action then drives `DragTargetDragEnter`, `Over`,
`Drop` or `Leave` and `DragSourceEndedAt` itself, so drag and drop completes in
the renderer and no platform drag session starts.

DEV-669: hover is non-consuming. The browser keeps a snapshot after a hover that
was dispatched with status OK; every other outcome and every other action kind
forgets it. The renderer still compares the DOM version before each action, so a
hover that mutates the page retires its references. Compiled tests cover the
payload parser and the browser's keep-or-forget rule.

## Keyboard input (ABI28)

Typing (kind 64) and key chords (kind 128) use the `KeyboardAction` Mojo
method. The browser and renderer both bound the payload: typed text is 1–1024
UTF-8 bytes; a chord is `"<modifiers>:<key>"` (`keyboard_policy.h`).

The renderer checks the retained handle and the snapshot's DOM version once,
refuses password ancestry, lays out, and focuses the reference if it isn't
focused. Focus runs author listeners, so from then on a failure is
`possiblyDispatched`. Every later check is identity only, because typing edits
the DOM.

Typing places the caret at the end. Text fields (the controls the ABI17
keypress baseline supports) send each character through
`PerformKeypressForArxInspection` with a baseline captured just before it, so
each key keeps that path's guarantees. A contenteditable root uses the same
`ArxKeypressGuard` hooks directly, with a check that focus stays on the
reference and both selection ends stay inside it and outside password
ancestry. A line feed is Enter and is refused for single-line inputs. No new
Blink hook is added.

A chord on an editable reference with a text or editing key is guarded the same
way. Tab, Escape, Page Up/Down and F1–F12 keep Blink's defaults; so do Enter
and Space on a non-editable control. Other characters on a non-editable
reference, and every chord with Control, Alt or Meta, are dispatched with their
default already handled: page listeners see them, but no clipboard, undo,
editing or access-key default runs. A keypress event is only sent while focus
is still on the reference.

## Explicit form state (ABI29)

Select-values (kind 256) and set-checked (kind 512) use the `FormStateAction`
Mojo method and the shared receipts. The browser bounds the payload; the
renderer parses select values as a JSON array of strings (at most 64, each at
most 4096 UTF-16 units, no duplicates) and checked state as "1" or "0".

The renderer checks the retained handle against the snapshot's DOM version,
then in one task refuses password ancestry, disabled and inert controls and
empty layout. Set-checked applies to checkboxes and radios only and can't
uncheck a radio. Select-values applies to a native multiple select; every value
must match exactly one option, and a disabled option can't become selected. An
equal state returns `unchanged` with no event and no setter. Otherwise the
setters run and input and change fire once; nothing is read afterwards.

## Developer scripts (ABI34, DEV-668)

`ScriptRunner` is created with each frame's `Inspector` and has its own
interface (`developer.mojom`), so a script never rebinds or clears inspection
snapshots. `Evaluate` wraps the agent's source as the body of an async function,
compiles it once in the frame's developer world to report a syntax error with
the agent's own line, then runs it through `RequestExecuteScript` in that world
with no user activation and awaits its promise. The value is serialized with
`JSON.stringify` inside the world; text over the requested limit is `kLimit`,
and an exception's name and message are capped at 128 and 2048 bytes. The world
shares the DOM, not the page's JavaScript, and uses the page's origin and CSP.
Credential reads are refused by Blink hooks keyed on the world (see the native
README), not by anything the script could redefine.

`EvaluateTranslation` (ABI57, DEV-996) does the same in Arx's translation world
(`kArxTranslationWorldId`), for the app's page translation scripts only. The
browser sends these for private pages too; the same credential hooks apply.
