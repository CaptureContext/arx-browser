import CustomDump
@testable import SettingsFeature
import Testing

/// DEV-871: with no working AI commands, a release build neither lists, searches nor opens
/// Assistant › AI Commands, rather than show an empty page.
@MainActor
@Suite(.dependencies)
internal struct SettingsAICommandsTests {
	/// The lists' own pages, which every build lists (DEV-1114).
	private static let lists: [SettingsPage] = [
		.searchShortcuts,
		.proxyLinks,
		.routing,
		.appLinks,
		.keptLoadedSites,
		.webKitSites,
		.featureFlags,
	]

	@Test
	internal func releaseLeavesOutAICommandsWhileNoneWorks() async throws {
		let pages = SettingsPage.available(
			showingPendingOptions: false,
			hasAICommands: false
		)
		expectNoDifference(pages, [.profile] + Self.lists)

		let index = SettingsView.assistantSearchIndex(listing: pages)
		#expect(!index.contains { $0.destination == .page(.aiCommands) })
		#expect(!index.contains { $0.destination == .page(.assistantFeatures) })
		#expect(index.contains { $0.destination == .row(.assistant, .assistantProviders) })
	}

	@Test
	internal func releaseListsAICommandsOnceOneWorks() async throws {
		let pages = SettingsPage.available(
			showingPendingOptions: false,
			hasAICommands: true
		)
		expectNoDifference(pages, [.aiCommands, .profile] + Self.lists)

		let index = SettingsView.assistantSearchIndex(listing: pages)
		#expect(index.contains { $0.destination == .page(.aiCommands) })
	}

	@Test
	internal func debugListsEveryPageWithItsUnfinishedOptions() async throws {
		let pages = SettingsPage.available(
			showingPendingOptions: true,
			hasAICommands: false
		)
		expectNoDifference(pages, SettingsPage.allCases)
	}
}
