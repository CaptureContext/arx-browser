# MCP interoperability fixtures

`make test-mcp` builds the real `ArxMCP` helper, runs it against an authenticated temporary Unix-socket host, and exercises both the official Swift MCP SDK 0.12.1 client and Python MCP SDK 1.26.0 client. The fixture credentials are synthetic and never access the user's browser workspace. Tests assert protocol negotiation, tools/schema, structured inventory, filtered pagination, URL sanitation, management denial, grant changes reaching the client as `tools/list_changed` without reconnecting, the focused-tab alias, the split organization tools, batch partial failure, act-and-observe snapshots, resource subscriptions filtered by grant and ended by revocation, bounded PNG screenshot/image metadata delivery, stdout discipline, and clean shutdown. Normal `make test` also runs the transport, authorization, inventory and TCA tests; the two process fixtures require `test-mcp`.

Set `MCP_PYTHON` to a Python 3.10+ executable. Dependencies are installed into the ignored `build/mcp-venv` folder. Python is a test dependency only; the bundled helper is native Swift.

Set `MCP_HELPER` to an already built `Arx.app/Contents/Helpers/ArxMCP` to run both protocol clients against the actual embedded binary. App builds also fail if this executable is missing.

The independent Python SDK client also verifies `browser_inspect` through actual bundled stdio and authenticated IPC: explicit revision, historical DOM metadata, untrusted text, coverage omissions and no exposed trusted scope UUID. Native page inspection acceptance is a separate signed runtime gate.

The protocol tool-list contract includes `browser_click`. Actual page interaction requires the separate permission, approval and native atomic reference-click capability; synthetic helper tests are not native website-action acceptance.

The SDK tool inventory includes browser_replace_text and browser_select_value, bounded reference actions requiring the existing explicit interaction/content/read/management grants and mutation approval. They do not provide typing, keyboard emulation, autofill or arbitrary JavaScript. The shared operation ID budget prevents replay across click and form kinds; supplied values are absent from receipts and activity.

Both SDK inventories retain all earlier tools and add browser_scroll. The owned clients pass explicit reference/axis/delta arguments and require the authenticated app-side denial; no unsupported schema fallback is accepted. Native helper acceptance is a separate gate.

Both independent SDK clients include browser_keypress and require authenticated app-side denial from the read-only synthetic host, without echoing the key. The signed app helper checks the same eleven-tool inventory. These transport checks do not replace the native guarded-key fixture.

Both SDK inventories also list browser_sign_in. The clients send a well-formed begin request and require the authenticated app-side denial from the synthetic host; credential-shaped arguments are rejected by the schema. Trusted user consent, the privacy lock and secret exclusion are proven separately by `make sign-in-smoke` in the signed app.

Both SDK clients check that `browser_command` advertises the boolean `route` opt-in and that a routed `openTab` reaches the app, which denies it on the read-only synthetic host. Rule matching, fallback and Little Arx routing are covered by AppFeature tests.
