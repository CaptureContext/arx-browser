import Foundation

/// The `ARX_LIVE_CALENDAR` feature flag (DEV-804): a Google Calendar favorite's hover card shows
/// today's day, read from the calendar's own page in the favorite's profile. Off by default
/// until it's proven on real accounts.
public enum LiveCalendar {
	public static let featureFlag: String = FeatureFlag.liveCalendar.name

	/// The environment first, then user defaults, as the other `ARX_*` feature flags read.
	/// `1`, `true` or `yes` turns it on; anything else, or nothing, leaves it off.
	public static func isEnabled(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.liveCalendar.isOn(environment: environment, defaults: defaults)
	}
}
