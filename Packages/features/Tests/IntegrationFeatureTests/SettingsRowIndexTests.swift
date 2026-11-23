@testable import AppFeature
import AppUI
import BrowserCore
import CommandBarFeature
import CustomDump
import Foundation
@testable import SettingsFeature
import Testing
import _ComposableArchitecture

/// DEV-1015: the Settings row index the command bar lists and DEV-1023 builds on.
@MainActor
@Suite(.dependencies)
internal struct SettingsRowIndexTests {
	@Test
	internal func everyDestinationReadsBackFromItsID() async throws {
		let index = SettingsCategory.searchIndex
		for entry in index {
			expectNoDifference(SettingsDestination(id: entry.destination.id), entry.destination, "\(entry.destination.id)")
		}
		expectNoDifference(SettingsDestination(id: "row/general/warnBeforeQuitting"), .row(.general, .warnBeforeQuitting))

		// The sheets that became pages (DEV-1114) still open from a result found before.
		expectNoDifference(SettingsDestination(id: "panel/search/searchShortcuts"), .page(.searchShortcuts))
		expectNoDifference(SettingsDestination(id: "panel/routing/routing"), .page(.routing))
		for text in ["", "row", "row/general", "row/nowhere/haptics", "pane/general/extra", "automation/x"] {
			#expect(SettingsDestination(id: text) == nil, "\(text)")
		}
	}

	@Test
	internal func everySwitchIsFoundOnceAndReadsItsPreference() async throws {
		let toggles = SettingsCategory.searchIndex.compactMap(\.toggle)
		expectNoDifference(Set(toggles).count, toggles.count)

		@Shared(.general)
		var general

		$general.withLock { $0.hapticsEnabled = false }
		#expect(!SettingsSwitch.haptics.isOn)
		$general.withLock { $0.hapticsEnabled = true }
		#expect(SettingsSwitch.haptics.isOn)
	}

	@Test
	internal func aSwitchRowShowsItsStateAndOpensItsRow() async throws {
		@Shared(.general)
		var general

		$general.withLock { $0.hapticsEnabled = true }
		let entry = try #require(SettingsCategory.searchIndex.first { $0.toggle == .haptics })

		let row = CommandBarFeature.Entry(setting: entry)

		expectNoDifference(row.presentation.title, entry.title)
		expectNoDifference(row.presentation.state, String.localized(.appUI.command.settingOn))
		expectNoDifference(row.intent, .openSettings("row/advanced/haptics"))
		expectNoDifference(row.keywords, entry.keywords)
	}
}
