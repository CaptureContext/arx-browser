# arx-features
Browser screens, state, and application composition. Requires macOS 27 or later and Swift 6.4.
## Boundaries

May depend on core, engine, services, design-system, dependencies, extensions, and lower-level features. Lower layers must not import this package.
## Targets

- [AppFeature](Sources/AppFeature/README.md)
- [ChatFeature](Sources/ChatFeature/README.md): the built-in assistant's per-profile chats, panel and chat settings.
- [CommandBarFeature](Sources/CommandBarFeature/README.md)
- [DownloadsFeature](Sources/DownloadsFeature/README.md): the service-owned queue, with ordinary-profile and separate private-transfer filters.
- [ExtensionsFeature](Sources/ExtensionsFeature/README.md): per-profile existing-extension management behind runtime capability.
- [FeedbackFeature](Sources/FeedbackFeature/README.md): Help › Report a Problem…, sent to the feedback relay or saved to a file.
- [HistoryFeature](Sources/HistoryFeature/README.md): the Library's History page, by day with search and deletion, over the profile's history.
- [LiveFolderFeature](Sources/LiveFolderFeature/README.md): live folders' refreshes and badges, not yet in the sidebar (DEV-926).
- [LittleArxFeature](Sources/LittleArxFeature/README.md)
- [MainFeature](Sources/MainFeature/README.md)
- [MediaFeature](Sources/MediaFeature/README.md): media state and commands behind the native capability boundary.
- [MigrationAssistantFeature](Sources/MigrationAssistantFeature/README.md): import selection, preview, progress, cancellation, results and retry over MigrationAssistant.
- [OnboardingFeature](Sources/OnboardingFeature/README.md): the placeholder setup window; AppFeature owns presentation and dismissal persistence.
- [OutsideAgentsFeature](Sources/OutsideAgentsFeature/README.md): the `arx` command, the MCP switch and agent apps, shared by onboarding and Settings.
- [PageCaptureFeature](Sources/PageCaptureFeature/README.md): frozen viewport/region selection, preview and local export.
- [PeekFeature](Sources/PeekFeature/README.md)
- [SettingsFeature](Sources/SettingsFeature/README.md)
- [SidebarFeature](Sources/SidebarFeature/README.md)
- [TabArchiveFeature](Sources/TabArchiveFeature/README.md)
- [ViewerFeature](Sources/ViewerFeature/README.md)
- [ViewerItemFeature](Sources/ViewerItemFeature/README.md)
- [ChatFeatureTests](Tests/ChatFeatureTests/README.md)
- [DownloadsFeatureTests](Tests/DownloadsFeatureTests/README.md)
- [ExtensionsFeatureTests](Tests/ExtensionsFeatureTests/README.md)
- [HistoryFeatureTests](Tests/HistoryFeatureTests/README.md)
- [IntegrationFeatureTests](Tests/IntegrationFeatureTests/README.md)
- [LiveFolderFeatureTests](Tests/LiveFolderFeatureTests/README.md)
- [MediaFeatureTests](Tests/MediaFeatureTests/README.md)
- [MigrationAssistantFeatureTests](Tests/MigrationAssistantFeatureTests/README.md)
- [OnboardingFeatureTests](Tests/OnboardingFeatureTests/README.md)
- [PageCaptureFeatureTests](Tests/PageCaptureFeatureTests/README.md)

New targets belong in this role-based package and require a target README.

Reference scroll joins existing MCP approval and receipt lifecycle without introducing implicit focus or a new grant. Its native availability is separately gated.


The explicit `external-consent-smoke` DEBUG mode uses the actual Main page and
native events with a disposable unique protocol handler. It requires real Chrome
modal visibility and exact native operation/drain receipts without publishing an
external tab. Native startup separately validates the one-use fixture root and
suppresses every final OS launch. Ordinary startup and ordinary `app-smoke` retain
their existing Keychain policy.

External-consent fixture admission reads and validates the exact argv root,
explicit profile, private directory/token metadata and running application inode
before enabling mock Keychain or constructing any workspace/window. Missing or
malformed fixture inputs fail startup without the ordinary profile fallback;
Release builds refuse this fixture mode.
