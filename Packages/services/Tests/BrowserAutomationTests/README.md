# BrowserAutomationTests

These suites call the automation boundary's types directly and never resolve a dependency context or `@Shared` value, so they don't need `@Suite(.dependencies)` yet. A suite that starts using dependencies, a store or `@Shared` takes it (DEV-970): without it, every test in the process shares one set of dependency test values.

Tests the authenticated local automation boundary, deterministic filtered inventory, explicit command schema, conservative URL projection, stale-session and revocation behavior, and bounded framing. `make test` runs deterministic service tests. `make test-mcp` additionally builds the real helper and runs official Swift/Python SDK clients in separate processes against a temporary synthetic IPC host.

Queued-response regressions change enabled state, client membership, credential digest, read access, scopes and grant revision before a completed response reaches the host. They verify failure before asynchronous revoke/stop runs, and fail-closed behavior when the live application callback is missing or rejects the result. Protocol fixtures explicitly authorize their synthetic responses.

Transport regressions exercise 24 simultaneous local clients, cancellation during a pending exchange, a late reply after a real socket peer closes, and writing to a closed stdio reader. They run concurrently with grant-revocation tests to expose cooperative-executor starvation. Stopping the host must either return a disabled failure or close the connection; no successful content may survive.

Folder-move coverage binds inventory revisions to ordered topology and ownership while ignoring navigation/disclosure, requires explicit destination revisions in the tool parser, and sends `moveFolder` through both real SDK/helper/IPC fixtures to confirm the read-only host denies it after protocol delivery. Application reducer tests separately exercise approved execution and Undo.

Screenshot tests cover backward-compatible disabled grants, finite bounded region parsing, screenshot-only epoch revision changes, one image content block, metadata agreement and exact IPC/MCP output limits. Held host replies are denied after grant/document changes; a PNG within its byte budget can still be rejected when escaped JSON exceeds the transport frame. Swift and Python process clients independently decode a real PNG returned by a synthetic authenticated host.

Inspection tests cover absent-field grant defaults, explicit schema/limit rejection, canonical historical versions and node topology, UTF-8 limits, escaped JSON expansion, metadata-only revision stability, and exact final IPC release after document/grant changes. Both real SDK clients read the synthetic semantic response through the bundled helper, preserving its untrusted-data envelope and withholding the trusted scope UUID. These tests do not establish native renderer semantics.

Inventory projection regressions cover exact-tab grants in excluded folders/spaces: ancestry IDs and names are absent, hidden moves preserve public revisions/cursors, an ungranted location revokes the tab, and full-space grants retain parent metadata and stale-move revisions.

Click tests cover backward-compatible default-off permission, strict explicit-target schema, host pre/post-submission cancellation, deadline/revoke/late-response outcomes, and oversized MCP envelopes that must never update latest-released snapshots.

Wait protocol tests enforce explicit target/condition, bounded deadlines, rejection of content/mutation predicates, honest stopped/error metadata and lossless decimal epochs. Held IPC replies recheck grants/source validity and cannot escape cancellation or disconnect. The independent Swift/Python MCP clients exercise the wait tool through the real helper against a synthetic IPC host.

Form tests exercise exact empty/Unicode schemas, byte/character limits, canonical payload binding, value-free receipts, and actual local socket cancellation/revocation/timeout delivery before and after submission. Known unchanged plus late stale/cancel/timeout failures remain unchanged. Tool-list fixtures include both bounded form tools; native website effects require the separate signed fixture.

Scroll schema tests cover exact keys, finite fractional/integer deltas, signed-zero digest equality and cross-action binding. Authenticated host tests exercise before/after-submit cancellation, timeout/revocation/grant changes, wrong submission-family calls and precise unchanged receipts. Both actual SDK clients list all nine tools and forward explicit browser_scroll to the permission-denying host; synthetic exchange does not prove native scrolling.

Keypress schema tests require an exact key and explicit reference target; they
reject missing fields, modifiers/focus/code/repeat/value additions, controls,
multi-scalar strings and unsupported named shortcuts before exchange.

AutomationPresentationTests cover strict foreground/source/handle schema admission, rejection of host fields on other commands, request binding, value-free `presentations`/`presentation` MCP payloads and decoding of older inventories without presentations. They introduce no new MCP tool name or native API.

`AutomationSettingsTests.sitePermissionsAndZoomParse` (DEV-716) covers `setSitePermission` and `setSiteZoom` arguments: origins and hosts normalized, defaults without an origin or host, null removals, refused values (pop-ups ask, a default allow, bad origins, unknown settings, zoom out of range) and both sections requiring a profile.

`AutomationToolListingTests` (DEV-1021) cover the core listing: Claude Code (or `ARX_MCP_TOOLS=core`) starts with the core tools and `browser_more_tools`, other clients with every tool; every tool is core or in exactly one group; the core listing is under a third of the full one and keeps every argument, describes each core tool more briefly, keeps the focused-tab note and still follows the grant; `browser_more_tools` names every group, adds groups only within the grant, reports the ones the grant doesn't cover, changes nothing the second time or on a full listing, and rejects unknown groups. `MCPInteropTests.claudeCodeStartsWithTheCoreToolsAndAddsGroups` checks the same through the real helper, with `list_changed` after the call.
