import CustomDump
import SettingsFeature
import Testing

@Suite(.dependencies)
internal struct SettingsCategoryTests {
	@Test
	internal func settingsListsEveryCategoryButAnEmptyExperimental() {
		expectNoDifference(SettingsCategory.available, SettingsCategory.allCases.filter { $0 != .experimental })
	}
}
