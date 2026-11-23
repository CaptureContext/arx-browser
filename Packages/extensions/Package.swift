// swift-tools-version: 6.4

import PackageDescription

// MARK: - Package

let packageName = "arx-extensions"
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
		.package(
			url: "https://github.com/capturecontext/swift-capture.git",
			.upToNextMajor(from: "4.1.1")
		),
		.package(
			url: "https://github.com/capturecontext/swift-casification.git",
			.upToNextMinor(from: "0.7.0")
		),
		.package(
			url: "https://github.com/capturecontext/swift-foundation-extensions.git",
			.upToNextMinor(from: "0.10.0")
		),
		.package(
			url: "https://github.com/capturecontext/swift-keypath-mapping.git",
			.upToNextMinor(from: "0.0.3")
		),
		.package(
			url: "https://github.com/capturecontext/swift-marker-protocols.git",
			.upToNextMajor(from: "1.5.3")
		),
		.package(
			url: "https://github.com/capturecontext/swift-result-builders.git",
			.upToNextMinor(from: "0.0.3")
		),
		.package(
			url: "https://github.com/capturecontext/swift-declarative-configuration.git",
			.upToNextMinor(from: "0.7.1")
		),
		.package(
			url: "https://github.com/capturecontext/swift-keypaths-extensions.git",
			.upToNextMinor(from: "0.2.2")
		),
		.package(
			url: "https://github.com/pointfreeco/swift-case-paths.git",
			.upToNextMajor(from: "1.10.0")
		),
		.package(
			url: "https://github.com/pointfreeco/swift-identified-collections.git",
			.upToNextMajor(from: "1.1.1")
		),
		.package(
			url: "https://github.com/pointfreeco/swift-custom-dump.git",
			.upToNextMajor(from: "1.7.3")
		),
		.package(
			url: "https://github.com/pointfreeco/swift-issue-reporting.git",
			.upToNextMajor(from: "2.1.0")
		),
	],
	producibleTargets: [

		// MARK: - F

		.target(
			name: "Files",
			product: .library(),
			exclude: ["README.md"]
		),

		// MARK: - L

		.target(
			name: "LocalExtensions",
			product: .library(),
			dependencies: .group(
				.product(
					name: "Capture",
					package: "swift-capture"
				),
				.product(
					name: "Casification",
					package: "swift-casification"
				),
				.product(
					name: "FoundationExtensions",
					package: "swift-foundation-extensions"
				),
				.product(
					name: "FoundationExtensionsMacros",
					package: "swift-foundation-extensions"
				),
				.product(
					name: "KeyPathMapping",
					package: "swift-keypath-mapping"
				),
				.product(
					name: "FoundationMarkerProtocols",
					package: "swift-marker-protocols"
				),
				.product(
					name: "ArrayBuilder",
					package: "swift-result-builders"
				),
				.product(
					name: "DeclarativeConfiguration",
					package: "swift-declarative-configuration"
				),
				.product(
					name: "KeyPathsExtensions",
					package: "swift-keypaths-extensions"
				),
				.product(
					name: "CasePaths",
					package: "swift-case-paths"
				),
				.product(
					name: "IdentifiedCollections",
					package: "swift-identified-collections"
				),
				.product(
					name: "CustomDump",
					package: "swift-custom-dump"
				),
				.product(
					name: "IssueReporting",
					package: "swift-issue-reporting"
				),
			),
			exclude: ["README.md"]
		),

		.target(
			name: "LocalUIExtensions",
			product: .library(),
			dependencies: .group(
				.localExtensions,
				.product(
					name: "CocoaAliases",
					package: "cocoa-aliases"
				),
				.product(
					name: "CocoaExtensions",
					package: "swift-cocoa-extensions"
				),
				.product(
					name: "CocoaExtensionsMacros",
					package: "swift-cocoa-extensions"
				),
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
