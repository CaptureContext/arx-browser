import Foundation

/// How long a Little Arx window may sit unused before Arx archives it (DEV-1138).
/// Never is no value at all.
public enum LittleArxArchiveInterval: String, CaseIterable, Codable, Sendable {
	case fifteenMinutes
	case hour
	case twelveHours
	case day

	public var duration: TimeInterval {
		switch self {
		case .fifteenMinutes: 15 * 60
		case .hour: 60 * 60
		case .twelveHours: 12 * 60 * 60
		case .day: 24 * 60 * 60
		}
	}
}

/// The `ARX_LITTLE_ARX_AUTO_ARCHIVE` feature flag (DEV-1138): Little Arx windows left unused
/// for the chosen time are archived, and Settings offers the choice. On by default for the beta,
/// as every feature flag is; the interval itself starts at Never, so nothing is archived until
/// someone picks one.
public enum LittleArxAutoArchiveFeatureFlag {
	public static let name: String = FeatureFlag.littleArxAutoArchive.name

	/// Read through `FeatureFlag`: `0`, `false`, `no` or `off` turns it off; anything else, or
	/// nothing, leaves it on.
	public static func isEnabled(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.littleArxAutoArchive.isOn(environment: environment, defaults: defaults)
	}
}
