import CustomDump
import Testing

@testable import AppFeature
@testable import MigrationAssistant

/// The export alert counts with the catalog's plurals and the list format (DEV-1291), instead
/// of one sentence with four numbers no language could inflect.
internal struct BrowserDataExportMessageTests {
	@Test
	internal func anArchiveCountsEachKindWithItsOwnPlural() {
		let one: MigrationExportSummary = .init(profiles: 1, spaces: 1, folders: 1, tabs: 1, omittedRegularTabs: 0)
		expectNoDifference(
			BrowserDataExportOutcome.archive(one).message.detail,
			"Exported: 1 profile, 1 space, 1 folder, and 1 tab."
		)

		let many: MigrationExportSummary = .init(
			profiles: 2,
			spaces: 5,
			folders: 0,
			tabs: 12,
			omittedRegularTabs: 0,
			historyEntries: 1,
			archivedTabs: 3,
			extensions: 2
		)
		expectNoDifference(
			BrowserDataExportOutcome.archive(many).message.detail,
			"""
			Exported: 2 profiles, 5 spaces, 0 folders, and 12 tabs.
			Also exported: 1 history entry and 3 archived tabs.
			2 extensions are listed to reinstall.
			"""
		)
	}

	@Test
	internal func bookmarksSayWhichRegularTabsWereLeftOut() {
		let kept: MigrationExportSummary = .init(profiles: 1, spaces: 2, folders: 1, tabs: 25, omittedRegularTabs: 0)
		expectNoDifference(
			BrowserDataExportOutcome.bookmarks(kept).message.detail,
			"Exported: 25 bookmarks and 1 folder. Profiles and spaces became folders."
		)

		let omitted: MigrationExportSummary = .init(profiles: 1, spaces: 2, folders: 3, tabs: 1, omittedRegularTabs: 1)
		expectNoDifference(
			BrowserDataExportOutcome.bookmarks(omitted).message.detail,
			"""
			Exported: 1 bookmark and 3 folders. Profiles and spaces became folders.
			1 regular tab wasn’t included.
			"""
		)
	}
}
