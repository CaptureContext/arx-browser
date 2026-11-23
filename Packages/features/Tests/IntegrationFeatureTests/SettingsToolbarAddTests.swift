import BrowserCore
import CustomDump
import Foundation
@testable import SettingsFeature
import Testing
import _ComposableArchitecture

/// Max, 18 Nov: Settings' lists add from a "+" on the window's top bar, with a hint naming what it
/// adds, behind the `ARX_SETTINGS_TOOLBAR_ADD` flag.
@Suite(.dependencies)
@MainActor
internal struct SettingsToolbarAddTests {
	/// Profiles is the only pane with a "+"; the five list pages have one each.
	@Test
	internal func eachListHasOnePlusAndItsHintNamesWhatItAdds() {
		let panes = SettingsCategory.allCases.compactMap { category in
			SettingsAddTarget(category: category).map { (category, $0) }
		}
		expectNoDifference(panes.map(\.0), [.profiles])
		let pages = SettingsPage.allCases.compactMap { page in
			SettingsAddTarget(page: page).map { (page, $0) }
		}
		expectNoDifference(pages.map(\.0), [.proxyLinks, .routing, .appLinks, .keptLoadedSites, .webKitSites])
		expectNoDifference(
			pages.map(\.1),
			[.proxyLinkRule, .route, .appLink, .keptLoadedSite, .webKitSite]
		)
		expectNoDifference(
			SettingsAddTarget.allCases.map(\.title),
			["New Profile", "New Rule", "New Route", "New Handler", "Add Site", "Add Site"]
		)
	}

	@Test
	internal func theFlagIsRegisteredAndOnByDefault() throws {
		let defaults = try #require(UserDefaults(suiteName: "SettingsToolbarAddTests.\(UUID())"))
		#expect(FeatureFlag.settingsToolbarAdd.name == "ARX_SETTINGS_TOOLBAR_ADD")
		#expect(FeatureFlag.settingsToolbarAdd.isOn(environment: [:], defaults: defaults))
		#expect(!FeatureFlag.settingsToolbarAdd.isOn(environment: ["ARX_SETTINGS_TOOLBAR_ADD": "0"], defaults: defaults))
	}

	/// The bar's New Route starts the same draft the list's did, once; Remove drops it and a saved
	/// one leaves the list to show it.
	@Test
	internal func newRouteStartsOneDraftUntilItsSaved() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off

		await store.send(SettingsAddTarget.route.action(organization: organization))
		let draft = try #require(store.state.routingDraft)
		expectNoDifference(
			draft,
			.init(
				id: UUID(0),
				name: "",
				host: "",
				includesSubdomains: true,
				destination: .init(scope: .currentSpace, mode: .mainBrowser)
			)
		)

		// A second click while the first is unsaved keeps it.
		await store.send(.ui(.routing(.newDraft)))
		expectNoDifference(store.state.routingDraft, draft)

		await store.send(.ui(.routing(.draftChanged(nil))))
		#expect(store.state.routingDraft == nil)

		await store.send(.ui(.routing(.newDraft)))
		var fresh = try #require(store.state.routingDraft)
		var named = try #require(RoutingPattern.apply("github.com", to: fresh))
		await store.send(.ui(.routing(.draftChanged(named))))
		await store.send(.ui(.routing(.add(named, organization))))
		#expect(store.state.routingDraft == nil)
		expectNoDifference(store.state.routingPreferences.rules.map(\.host), ["github.com"])

		// A refused draft stays, with its error on its row.
		await store.send(.ui(.routing(.newDraft)))
		fresh = try #require(store.state.routingDraft)
		named = try #require(RoutingPattern.apply("example.com", to: fresh))
		named.destination.scope = .space(.init(rawValue: UUID(99)))
		await store.send(.ui(.routing(.draftChanged(named))))
		await store.send(.ui(.routing(.add(named, organization))))
		expectNoDifference(store.state.routingDraft, named)
		#expect(store.state.routing.failedRuleID == named.id)
	}

	/// Each "+" sends what the button over its list sent.
	@Test
	internal func eachPlusOpensWhatTheListsButtonOpened() async {
		let organization = IntegrationFeatureTests().fixture()
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.appLinks = .previewValue
		}
		store.exhaustivity = .off

		await store.send(SettingsAddTarget.proxyLinkRule.action(organization: organization))
		#expect(store.state.proxyLinkEditor != nil)

		await store.send(SettingsAddTarget.webKitSite.action(organization: organization))
		#expect(store.state.siteDraft?.list == .webKit)
		await store.send(.ui(.siteDraft(.cancel)))

		await store.send(SettingsAddTarget.keptLoadedSite.action(organization: organization))
		#expect(store.state.siteDraft?.list == .keptLoaded)
		#expect(store.state.siteDraft?.profileID == organization.profiles.first?.id)
	}

	/// Settings search still finds each action by its hint, on its page.
	@Test(arguments: [
		("New Profile", SettingsDestination.row(.profiles, .profileList)),
		("New Rule", .page(.proxyLinks)),
		("New Route", .page(.routing)),
		("New Handler", .page(.appLinks)),
		("Add Site", .page(.keptLoadedSites)),
		("Add Site", .page(.webKitSites)),
	])
	internal func searchFindsEachActionByItsHint(_ query: String, _ destination: SettingsDestination) {
		let results = SettingsCategory.searchIndex.matching(query)
		#expect(results.contains { $0.destination == destination })
	}
}
