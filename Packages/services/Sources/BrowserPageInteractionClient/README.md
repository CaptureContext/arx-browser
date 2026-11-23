# BrowserPageInteractionClient

Explicit, nonthrowing reference-scoped interaction dependency. Defaults are unavailable. The app supplies a previously released inspection snapshot and a separate interaction grant plus mutation approval; read permission and a reference alone never authorize an action.

The native adapter must validate the exact document, DOM version, retained node, scope and latest snapshot in the same renderer task as dispatch. The final authorization callback runs synchronously immediately before native submission. Cancellation or timeout after submission may report `possiblyDispatched`; `dispatched` means event initiation, never navigation completion or website success. The click surface provides no automatic replay, focus, typing or raw JavaScript. Form and scroll actions use the separate bounded closures below.

The same dependency also exposes separately queried form availability and formAuthorized. Whole text replacement and exact single-select values use ordinary form availability; guarded keypress is separately gated below. IME/paste/autofill remain unsupported. The mandatory authorization closure marks the final synchronous native-submission boundary. An unchanged receipt may carry a later cancellation/stale/timeout failure without becoming an unknown effect. Default implementations remain unavailable. No values appear in result types.

The separately gated scroll closure requests an instant offset on the nearest native user-scrollable container of an explicit inspection reference. It defaults unavailable, requires the same final synchronous authorization callback, and preserves dispatched/possiblyDispatched/unchanged outcomes across later cancellation or navigation. No focus, wheel-input, scroll chaining or website-success contract is implied.

The staged guarded `keyPress` form kind has independent `keypressIsAvailable`
(default false) and requires the ordinary form action boundary. It retains all
explicit source and final authorization checks. It never provides implicit
focus, modifiers, IME or arbitrary keyboard input; native same-task control and
selection checks govern each default edit after author handlers.

Pointer input (hover, pointer clicks and drags) uses the form path with `AutomationFormRequest` pointer kinds and an `AutomationPointer`; it is available whenever form actions are, because it shares the exact-version ABI27 form entry point.
