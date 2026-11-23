import Foundation

/// Settings › General › Battery Saver (DEV-915): when Chromium's Battery Saver turns on. It slows
/// background tabs' timers, limits pages' frame rate and freezes background tabs, as Chrome's
/// Energy Saver does. macOS Low Power Mode turns it on whatever this says, except Never.
public enum BatterySaverMode: String, Codable, CaseIterable, Sendable {
	/// When the battery is at 20% or lower and the Mac is unplugged, Chrome's default.
	case whenBatteryLow

	/// Whenever the Mac runs on battery.
	case whenUnplugged

	/// Not even in Low Power Mode.
	case never

	/// Chromium's `performance_tuning.battery_saver_mode.state` for this choice: 0 off, 1 below
	/// the battery threshold, 2 on battery, 3 always. Low Power Mode makes it 3.
	public func engineState(lowPowerMode: Bool) -> Int32 {
		switch self {
		case .never: 0
		case .whenBatteryLow: lowPowerMode ? 3 : 1
		case .whenUnplugged: lowPowerMode ? 3 : 2
		}
	}
}
