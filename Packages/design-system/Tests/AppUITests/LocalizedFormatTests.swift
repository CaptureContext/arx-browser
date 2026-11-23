import AppUI
import CustomDump
import Testing

/// Catalog strings go through `String(format:)` (DEV-1291): a percent sign is written `%%`.
internal struct LocalizedFormatTests {
	/// "% CPU" used to lose its "C" to a `% C` specifier; the catalog writes the sign `%%`.
	@Test
	internal func theCPUColumnKeepsItsPercentSign() {
		expectNoDifference(String.localized(.appUI.taskManager.cpu), "CPU %")
	}

	/// Counts are plural variations, so every language can inflect the noun; two keys chosen by
	/// count in code became one.
	@Test
	internal func countsArePlurals() {
		expectNoDifference([1, 2, 5].map { String.localized(.appUI.settings.spaceCount($0)) }, ["1 Space", "2 Spaces", "5 Spaces"])
		expectNoDifference([1, 2, 5].map { String.localized(.appUI.chat.attachTabCount($0)) }, ["1 tab", "2 tabs", "5 tabs"])
		expectNoDifference(
			[1, 2, 5].map { String.localized(.appUI.settings.iCloudSync.historyWindowDays($0)) },
			["1 day", "2 days", "5 days"]
		)
		expectNoDifference(
			[1, 2, 5].map { String.localized(.appUI.onboarding.makeItYours.count.history($0)) },
			["1 history entry", "2 history entries", "5 history entries"]
		)
		expectNoDifference(
			[1, 2, 5].map { String.localized(.appUI.export.count.archivedTabs($0)) },
			["1 archived tab", "2 archived tabs", "5 archived tabs"]
		)
	}

	/// With a name before the count, or a second number after it, the plural follows the count
	/// (the first number).
	@Test
	internal func pluralsFollowTheirCountAmongOtherArguments() {
		expectNoDifference(
			[1, 2, 5].map { String.localized(.appUI.chat.attachLimitFiles("Claude", $0)) },
			[
				"Claude takes up to 1 file in one message.",
				"Claude takes up to 2 files in one message.",
				"Claude takes up to 5 files in one message.",
			]
		)
		expectNoDifference(
			[1, 2, 5].map { String.localized(.appUI.profileMove.tabsTitle($0, "Work")) },
			["Move 1 tab to “Work”?", "Move 2 tabs to “Work”?", "Move 5 tabs to “Work”?"]
		)
		expectNoDifference(
			[(1, 5), (2, 1), (5, 0)].map { String.localized(.appUI.settings.iCloudSync.merge.pins($0.0, $0.1)) },
			[
				"1 pinned tab combined (new: 5)",
				"2 pinned tabs combined (new: 1)",
				"5 pinned tabs combined (new: 0)",
			]
		)
	}
}
