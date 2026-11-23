# arx-services
Browser clients, persistence, and operating-system integration. Requires macOS 27 or later and Swift 6.4.
## Boundaries

May depend on core, engine, dependencies, and extensions. BrowserSurfaceClient isolates AppKit/SwiftUI hosting from engine commands. Must not depend on features or presentation components.
## Targets

- [AgentClient](Sources/AgentClient/README.md): provider-neutral agent contracts, per-profile conversation storage, prompt guidance, event batching and provider processes.
- [AgentToolsClient](Sources/AgentToolsClient/README.md): installs the `arx` command and adds Arx to agent apps' MCP configuration.
- [AppRelocationClient](Sources/AppRelocationClient/README.md): moves Arx to Applications when it's opened from the disk image or a translocated location.
- [AppLinkClient](Sources/AppLinkClient/README.md): runs an App Links handler's script with the link as `$1`, opens a link in the app macOS assigns or one chosen by path, lists apps for the picker, and copies links (DEV-857, DEV-862).
- [AppUpdaterClient](Sources/AppUpdaterClient/README.md): Sparkle updates from GitHub Releases, off unless the build is configured and signed.
- [ArxCommandLine](Sources/ArxCommandLine/README.md): the `arx` command.
- [BrowserAutomationClient](Sources/BrowserAutomationClient/README.md): authenticated Unix IPC and scoped metadata projection.
- [BrowserCaptureClient](Sources/BrowserCaptureClient/README.md): bounded viewport-capture boundary, frozen-image crop and local image export.
- [BrowserDownloadsClient](Sources/BrowserDownloadsClient/README.md)
- [BrowserEngineClient](Sources/BrowserEngineClient/README.md)
- [BrowserExtensionsClient](Sources/BrowserExtensionsClient/README.md): capability-gated ordinary-profile extension inventory and management.
- [BrowserHistoryClient](Sources/BrowserHistoryClient/README.md)
- [BrowserMCPServer](Sources/BrowserMCPServer/README.md): the bundled SDK-backed stdio server.
- [BrowserMediaClient](Sources/BrowserMediaClient/README.md)
- [BrowserPageInspectionClient](Sources/BrowserPageInspectionClient/README.md): fail-closed historical semantic page reads with live document/scope checks.
- [BrowserSurfaceClient](Sources/BrowserSurfaceClient/README.md)
- [BrowserWorkspaceClient](Sources/BrowserWorkspaceClient/README.md): the workspace file, its in-memory document and the shared preference keys.
- [ChromiumBrowserEngine](Sources/ChromiumBrowserEngine/README.md)
- [ClaudeAgentClient](Sources/ClaudeAgentClient/README.md): Claude through the person's own signed-in, unmodified Claude Code, with Arx's MCP tools as its only tools.
- [CodexAgentClient](Sources/CodexAgentClient/README.md): ChatGPT through the person's own signed-in, unmodified Codex CLI, with Arx's MCP tools as its only working tools.
- [DefaultBrowserClient](Sources/DefaultBrowserClient/README.md): reads whether Arx is the default browser and asks macOS to make it so.
- [MemberNumberClient](Sources/MemberNumberClient/README.md): signs in with Apple and claims the identity card's member number from Arx's server, kept per Mac (DEV-701).
- [MemoryPressureClient](Sources/MemoryPressureClient/README.md): the system's memory pressure, from the same macOS source Chromium reads, for unloading idle tabs (DEV-873).
- [DiagnosticsClient](Sources/DiagnosticsClient/README.md): crash reports reduced to what may leave the Mac, kept locally and sent only with consent, and Report a Problem's relay contract.
- [FairPlayBridge](Sources/FairPlayBridge/README.md): FairPlay in Chromium tabs, the app's side: the page script and the pairing of a Spotify tab with Arx's FairPlay helper (DEV-1144).
- [FairPlayPlayer](Sources/FairPlayPlayer/README.md): the FairPlay helper app's player, Now Playing and media keys (DEV-1144).
- [FairPlayProtocol](Sources/FairPlayProtocol/README.md): the bounded messages between page, app and helper (DEV-1144).
- [LiveFolderClient](Sources/LiveFolderClient/README.md): live folders' items from their sources (GitHub pull requests first), behind an account seam that holds none yet.
- [MigrationAssistant](Sources/MigrationAssistant/README.md): import discovery, preview, staged execution, cancellation and reports. No source adapters yet.
- [PageTranslationClient](Sources/PageTranslationClient/README.md): page translation on this Mac with Apple's Translation framework (DEV-904).
- [SearchSuggestionsClient](Sources/SearchSuggestionsClient/README.md): Search suggestions from the profile's provider for the command bar, without cookies.
- [SoundFeedbackClient](Sources/SoundFeedbackClient/README.md): Arx's three interface sounds (capture, done, could not), played as macOS interface sounds when Sound feedback is on and nothing else is using sound (DEV-1256).
- [WebKitBrowserEngine](Sources/WebKitBrowserEngine/README.md): WebKit pages for protected video and music, behind the app's engine client (DEV-877).
- [AgentTests](Tests/AgentTests/README.md)
- [AgentToolsTests](Tests/AgentToolsTests/README.md)
- [AppRelocationTests](Tests/AppRelocationTests/README.md)
- [AppUpdaterTests](Tests/AppUpdaterTests/README.md)
- [BrowserAutomationTests](Tests/BrowserAutomationTests/README.md)
- [BrowserCaptureTests](Tests/BrowserCaptureTests/README.md)
- [BrowserHistoryTests](Tests/BrowserHistoryTests/README.md)
- [BrowserPagePreviewTests](Tests/BrowserPagePreviewTests/README.md)
- [BrowserSiteIconTests](Tests/BrowserSiteIconTests/README.md)
- [BrowserWorkspaceClientTests](Tests/BrowserWorkspaceClientTests/README.md)
- [DefaultBrowserTests](Tests/DefaultBrowserTests/README.md)
- [DiagnosticsTests](Tests/DiagnosticsTests/README.md)
- [FairPlayBridgeTests](Tests/FairPlayBridgeTests/README.md)
- [LiveFolderTests](Tests/LiveFolderTests/README.md)
- [MemberNumberTests](Tests/MemberNumberTests/README.md)
- [MigrationAssistantTests](Tests/MigrationAssistantTests/README.md)
- [PageTranslationTests](Tests/PageTranslationTests/README.md)
- [SearchSuggestionsTests](Tests/SearchSuggestionsTests/README.md)
- [SoundFeedbackTests](Tests/SoundFeedbackTests/README.md)
- [WebKitBrowserEngineTests](Tests/WebKitBrowserEngineTests/README.md)

New targets belong in this role-based package and require a target README.

- [BrowserPagePreviewClient](Sources/BrowserPagePreviewClient/README.md): per-profile saved pictures of pages for hover cards, and Open Graph details for pages that aren't loaded, without cookies (DEV-730) or with the profile's cookies for the page's own host only (DEV-1142).
- [BrowserSiteIconClient](Sources/BrowserSiteIconClient/README.md): profile-scoped site icon streams with synchronous membership revocation, and `BrowserSiteIconStore`, the per-profile icon cache that survives relaunches.

`BrowserPageInteractionClient` is the independently gated, nonthrowing reference-action boundary for accessibility clicks, bounded text replacement and exact single-select values; read-only inspection does not authorize it.

`BrowserPageWaitClient` provides bounded, authorized loading observations for an already-loaded ordinary session. Chromium owns page/epoch validation and event subscription cleanup; the automation feature owns grants and final delivery.

Reference scrolling uses the existing page-interaction client and the same authenticated host, approval, shared operation-ID budget and non-replay receipts as click/form actions. No additional package or transport is introduced.
