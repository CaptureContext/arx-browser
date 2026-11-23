import Foundation

/// What Help › Report a Problem saves for the issue (DEV-887): the person's description and the
/// versions, plus diagnostics only when they leave Include diagnostics on.
public struct ProblemReport: Codable, Equatable, Sendable {
	public var description: String
	public var environment: DiagnosticsEnvironment

	/// `nil` when the person turned Include diagnostics off.
	public var diagnostics: Diagnostics?

	public init(
		description: String,
		environment: DiagnosticsEnvironment,
		diagnostics: Diagnostics?
	) {
		self.description = description
		self.environment = environment
		self.diagnostics = diagnostics
	}

	/// The longest description kept.
	public static let descriptionLimit: Int = 10_000

	/// The description, trimmed and capped, or `nil` when there's nothing to report.
	public static func trimmedDescription(_ text: String) -> String? {
		let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty
		else { return nil }

		return String(trimmed.prefix(descriptionLimit))
	}

	public struct Diagnostics: Codable, Equatable, Sendable {
		/// Such as `Mac16,10`.
		public var hardwareModel: String?
		public var memoryGB: Int

		/// Crash reports from the last ``crashReportWindow``.
		public var crashReports: [CrashReport]

		/// Main-thread stalls from the last ``crashReportWindow``, newest first, at most
		/// ``hangLimit`` (DEV-1010). Missing from reports saved before stalls were kept.
		public var stalls: [StallRecord]?

		/// MetricKit's hang reports from the same window, at most ``hangLimit``.
		public var hangReports: [HangReport]?

		/// Runs that ended without Arx quitting, from the same window, at most ``hangLimit``
		/// (DEV-1018).
		public var uncleanExits: [UncleanExit]?

		public init(
			hardwareModel: String?,
			memoryGB: Int,
			crashReports: [CrashReport],
			stalls: [StallRecord]? = nil,
			hangReports: [HangReport]? = nil,
			uncleanExits: [UncleanExit]? = nil
		) {
			self.hardwareModel = hardwareModel
			self.memoryGB = memoryGB
			self.crashReports = crashReports
			self.stalls = stalls
			self.hangReports = hangReports
			self.uncleanExits = uncleanExits
		}
	}

	/// The most stalls and MetricKit reports a problem report carries.
	public static let hangLimit: Int = 20

	/// How far back Include diagnostics reaches for crash reports.
	public static let crashReportWindow: TimeInterval = 7 * 24 * 3600
}

/// The versions every report names. Nothing here identifies the person or their Mac.
public struct DiagnosticsEnvironment: Codable, Equatable, Sendable {
	public var appVersion: String
	public var appBuild: String

	/// Helium's version, from the engine framework (`0.20.1.1`).
	public var engineVersion: String?

	/// The Chromium version the engine is built on.
	public var chromiumVersion: String?

	/// Such as `macOS 27.0 (26A425)`.
	public var macOSVersion: String
	public var architecture: String

	public init(
		appVersion: String,
		appBuild: String,
		engineVersion: String?,
		chromiumVersion: String?,
		macOSVersion: String,
		architecture: String
	) {
		self.appVersion = appVersion
		self.appBuild = appBuild
		self.engineVersion = engineVersion
		self.chromiumVersion = chromiumVersion
		self.macOSVersion = macOSVersion
		self.architecture = architecture
	}

	/// The running app's versions. The engine's come from `Arx Framework.framework`: its
	/// `CFBundleShortVersionString` is Helium's version, and `Versions/Current` names Chromium's.
	public static func current(bundle: Bundle = .main) -> Self {
		let info: [String: Any] = bundle.infoDictionary ?? [:]
		let framework: URL? = bundle.privateFrameworksURL?.appendingPathComponent("Arx Framework.framework")
		let engine: [String: Any]? = framework
			.flatMap { Bundle(url: $0)?.infoDictionary }
		let chromium: String? = framework.flatMap { url in
			let current: URL = url.appendingPathComponent("Versions/Current")
			let resolved: String = current.resolvingSymlinksInPath().lastPathComponent
			return resolved == "Current" ? nil : resolved
		}
		#if arch(arm64)
		let architecture: String = "arm64"
		#else
		let architecture: String = "x86_64"
		#endif
		return .init(
			appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
			appBuild: info["CFBundleVersion"] as? String ?? "unknown",
			engineVersion: engine?["CFBundleShortVersionString"] as? String,
			chromiumVersion: chromium,
			macOSVersion: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
				.replacingOccurrences(of: "Version ", with: "")
				.replacingOccurrences(of: "Build ", with: ""),
			architecture: architecture
		)
	}
}
