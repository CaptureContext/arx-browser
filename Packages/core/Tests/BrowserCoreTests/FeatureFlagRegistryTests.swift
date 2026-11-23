import BrowserCore
import CustomDump
import Foundation
import Testing

/// DEV-1115: every `ARX_*` feature flag is in `FeatureFlag`, reads the environment before user
/// defaults, and saves where Settings writes it. DEV-1143: each is on by default unless the
/// registry lists it in `offByDefault`.
internal struct FeatureFlagRegistryTests {
	/// `ARX_*` names that the scan below finds but that aren't feature flags. Build, test and smoke
	/// variables don't match its patterns; list one here only if it does.
	private static let notFeatureFlags: Set<String> = [
		// Settings › Advanced › Memory's pages kept for Back and Forward, a number (DEV-943).
		"ARX_BACK_FORWARD_CACHE_SIZE",
		// The engine's purge on freeze: `on` or `limit`, not on and off (DEV-682).
		"ARX_MEMORY_PURGE_ON_FREEZE",
		// The scroll edge's style, one of four, and its tuner, a developer tool (DEV-790).
		"ARX_SCROLL_EDGE",
		"ARX_SCROLL_EDGE_TUNER",
		// Settings › Advanced › WebKit's Widevine answer, a setting the app writes for the engine
		// (DEV-1144).
		"ARX_WIDEVINE_ANSWER",
	]

	/// How a flag shows up in the sources: "the `ARX_X` feature flag" in its documentation, a
	/// `featureFlag` or `name` constant, a read from user defaults or through a `read` closure, or
	/// the engine's `FeatureFlag("ARX_X")`.
	private static let patterns: [String] = [
		#"`(ARX_[A-Z0-9_]+)` (?:feature )?flag"#,
		#"featureFlag[A-Za-z]*: String = "(ARX_[A-Z0-9_]+)""#,
		#"name: String = "(ARX_[A-Z0-9_]+)""#,
		#"forKey: "(ARX_[A-Z0-9_]+)""#,
		#"read\("(ARX_[A-Z0-9_]+)"\)"#,
		#"FeatureFlag\("(ARX_[A-Z0-9_]+)"\)"#,
	]

	/// The source files the scan reads: Swift, and the engine's Objective-C++ and C++.
	private static let extensions: Set<String> = ["swift", "mm", "m", "h", "cc"]

	@Test
	internal func everyFlagTheSourcesReadIsRegistered() throws {
		let found = try Self.flagsInSources()

		// The scan works: it finds at least the flags declared in BrowserCore.
		#expect(found.contains(FeatureFlag.agentTabs.name))
		let registered = Set(FeatureFlag.allCases.map(\.name))
		let missing = found.subtracting(registered).subtracting(Self.notFeatureFlags)
		#expect(
			missing.isEmpty,
			"Register these in FeatureFlag (BrowserCore), or list them in notFeatureFlags: \(missing.sorted())"
		)
		expectNoDifference(registered.intersection(Self.notFeatureFlags), [])
	}

	/// A new flag a merge brings in is caught however it's declared.
	@Test
	internal func theScanFindsANewFlagInEachForm() throws {
		let text = """
		/// Behind the `ARX_ONE` feature flag.
		public static let featureFlag: String = "ARX_TWO"
		public static let name: String = "ARX_THREE"
		let value = defaults.string(forKey: "ARX_FOUR")
		hidesSeparator = read("ARX_FIVE") != "0"
		if (FeatureFlag("ARX_SIX") == "on") {}
		print("ARX_SMOKE_SUCCESS")
		/// As the other `ARX_*` feature flags read.
		"""
		expectNoDifference(
			try Self.names(in: text),
			["ARX_ONE", "ARX_TWO", "ARX_THREE", "ARX_FOUR", "ARX_FIVE", "ARX_SIX"]
		)
	}

	@Test
	internal func theEnvironmentWinsOverDefaults() throws {
		let defaults = try #require(UserDefaults(suiteName: "FeatureFlagRegistryTests.\(UUID())"))
		let flag = FeatureFlag.iCloudSync
		expectNoDifference(flag.state(environment: [:], defaults: defaults), .init(isOn: true, source: .default))
		flag.set(false, defaults: defaults)
		expectNoDifference(flag.state(environment: [:], defaults: defaults), .init(isOn: false, source: .defaults))
		expectNoDifference(defaults.string(forKey: flag.name), "off")
		expectNoDifference(
			flag.state(environment: [flag.name: "1"], defaults: defaults),
			.init(isOn: true, source: .environment)
		)

		// An environment value that's neither on nor off leaves it to defaults.
		expectNoDifference(
			flag.state(environment: [flag.name: "maybe"], defaults: defaults),
			.init(isOn: false, source: .defaults)
		)
		flag.set(nil, defaults: defaults)
		expectNoDifference(defaults.string(forKey: flag.name), nil)
	}

	/// DEV-1143: with nothing set, a flag is on unless the registry lists it as off, and for the
	/// beta only the Customizable homepage is (Max, 17 and 20 Nov).
	@Test
	internal func eachFlagStartsAtTheRegistrysDefault() throws {
		let defaults = try #require(UserDefaults(suiteName: "FeatureFlagRegistryTests.\(UUID())"))
		for flag in FeatureFlag.allCases {
			let isOn = !FeatureFlag.offByDefault.contains(flag)
			expectNoDifference(flag.isOnByDefault, isOn, "\(flag)")
			expectNoDifference(flag.state(environment: [:], defaults: defaults), .init(isOn: isOn, source: .default), "\(flag)")
		}
		expectNoDifference(FeatureFlag.offByDefault, [.customizableHomepage])
	}

	/// DEV-1143: a flag now on by default stays off where Arx already saved it off, and turns off
	/// from the environment or Settings.
	@Test
	internal func aSavedOffKeepsADefaultOnFlagOff() throws {
		let defaults = try #require(UserDefaults(suiteName: "FeatureFlagRegistryTests.\(UUID())"))
		let flag = FeatureFlag.agentTabs
		#expect(flag.isOnByDefault)
		for saved in ["0", "false", "no", "off"] {
			defaults.set(saved, forKey: flag.name)
			expectNoDifference(flag.state(environment: [:], defaults: defaults), .init(isOn: false, source: .defaults), "\(saved)")
		}
		flag.set(nil, defaults: defaults)
		expectNoDifference(flag.state(environment: [flag.name: "0"], defaults: defaults), .init(isOn: false, source: .environment))
		flag.set(false, defaults: defaults)
		expectNoDifference(defaults.string(forKey: flag.name), "off")
		#expect(!flag.isOn(environment: [:], defaults: defaults))
	}

	/// An engine flag's default is the engine's: `engine_bridge.mm` changes one only with the word
	/// for the other side, `on` for a flag off by default and `off` for one on by default.
	@Test
	internal func theEngineFlagsDefaultsAreTheEngines() throws {
		let bridge = try String(
			contentsOf: Self.repository.appending(path: "Packages/engine/Native/engine_bridge.mm"),
			encoding: .utf8
		)
		let pattern = try NSRegularExpression(pattern: #"FeatureFlag\("(ARX_[A-Z0-9_]+)"\) == "(on|off)""#)
		var changing: [String: String] = [:]
		for match in pattern.matches(in: bridge, range: NSRange(bridge.startIndex..., in: bridge)) {
			guard
				let name = Range(match.range(at: 1), in: bridge),
				let word = Range(match.range(at: 2), in: bridge)
			else { continue }

			changing[String(bridge[name])] = String(bridge[word])
		}
		for flag in FeatureFlag.allCases where flag.isReadByEngine {
			let word = try #require(changing[flag.name], "engine_bridge.mm doesn't read \(flag.name)")
			expectNoDifference(flag.isOnByDefault, word == "off", "\(flag)")
		}
	}

	/// The engine's flags read as `engine_bridge.mm` does: any environment value wins, and only
	/// the exact word changes one.
	@Test
	internal func anEngineFlagReadsAsTheEngineDoes() throws {
		let defaults = try #require(UserDefaults(suiteName: "FeatureFlagRegistryTests.\(UUID())"))
		let idle = FeatureFlag.idleTrim
		#expect(idle.isReadByEngine)
		// On by default (DEV-1143): only the exact `off` turns it off.
		expectNoDifference(idle.state(environment: [:], defaults: defaults), .init(isOn: true, source: .default))
		expectNoDifference(idle.state(environment: [idle.name: "0"], defaults: defaults), .init(isOn: true, source: .environment))
		expectNoDifference(idle.state(environment: [idle.name: "off"], defaults: defaults), .init(isOn: false, source: .environment))
		idle.set(false, defaults: defaults)
		expectNoDifference(idle.state(environment: [:], defaults: defaults), .init(isOn: false, source: .defaults))

		// An environment value the engine ignores still hides defaults from it.
		expectNoDifference(idle.state(environment: [idle.name: "no"], defaults: defaults), .init(isOn: true, source: .environment))

		let spare = FeatureFlag.spareRenderer
		expectNoDifference(spare.state(environment: [spare.name: "false"], defaults: defaults), .init(isOn: true, source: .environment))
		expectNoDifference(spare.state(environment: [spare.name: "off"], defaults: defaults), .init(isOn: false, source: .environment))
	}

	@Test
	internal func aFlagOnByDefaultTurnsOffOnlyWhenSaidSo() throws {
		let defaults = try #require(UserDefaults(suiteName: "FeatureFlagRegistryTests.\(UUID())"))
		let flag = FeatureFlag.readingMode
		#expect(flag.isOn(environment: [:], defaults: defaults))
		#expect(!flag.isOn(environment: [flag.name: "off"], defaults: defaults))
		flag.set(false, defaults: defaults)
		#expect(!flag.isOn(environment: [:], defaults: defaults))
		#expect(flag.isOn(environment: [flag.name: "yes"], defaults: defaults))
	}

	/// The `ARX_*` names the patterns find in every package's and the app's sources.
	private static func flagsInSources() throws -> Set<String> {
		let packages = try FileManager.default.contentsOfDirectory(
			at: repository.appending(path: "Packages"),
			includingPropertiesForKeys: nil
		)
		let roots = packages.map { $0.appending(path: "Sources") }
			+ [repository.appending(path: "Sources"), repository.appending(path: "Packages/engine/Native")]
		var names: Set<String> = []
		for root in roots {
			guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }

			for case let file as URL in files where extensions.contains(file.pathExtension) {
				names.formUnion(try Self.names(in: String(contentsOf: file, encoding: .utf8)))
			}
		}
		return names
	}

	/// The repository's root: …/Packages/core/Tests/BrowserCoreTests/FeatureFlagRegistryTests.swift.
	private static var repository: URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
	}

	/// The `ARX_*` names the patterns find in one source file's text.
	private static func names(in text: String) throws -> Set<String> {
		let range = NSRange(text.startIndex..., in: text)
		var names: Set<String> = []
		for pattern in patterns {
			for match in try NSRegularExpression(pattern: pattern).matches(in: text, range: range) {
				guard let name = Range(match.range(at: 1), in: text) else { continue }

				names.insert(String(text[name]))
			}
		}
		return names
	}
}
