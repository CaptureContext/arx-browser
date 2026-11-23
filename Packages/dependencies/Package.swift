// swift-tools-version: 6.4

import PackageDescription

// MARK: - Package

let packageName = "arx-dependencies"
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
		.extensions,
		.mcp,
		.sparkle,
		.swiftLog,
		.package(
			url: "https://github.com/apple/swift-argument-parser.git",
			.upToNextMajor(from: "1.8.2")
		),
		.package(
			url: "https://github.com/onmyway133/promptberry.git",
			.upToNextMajor(from: "1.0.0")
		),
		.package(
			url: "https://github.com/swiftlang/swift-subprocess.git",
			.upToNextMajor(from: "1.0.0")
		),
		.package(
			url: "https://github.com/capturecontext/swift-sharing-extensions.git",
			.upToNextMinor(from: "0.2.0")
		),
		.package(
			url: "https://github.com/capturecontext/swift-package-resources.git",
			.upToNextMajor(from: "5.0.1")
		),
		.package(
			url: "https://github.com/pointfreeco/swift-concurrency-extras.git",
			.upToNextMajor(from: "1.4.1")
		),
		.package(
			url: "https://github.com/pointfreeco/swift-dependencies.git",
			.upToNextMajor(from: "1.17.1")
		),
		.package(
			url: "https://github.com/pointfreeco/swift-clocks.git",
			.upToNextMajor(from: "1.1.1")
		),
		.package(
			url: "https://github.com/pointfreeco/combine-schedulers.git",
			.upToNextMajor(from: "1.2.2")
		),
		.package(
			url: "https://github.com/pointfreeco/swift-issue-reporting.git",
			.upToNextMajor(from: "2.1.0")
		),
		.package(
			url: "https://github.com/pointfreeco/swift-perception.git",
			.upToNextMajor(from: "2.0.12")
		),
		.package(
			url: "https://github.com/pointfreeco/swift-snapshot-testing.git",
			.upToNextMajor(from: "1.19.4")
		),
		.package(
			url: "https://github.com/pointfreeco/swift-url-routing.git",
			.upToNextMinor(from: "0.7.0")
		),
		.package(
			url: "https://github.com/pointfreeco/sqlite-data.git",
			.upToNextMajor(from: "1.12.0"),
			traits: ["SQLiteDataTagged"]
		),
		.package(
			url: "https://github.com/pointfreeco/swift-structured-queries.git",
			.upToNextMinor(from: "0.39.2"),
			traits: ["StructuredQueriesTagged", "StructuredQueriesCasePaths"]
		),
	],
	producibleTargets: [

		// MARK: - C

		.target(
			name: "_CocoaNavigation",
			product: .library(),
			dependencies: .group(
				.product(
					name: "AppKitNavigation",
					package: "swift-navigation"
				),
				.dependency("_ConcurrencyExtras"),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "_CommandLine",
			product: .library(),
			dependencies: .group(
				.product(
					name: "ArgumentParser",
					package: "swift-argument-parser"
				),
				.product(
					name: "Promptberry",
					package: "promptberry"
				),
				.product(
					name: "Subprocess",
					package: "swift-subprocess"
				),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "_ComposableArchitecture",
			product: .library(),
			dependencies: .group(
				.product(
					name: "ComposableArchitectureExtensions",
					package: "composable-architecture-extensions"
				),
				.dependency("_CocoaNavigation"),
				.dependency("_SharingExtensions"),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "_ConcurrencyExtras",
			product: .library(),
			dependencies: .group(
				.localExtensions,
				.product(
					name: "ConcurrencyExtras",
					package: "swift-concurrency-extras"
				),
			),
			exclude: ["README.md"]
		),

		// MARK: - D

		.target(
			name: "_Dependencies",
			product: .library(),
			dependencies: .group(
				.localExtensions,
				.dependency("_CocoaNavigation"),
				.product(
					name: "Dependencies",
					package: "swift-dependencies"
				),
				.product(
					name: "DependenciesMacros",
					package: "swift-dependencies"
				),
				.product(
					name: "Clocks",
					package: "swift-clocks"
				),
				.product(
					name: "CombineSchedulers",
					package: "combine-schedulers"
				),
			),
			exclude: ["README.md"]
		),

		// MARK: - I

		.target(
			name: "_IssueReporting",
			product: .library(),
			dependencies: .group(
				.product(
					name: "IssueReporting",
					package: "swift-issue-reporting"
				),
			),
			exclude: ["README.md"]
		),

		// MARK: - M

		.target(
			name: "_MCP",
			product: .library(),
			dependencies: .group(
				.product(
					name: "MCP",
					package: "swift-sdk"
				),
				.product(
					name: "Logging",
					package: "swift-log"
				),
			),
			exclude: ["README.md"]
		),

		// MARK: - P

		.target(
			name: "_PackageResources",
			product: .library(),
			dependencies: .group(
				.product(
					name: "PackageResources",
					package: "swift-package-resources"
				),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "_Perception",
			product: .library(),
			dependencies: .group(
				.product(
					name: "Perception",
					package: "swift-perception"
				),
			),
			exclude: ["README.md"]
		),

		// MARK: - S

		.target(
			name: "_SharingExtensions",
			product: .library(),
			dependencies: .group(
				.product(
					name: "SharingExtensions",
					package: "swift-sharing-extensions"
				),
				.product(
					name: "SharingKeys",
					package: "swift-sharing-extensions"
				),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "_Sparkle",
			product: .library(),
			dependencies: .group(
				.product(
					name: "Sparkle",
					package: "Sparkle"
				),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "_SQLiteData",
			product: .library(),
			dependencies: .group(
				.product(
					name: "SQLiteData",
					package: "sqlite-data"
				),
				.product(
					name: "StructuredQueries",
					package: "swift-structured-queries"
				),
			),
			exclude: ["README.md"]
		),

		// MARK: - T

		.target(
			name: "_TestSupport",
			product: .library(),
			dependencies: .group(
				.dependencies,
				.dependency("_Perception"),
				.localExtensions,
				.product(
					name: "DependenciesTestSupport",
					package: "swift-dependencies"
				),
				.product(
					name: "IssueReportingTestSupport",
					package: "swift-issue-reporting"
				),
				.product(
					name: "SnapshotTesting",
					package: "swift-snapshot-testing"
				),
			),
			exclude: ["README.md"]
		),

		// MARK: - U

		.target(
			name: "_URLRouting",
			product: .library(),
			dependencies: .group(
				.product(
					name: "URLRouting",
					package: "swift-url-routing"
				),
			),
			exclude: ["README.md"]
		),
	],
	swiftLanguageModes: [.v6]
)

// MARK: - Helpers (Packages)

extension Package.Dependency {
	static var mcp: Package.Dependency {
		.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
	}

	static var sparkle: Package.Dependency {
		.package(url: "https://github.com/sparkle-project/Sparkle.git", .upToNextMajor(from: "2.10.1"))
	}

	static var swiftLog: Package.Dependency {
		.package(url: "https://github.com/apple/swift-log.git", .upToNextMajor(from: "1.5.0"))
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
