import BrowserCore
import Foundation
import Testing

internal struct BatterySaverTests {
	@Test
	internal func lowPowerModeTurnsItOnUnlessNever() async throws {
		#expect(BatterySaverMode.whenBatteryLow.engineState(lowPowerMode: false) == 1)
		#expect(BatterySaverMode.whenUnplugged.engineState(lowPowerMode: false) == 2)
		#expect(BatterySaverMode.never.engineState(lowPowerMode: false) == 0)
		#expect(BatterySaverMode.whenBatteryLow.engineState(lowPowerMode: true) == 3)
		#expect(BatterySaverMode.whenUnplugged.engineState(lowPowerMode: true) == 3)
		#expect(BatterySaverMode.never.engineState(lowPowerMode: true) == 0)
	}

	@Test
	internal func preferenceRoundTripsAndDefaults() async throws {
		var preferences = BrowserPreferences()
		#expect(preferences.batterySaver == .whenBatteryLow)
		preferences.batterySaver = .whenUnplugged
		let data = try JSONEncoder().encode(preferences)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: data).batterySaver == .whenUnplugged)

		var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		old["batterySaver"] = "fromTheFuture"
		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONSerialization.data(withJSONObject: old))
		#expect(decoded.batterySaver == .whenBatteryLow)
	}
}
