// swift-tools-version: 6.4

import PackageDescription

// MARK: - Package

let packageName = "arx-services"
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
		.dependencies,
		.extensions,
	],
	producibleTargets: [

		// MARK: - A

		.target(
			name: "AgentClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.services("BrowserAutomationClient"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "AgentToolsClient",
			product: .library(),
			dependencies: .group(
				.services("BrowserAutomationClient"),
				.extensions("Files"),
				.dependencies,
			),
			exclude: ["README.md", "Skill"]
		),

		.target(
			name: "AppLinkClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "AppRelocationClient",
			product: .library(),
			dependencies: .group(
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "AppUpdaterClient",
			product: .library(),
			dependencies: .group(
				.dependencies,
				.dependency("_Sparkle"),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "ArxCommandLine",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.services("AgentToolsClient"),
				.services("BrowserAutomationClient"),
				.services("BrowserMCPServer"),
				.dependency("_CommandLine"),
				.extensions("Files"),
			),
			exclude: ["README.md"]
		),

		// MARK: - B

		.target(
			name: "BrowserAutomationClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserCaptureClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserDownloadsClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserEngineClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserExtensionsClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependency("_SharingExtensions"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserHistoryClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.services("HistoryDatabase"),
				.dependency("_SQLiteData"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserMCPServer",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.services("AgentToolsClient"),
				.services("BrowserAutomationClient"),
				.dependency("_MCP"),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserMediaClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserPageInspectionClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserPageInteractionClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserPageWaitClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserPagePreviewClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserSiteIconClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserSurfaceClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "BrowserWorkspaceClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.services("HistoryDatabase"),
				.services("WorkspaceDatabase"),
				.dependency("_SharingExtensions"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		// MARK: - C

		.target(
			name: "ClaudeAgentClient",
			product: .library(),
			dependencies: .group(
				.services("AgentClient"),
				.services("BrowserAutomationClient"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "ChromiumBrowserEngine",
			product: .library(),
			dependencies: .group(
				.services("BrowserSiteIconClient"),
				.services("BrowserExtensionsClient"),
				.services("BrowserMediaClient"),
				.services("BrowserCaptureClient"),
				.services("BrowserPageInspectionClient"),
				.services("BrowserPageInteractionClient"),
				.services("BrowserPageWaitClient"),
				.services("BrowserDownloadsClient"),
				.services("BrowserEngineClient"),
				.services("BrowserSurfaceClient"),
				.core("BrowserCore"),
				.engine("ChromiumEngine"),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "CodexAgentClient",
			product: .library(),
			dependencies: .group(
				.services("AgentClient"),
				.services("BrowserAutomationClient"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		// MARK: - D

		.target(
			name: "DefaultBrowserClient",
			product: .library(),
			dependencies: .group(
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "DiagnosticsClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		// MARK: - F

		.target(
			name: "FairPlayBridge",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.services("FairPlayProtocol"),
			),
			exclude: ["README.md"],
			resources: [
				.copy("Resources/FairPlayBridge.js"),
			]
		),

		.target(
			name: "FairPlayPlayer",
			product: .library(),
			dependencies: .group(
				.services("FairPlayProtocol"),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "FairPlayProtocol",
			product: .library(),
			exclude: ["README.md"]
		),

		// MARK: - L

		.target(
			name: "LiveFolderClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		// MARK: - M

		.target(
			name: "MemberNumberClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "MemoryPressureClient",
			product: .library(),
			dependencies: .group(
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "MigrationAssistant",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		// MARK: - P

		.target(
			name: "PageReaderClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.services("BrowserEngineClient"),
				.dependencies,
			),
			exclude: ["README.md", "Resources/Readability-LICENSE.md"],
			resources: [
				.copy("Resources/Readability.js"),
				.copy("Resources/Readability-readerable.js"),
			]
		),

		.target(
			name: "PageTextIndexClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "PageTranslationClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		// MARK: - S

		.target(
			name: "SearchSuggestionsClient",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		.target(
			name: "SoundFeedbackClient",
			product: .library(),
			dependencies: .group(
				.services("BrowserWorkspaceClient"),
				.dependency("_SharingExtensions"),
				.dependencies,
			),
			exclude: ["README.md"],
			resources: [
				.copy("Resources/capture.wav"),
				.copy("Resources/done.wav"),
				.copy("Resources/could-not.wav"),
			]
		),

		// MARK: - W

		.target(
			name: "WebKitBrowserEngine",
			product: .library(),
			dependencies: .group(
				.services("BrowserEngineClient"),
				.services("BrowserSurfaceClient"),
				.core("BrowserCore"),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "HistoryDatabase",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependency("_SQLiteData"),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "WorkspaceDatabase",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.dependency("_SQLiteData"),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "WorkspaceSync",
			product: .library(),
			dependencies: .group(
				.core("BrowserCore"),
				.services("HistoryDatabase"),
				.services("WorkspaceDatabase"),
				.dependency("_SQLiteData"),
				.dependencies,
			),
			exclude: ["README.md"]
		),

		// MARK: - Testing

		// MARK: - A

		.testTarget(
			name: "AgentTests",
			dependencies: .group(
				.services("AgentClient"),
				.services("ClaudeAgentClient"),
				.services("CodexAgentClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "AgentToolsTests",
			dependencies: .group(
				.services("AgentToolsClient"),
				.services("BrowserAutomationClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "BrowserWorkspaceClientTests",
			dependencies: .group(
				.services("BrowserWorkspaceClient"),
				.core("BrowserCore"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "AppLinkTests",
			dependencies: .group(
				.core("BrowserCore"),
				.services("AppLinkClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "AppRelocationTests",
			dependencies: .group(
				.services("AppRelocationClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "AppUpdaterTests",
			dependencies: .group(
				.services("AppUpdaterClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "ArxCommandLineTests",
			dependencies: .group(
				.services("ArxCommandLine"),
				.services("BrowserAutomationClient"),
				.extensions("Files"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - B

		.testTarget(
			name: "BrowserAutomationTests",
			dependencies: .group(
				.services("AgentToolsClient"),
				.services("BrowserAutomationClient"),
				.services("BrowserCaptureClient"),
				.services("BrowserMCPServer"),
				.core("BrowserCore"),
				.testSupport,
				.dependency("_MCP"),
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "BrowserCaptureTests",
			dependencies: .group(
				.services("BrowserCaptureClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "BrowserHistoryTests",
			dependencies: .group(
				.services("BrowserHistoryClient"),
				.services("HistoryDatabase"),
				.dependency("_SQLiteData"),
				.core("BrowserCore"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "BrowserPagePreviewTests",
			dependencies: .group(
				.services("BrowserPagePreviewClient"),
				.core("BrowserCore"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "BrowserSiteIconTests",
			dependencies: .group(
				.services("BrowserSiteIconClient"),
				.core("BrowserCore"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - C

		.testTarget(
			name: "ChromiumBrowserEngineTests",
			dependencies: .group(
				.services("ChromiumBrowserEngine"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - D

		.testTarget(
			name: "DefaultBrowserTests",
			dependencies: .group(
				.services("DefaultBrowserClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "DiagnosticsTests",
			dependencies: .group(
				.services("DiagnosticsClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - F

		.testTarget(
			name: "FairPlayBridgeTests",
			dependencies: .group(
				.services("FairPlayBridge"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - L

		.testTarget(
			name: "LiveFolderTests",
			dependencies: .group(
				.services("LiveFolderClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - M

		.testTarget(
			name: "MemberNumberTests",
			dependencies: .group(
				.services("MemberNumberClient"),
				.core("BrowserCore"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "MigrationAssistantTests",
			dependencies: .group(
				.services("MigrationAssistant"),
				.core("BrowserCore"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - P

		.testTarget(
			name: "PageReaderTests",
			dependencies: .group(
				.services("PageReaderClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "PageTextIndexTests",
			dependencies: .group(
				.services("PageTextIndexClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "PageTranslationTests",
			dependencies: .group(
				.core("BrowserCore"),
				.services("PageTranslationClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - S

		.testTarget(
			name: "SearchSuggestionsTests",
			dependencies: .group(
				.services("SearchSuggestionsClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "SoundFeedbackTests",
			dependencies: .group(
				.services("SoundFeedbackClient"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		// MARK: - W

		.testTarget(
			name: "WebKitBrowserEngineTests",
			dependencies: .group(
				.services("WebKitBrowserEngine"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "WorkspaceDatabaseTests",
			dependencies: .group(
				.services("WorkspaceDatabase"),
				.testSupport,
			),
			exclude: ["README.md"]
		),

		.testTarget(
			name: "WorkspaceSyncTests",
			dependencies: .group(
				.services("WorkspaceSync"),
				.services("HistoryDatabase"),
				.services("BrowserHistoryClient"),
				.services("WorkspaceDatabase"),
				.services("BrowserWorkspaceClient"),
				.core("BrowserCore"),
				.testSupport,
			),
			exclude: ["README.md"]
		),
	],
	swiftLanguageModes: [.v6]
)

// MARK: - Helpers (Packages)

extension Package.Dependency {
	static var engine: Package.Dependency {
		.package(
			name: "arx-engine",
			path: "../engine"
		)
	}

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

	static func engine(_ product: String) -> Self {
		.resolve(product: product, package: "arx-engine", condition: nil)
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
