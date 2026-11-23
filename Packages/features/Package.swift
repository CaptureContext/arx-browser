// swift-tools-version: 6.4

import PackageDescription

// MARK: - Package

let packageName = "arx-features"
let package = Package(
	name: packageName,
	platforms: [.macOS(.v27)],
	dependencies: [
		.fork("cocoa-aliases"),
		.fork("composable-architecture-extensions"),
		.fork("swift-cocoa-extensions"),
		.fork("swift-composable-architecture"),
		.fork("swift-macro-toolkit"),
		.fork("swift-navigation"),
		.fork("swift-syntax"),
		.core,
		.engine,
		.services,
		.designSystem,
		.dependencies,
	],
	producibleTargets: [

		// MARK: - A

		.target(
			name: "AppFeature",
			product: .library(),
			dependencies: .group(
				.feature("ChatFeature"),
				.feature("DownloadsFeature"),
				.feature("MainFeature"),
				.feature("MediaFeature"),
				.feature("MigrationAssistantFeature"),
				.feature("OnboardingFeature"),
				.feature("OutsideAgentsFeature"),
				.feature("PageCaptureFeature"),
				.feature("LittleArxFeature"),
				.feature("PeekFeature"),
				.feature("FeedbackFeature"),
				.feature("SettingsFeature"),
				.feature("SidebarFeature"),
				.feature("TaskManagerFeature"),
				.feature("ViewerFeature"),
				.feature("ViewerItemFeature"),
				.core("BrowserCore"),
				.engine("ChromiumEngine"),
				.services("AppUpdaterClient"),
				.services("ChromiumBrowserEngine"),
				.services("DefaultBrowserClient"),
				.services("FairPlayBridge"),
				.services("WebKitBrowserEngine"),
				.services("PageTranslationClient"),
				.services("BrowserWorkspaceClient"),
				.services("WorkspaceDatabase"),
				.services("WorkspaceSync"),
				.services("BrowserHistoryClient"),
				.services("HistoryDatabase"),
				.services("PageTextIndexClient"),
				.services("BrowserExtensionsClient"),
				.services("BrowserAutomationClient"),
				.services("BrowserMCPServer"),
				.services("BrowserCaptureClient"),
				.services("BrowserPageInspectionClient"),
				.services("BrowserPageInteractionClient"),
				.services("BrowserPageWaitClient"),
				.dependency("_MCP"),
				.dependency("_IssueReporting"),
				.services("BrowserDownloadsClient"),
				.services("BrowserMediaClient"),
				.services("BrowserEngineClient"),
				.services("BrowserSurfaceClient"),
				.services("BrowserSiteIconClient"),
				.services("BrowserPagePreviewClient"),
				.services("MigrationAssistant"),
				.services("AppRelocationClient"),
				.services("AppLinkClient"),
				.services("MemoryPressureClient"),
				.services("SoundFeedbackClient"),
				.services("MemberNumberClient"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		// MARK: - C

		.target(
			name: "ChatFeature",
			product: .library(),
			dependencies: .group(
				.services("AgentClient"),
				.services("ClaudeAgentClient"),
				.services("CodexAgentClient"),
				.core("BrowserCore"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "CommandBarFeature",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.services("BrowserWorkspaceClient"),
				.services("SearchSuggestionsClient"),
				.services("PageTextIndexClient"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		// MARK: - D

		.target(
			name: "DownloadsFeature",
			product: .library(),
			dependencies: .group(
				.services("BrowserDownloadsClient"),
				.services("SoundFeedbackClient"),
				.core("BrowserCore"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		// MARK: - E

		.target(
			name: "ExtensionsFeature",
			product: .library(),
			dependencies: .group(
				.services("BrowserExtensionsClient"),
				.core("BrowserCore"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		// MARK: - F

		.target(
			name: "FeedbackFeature",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.services("DiagnosticsClient"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		// MARK: - L

		.target(
			name: "LiveFolderFeature",
			product: .library(),
			dependencies: .group(
				.services("LiveFolderClient"),
				.core("BrowserCore"),
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "LittleArxFeature",
			product: .library(),
			dependencies: .group(
				.feature("CommandBarFeature"),
				.feature("ViewerItemFeature"),
				.services("BrowserEngineClient"),
				.services("BrowserWorkspaceClient"),
				.services("BrowserSurfaceClient"),
				.core("BrowserCore"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		// MARK: - H

		.target(
			name: "HistoryFeature",
			product: .library(),
			dependencies: .group(
				.designSystem("AppUI"),
				.core("BrowserCore"),
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		// MARK: - M

		.target(
			name: "MainFeature",
			product: .library(),
			dependencies: .group(
				.feature("SidebarFeature"),
				.services("BrowserWorkspaceClient"),
				.feature("HistoryFeature"),
				.feature("TabArchiveFeature"),
				.feature("CommandBarFeature"),
				.feature("ViewerFeature"),
				.feature("ViewerItemFeature"),
				.core("BrowserCore"),
				.services("BrowserEngineClient"),
				.services("BrowserExtensionsClient"),
				.services("BrowserSurfaceClient"),
				.services("PageTranslationClient"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "MediaFeature",
			product: .library(),
			dependencies: .group(
				.services("BrowserMediaClient"),
				.core("BrowserCore"),
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "MigrationAssistantFeature",
			product: .library(),
			dependencies: .group(
				.feature("ExtensionsFeature"),
				.services("BrowserEngineClient"),
				.services("BrowserExtensionsClient"),
				.services("MigrationAssistant"),
				.core("BrowserCore"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		// MARK: - O

		.target(
			name: "OnboardingFeature",
			product: .library(),
			dependencies: .group(
				.feature("ChatFeature"),
				.feature("ExtensionsFeature"),
				.feature("MigrationAssistantFeature"),
				.feature("OutsideAgentsFeature"),
				.services("MigrationAssistant"),
				.services("DefaultBrowserClient"),
				.services("AgentClient"),
				.services("WorkspaceSync"),
				.core("BrowserCore"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "OutsideAgentsFeature",
			product: .library(),
			dependencies: .group(
				.services("AgentToolsClient"),
				.services("BrowserAutomationClient"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		// MARK: - P

		.target(
			name: "PageCaptureFeature",
			product: .library(),
			dependencies: .group(
				.services("BrowserCaptureClient"),
				.services("BrowserPageInspectionClient"),
				.services("SoundFeedbackClient"),
				.core("BrowserCore"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "PeekFeature",
			product: .library(),
			dependencies: .group(
				.feature("ViewerItemFeature"),
				.core("BrowserCore"),
				.services("BrowserEngineClient"),
				.services("BrowserSurfaceClient"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		// MARK: - S

		.target(
			name: "SettingsFeature",
			product: .library(),
			dependencies: .group(
				.feature("ExtensionsFeature"),
				.services("AppLinkClient"),
				.services("AppUpdaterClient"),
				.services("DefaultBrowserClient"),
				.services("DiagnosticsClient"),
				.services("BrowserDownloadsClient"),
				.services("BrowserEngineClient"),
				.services("BrowserHistoryClient"),
				.services("BrowserWorkspaceClient"),
				.services("MemberNumberClient"),
				.services("WorkspaceDatabase"),
				.services("WorkspaceSync"),
				.core("BrowserCore"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "SidebarFeature",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		// MARK: - T

		.target(
			name: "TabArchiveFeature",
			product: .library(),
			dependencies: .group(
				.designSystem("AppUI"),
				.core("BrowserCore"),
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "TaskManagerFeature",
			product: .library(),
			dependencies: .group(
				.services("BrowserEngineClient"),
				.core("BrowserCore"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		// MARK: - V

		.target(
			name: "ViewerFeature",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.services("BrowserEngineClient"),
				.appUI,
				.services("BrowserSurfaceClient"),
				.feature("ViewerItemFeature"),
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "ViewerItemFeature",
			product: .library(),
			dependencies: .group(
				.feature("DownloadsFeature"),
				.core("BrowserCore"),
				.services("BrowserDownloadsClient"),
				.services("BrowserEngineClient"),
				.services("BrowserSurfaceClient"),
				.services("PageReaderClient"),
				.appUI,
				.composableArchitecture,
			),
			exclude: ["README.md"]
		),

		// MARK: - Testing

		// MARK: - C

		.testTarget(
			name: "ChatFeatureTests",
			dependencies: .group(
				.feature("ChatFeature"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - D

		.testTarget(
			name: "DownloadsFeatureTests",
			dependencies: .group(
				.feature("DownloadsFeature"),
				.services("BrowserDownloadsClient"),
				.appUI,
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - E

		.testTarget(
			name: "ExtensionsFeatureTests",
			dependencies: .group(
				.feature("SettingsFeature"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - H

		.testTarget(
			name: "HistoryFeatureTests",
			dependencies: .group(
				.feature("HistoryFeature"),
				.appUI,
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - I

		.testTarget(
			name: "IntegrationFeatureTests",
			dependencies: .group(
				.feature("AppFeature"),
				.feature("FeedbackFeature"),
				.feature("HistoryFeature"),
				.feature("OutsideAgentsFeature"),
				.feature("SettingsFeature"),
				.services("AgentToolsClient"),
				.services("AppLinkClient"),
				.services("BrowserEngineClient"),
				.services("PageReaderClient"),
				.services("BrowserAutomationClient"),
				.services("BrowserDownloadsClient"),
				.services("BrowserExtensionsClient"),
				.services("BrowserPagePreviewClient"),
				.services("AppUpdaterClient"),
				.services("DefaultBrowserClient"),
				.services("DiagnosticsClient"),
				.services("SearchSuggestionsClient"),
				.services("MemberNumberClient"),
				.services("MemoryPressureClient"),
				.services("WebKitBrowserEngine"),
				.services("WorkspaceDatabase"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - L

		.testTarget(
			name: "LiveFolderFeatureTests",
			dependencies: .group(
				.feature("LiveFolderFeature"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - M

		.testTarget(
			name: "MediaFeatureTests",
			dependencies: .group(
				.feature("MediaFeature"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "MigrationAssistantFeatureTests",
			dependencies: .group(
				.feature("MigrationAssistantFeature"),
				.services("BrowserEngineClient"),
				.services("BrowserExtensionsClient"),
				.services("MigrationAssistant"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - O

		.testTarget(
			name: "OnboardingFeatureTests",
			dependencies: .group(
				.feature("OnboardingFeature"),
				.services("BrowserExtensionsClient"),
				.feature("ChatFeature"),
				.feature("MigrationAssistantFeature"),
				.feature("OutsideAgentsFeature"),
				.services("AgentClient"),
				.services("AgentToolsClient"),
				.services("BrowserAutomationClient"),
				.services("MigrationAssistant"),
				.services("DefaultBrowserClient"),
				.services("WorkspaceSync"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - P

		.testTarget(
			name: "PageCaptureFeatureTests",
			dependencies: .group(
				.feature("PageCaptureFeature"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - T

		.testTarget(
			name: "TaskManagerFeatureTests",
			dependencies: .group(
				.feature("TaskManagerFeature"),
				.services("BrowserEngineClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),
	],
	swiftLanguageModes: [.v6]
)

// MARK: - Helpers (Packages)

extension Package.Dependency {
	static var core: Package.Dependency {
		.package(
			name: "arx-core",
			path: "../core"
		)
	}

	static var dependencies: Package.Dependency {
		.package(
			name: "arx-dependencies",
			path: "../dependencies"
		)
	}

	static var designSystem: Package.Dependency {
		.package(
			name: "arx-design-system",
			path: "../design-system"
		)
	}

	static var engine: Package.Dependency {
		.package(
			name: "arx-engine",
			path: "../engine"
		)
	}

	static var extensions: Package.Dependency {
		.package(
			name: "arx-extensions",
			path: "../extensions"
		)
	}

	static var features: Package.Dependency {
		.package(
			name: "arx-features",
			path: "../features"
		)
	}

	static var services: Package.Dependency {
		.package(
			name: "arx-services",
			path: "../services"
		)
	}

	static var packageResources: Package.Dependency {
		.fork("package-resources-cli")
	}

	static func fork(_ package: String) -> Package.Dependency {
		.package(path: "../../Forks/\(package)")
	}
}

extension TargetDependenciesProvider where Self == Target.Dependency {
	static var localExtensions: Self {
		.extensions("LocalExtensions")
	}

	static var localUIExtensions: Self {
		.extensions("LocalUIExtensions")
	}

	static var testSupport: Self {
		.dependency("_TestSupport")
	}

	static var appUI: Self {
		.designSystem("AppUI")
	}

	static var packageResources: Self {
		.dependency("_PackageResources")
	}

	static var composableArchitecture: Self {
		.dependency("_ComposableArchitecture")
	}

	static var dependencies: Self {
		.dependency("_Dependencies")
	}

	static func core(
		_ product: String,
		condition: TargetDependencyCondition? = nil
	) -> Self {
		.resolve(
			product: product,
			package: "arx-core",
			condition: condition
		)
	}

	static func dependency(
		_ product: String,
		condition: TargetDependencyCondition? = nil
	) -> Self {
		.resolve(
			product: product,
			package: "arx-dependencies",
			condition: condition
		)
	}

	static func designSystem(
		_ product: String,
		condition: TargetDependencyCondition? = nil
	) -> Self {
		.resolve(
			product: product,
			package: "arx-design-system",
			condition: condition
		)
	}

	static func engine(
		_ product: String,
		condition: TargetDependencyCondition? = nil
	) -> Self {
		.resolve(
			product: product,
			package: "arx-engine",
			condition: condition
		)
	}

	static func extensions(
		_ product: String,
		condition: TargetDependencyCondition? = nil
	) -> Self {
		.resolve(
			product: product,
			package: "arx-extensions",
			condition: condition
		)
	}

	static func feature(
		_ product: String,
		condition: TargetDependencyCondition? = nil
	) -> Self {
		.resolve(
			product: product,
			package: "arx-features",
			condition: condition
		)
	}

	static func services(
		_ product: String,
		condition: TargetDependencyCondition? = nil
	) -> Self {
		.resolve(
			product: product,
			package: "arx-services",
			condition: condition
		)
	}

	private static func resolve(
		product: String,
		package: String,
		condition: TargetDependencyCondition?
	) -> Self {
		if package == packageName {
			return .target(product, condition: condition)
		} else {
			return .product(
				name: product,
				package: package,
				condition: condition
			)
		}
	}
}

// MARK: - Helpers (SwiftPM)

// MARK: TargetDependenciesProvider

protocol TargetDependenciesProvider {
	func makeDependencies() -> [Target.Dependency]
}

extension Target.Dependency: TargetDependenciesProvider {
	func makeDependencies() -> [Target.Dependency] { [self] }
}

extension [Target.Dependency]: TargetDependenciesProvider {
	func makeDependencies() -> [Target.Dependency] { self }
}

extension TargetDependenciesProvider where Self == Target.Dependency {
	static func target(
		_ name: String,
		condition: TargetDependencyCondition? = nil
	) -> Self {
		.target(
			name: name,
			condition: condition
		)
	}

	@_disfavoredOverload
	static func product(
		name: String,
		package: String,
		condition: TargetDependencyCondition? = nil
	) -> Self {
		.product(
			name: name,
			package: package,
			condition: condition
		)
	}
}

extension TargetDependenciesProvider where Self == [Target.Dependency] {
	static func group(
		_ providers: (any TargetDependenciesProvider)...
	) -> Self {
		providers.flatMap { $0.makeDependencies() }
	}
}

// MARK: TargetResourcesProvider

protocol TargetResourcesProvider {
	func makeResources() -> [Resource]
}

extension Resource: TargetResourcesProvider {
	func makeResources() -> [Resource] { [self] }
}

extension [Resource]: TargetResourcesProvider {
	func makeResources() -> [Resource] { self }
}

extension TargetResourcesProvider where Self == [Resource] {
	static func group(
		_ providers: (any TargetResourcesProvider)...
	) -> Self {
		providers.flatMap { $0.makeResources() }
	}
}

extension TargetResourcesProvider where Self == [Resource] {
	static var `default`: Self {
		return [.process("Resources")]
	}
}

// MARK: CustomTargetPathBuilder

struct CustomTargetPathBuilder: ExpressibleByStringLiteral {
	private let build: (String) -> String

	func build(for targetName: String) -> String {
		build(targetName)
	}

	init(_ build: @escaping (String) -> String) {
		self.build = build
	}

	init(_ value: String) {
		self.init { _ in value }
	}

	init(stringLiteral value: String) {
		self.init(value)
	}

	static var targetName: Self {
		return .init { $0 }
	}

	func map(_ transform: @escaping (String) -> String) -> Self {
		return .init { transform(self.build(for: $0)) }
	}

	func nestedInSources() -> Self {
		return nested(in: "Sources")
	}

	func nesting(_ child: String?) -> Self {
		return map { path in
			child.map { "\(path)/\($0)" } ?? path
		}
	}

	func nested(in parent: String) -> Self {
		return map { "\(parent)/\($0)" }
	}

	func suffixed(by suffix: String) -> Self {
		return map { "\($0)\(suffix)" }
	}

	func prefixed(by prefix: String) -> Self {
		return map { "\(prefix)\($0)" }
	}
}

// MARK: ProductType

enum ProductType: Equatable {
	case executable
	case library(PackageDescription.Product.Library.LibraryType? = .static)
}

// MARK: ProducibleTarget

struct ProducibleTarget {
	init(
		target: Target,
		productType: ProductType? = .none
	) {
		self.target = target
		self.productType = productType
	}

	var target: Target
	var productType: ProductType?

	var product: PackageDescription.Product? {
		switch productType {
		case .executable:
			// return .executable(name: target.name, targets: [target.name])
			return nil
		case let .library(type):
			return .library(name: target.name, type: type, targets: [target.name])
		case .none:
			return nil
		}
	}

	static func target(
		name: String,
		product productType: ProductType? = nil,
		dependencies: [Target.Dependency] = [],
		path: CustomTargetPathBuilder? = nil,
		exclude: [String] = [],
		sources: [String]? = nil,
		resources: [Resource]? = nil,
		publicHeadersPath: String? = nil,
		packageAccess: Bool = true,
		cSettings: [CSetting]? = nil,
		cxxSettings: [CXXSetting]? = nil,
		swiftSettings: [SwiftSetting]? = nil,
		linkerSettings: [LinkerSetting]? = nil,
		plugins: [Target.PluginUsage]? = nil
	) -> Self {
		return .init(
			target: productType == .executable
			? .executableTarget(
				name: name,
				dependencies: dependencies,
				path: path?.build(for: name),
				exclude: exclude,
				sources: sources,
				resources: resources,
				publicHeadersPath: publicHeadersPath,
				packageAccess: packageAccess,
				cSettings: cSettings,
				cxxSettings: cxxSettings,
				swiftSettings: swiftSettings,
				linkerSettings: linkerSettings,
				plugins: plugins
			)
			: .target(
				name: name,
				dependencies: dependencies,
				path: path?.build(for: name),
				exclude: exclude,
				sources: sources,
				resources: resources,
				publicHeadersPath: publicHeadersPath,
				packageAccess: packageAccess,
				cSettings: cSettings,
				cxxSettings: cxxSettings,
				swiftSettings: swiftSettings,
				linkerSettings: linkerSettings,
				plugins: plugins
			),
			productType: productType
		)
	}

	static func testTarget(
		name: String,
		dependencies: [Target.Dependency] = [],
		path: CustomTargetPathBuilder? = nil,
		exclude: [String] = [],
		sources: [String]? = nil,
		resources: [Resource]? = nil,
		packageAccess: Bool = true,
		cSettings: [CSetting]? = nil,
		cxxSettings: [CXXSetting]? = nil,
		swiftSettings: [SwiftSetting]? = nil,
		linkerSettings: [LinkerSetting]? = nil,
		plugins: [Target.PluginUsage]? = nil
	) -> Self {
		return .init(
			target: .testTarget(
				name: name,
				dependencies: dependencies,
				path: path?.build(for: name),
				exclude: exclude,
				sources: sources,
				resources: resources,
				packageAccess: packageAccess,
				cSettings: cSettings,
				cxxSettings: cxxSettings,
				swiftSettings: swiftSettings,
				linkerSettings: linkerSettings,
				plugins: plugins
			),
			productType: .none
		)
	}
}

// MARK: Package

extension Package {
	convenience init(
		name: String,
		defaultLocalization: LanguageTag? = nil,
		platforms: [SupportedPlatform]? = nil,
		pkgConfig: String? = nil,
		providers: [SystemPackageProvider]? = nil,
		dependencies: [Dependency] = [],
		producibleTargets: [ProducibleTarget],
		swiftLanguageModes: [SwiftLanguageMode]? = nil,
		cLanguageStandard: CLanguageStandard? = nil,
		cxxLanguageStandard: CXXLanguageStandard? = nil
	) {
		self.init(
			name: name,
			defaultLocalization: defaultLocalization,
			platforms: platforms,
			pkgConfig: pkgConfig,
			providers: providers,
			products: producibleTargets.compactMap(\.product),
			dependencies: dependencies,
			targets: producibleTargets.map(\.target),
			swiftLanguageModes: swiftLanguageModes,
			cLanguageStandard: cLanguageStandard,
			cxxLanguageStandard: cxxLanguageStandard
		)
	}
}
