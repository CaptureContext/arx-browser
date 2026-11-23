# arx-dependencies
Project-owned wrappers around external libraries. Requires macOS 27 or later and Swift 6.4.
## Boundaries

May depend on extensions and selected external libraries. Must not depend on browser domain, services, design-system, or features.
## Targets
- [_CocoaNavigation](Sources/_CocoaNavigation/README.md)
- [_CommandLine](Sources/_CommandLine/README.md)
- [_ComposableArchitecture](Sources/_ComposableArchitecture/README.md)
- [_ConcurrencyExtras](Sources/_ConcurrencyExtras/README.md)
- [_Dependencies](Sources/_Dependencies/README.md)
- [_IssueReporting](Sources/_IssueReporting/README.md)
- [_PackageResources](Sources/_PackageResources/README.md)
- [_Perception](Sources/_Perception/README.md)
- [_SQLiteData](Sources/_SQLiteData/README.md)
- [_SharingExtensions](Sources/_SharingExtensions/README.md)
- [_Sparkle](Sources/_Sparkle/README.md)
- [_TestSupport](Sources/_TestSupport/README.md)
- [_URLRouting](Sources/_URLRouting/README.md)

Selected targets are wrappers only. See the project dependency selection record for fork and transitive-dependency policies.

`_MCP` wraps the pinned official Swift MCP SDK and its logger types for the native helper; domain and feature targets do not import the SDK.
