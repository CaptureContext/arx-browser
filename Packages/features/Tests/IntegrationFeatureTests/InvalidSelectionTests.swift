import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport
@testable import AppFeature

/// A space selecting a tab it doesn't hold made every later workspace save fail with
/// "ValidationError error 20" (DEV-1261).
@Suite(.dependencies)
@MainActor
internal struct InvalidSelectionTests {
	/// Another window or an agent closes the tab this window shows. Reconciling drops it from the
	/// window's organization at once, but the viewer shows it until its queued close arrives, and a
	/// viewer action in between (a resize, a focus) selected it again in a space that no longer
	/// holds it.
	@Test
	internal func viewerActionDoesNotSelectATabClosedElsewhere() async throws {
		var organization = IntegrationFeatureTests().fixture()
		let closed = organization.tabs[0]
		let spaceID = organization.spaces[0].id
		organization.tabs.remove(id: closed.id)
		organization.spaces[0].unpinnedTabs.removeAll { $0 == closed.id }
		organization.spaces[0].selectedTabID = nil
		try organization.validate()

		var initial = MainFeature.State(organization: organization, spaceID: spaceID)
		initial.viewer.item.tab = closed
		initial.viewer.spaceID = spaceID
		let store = TestStore(initialState: initial) { MainFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.viewer(.ui(.resize([1]))))

		expectNoDifference(store.state.sidebar.organization.spaces[id: spaceID]?.selectedTabID, nil)
		try store.state.sidebar.organization.validate()
	}

	/// A Favorite of another profile isn't one this space can show.
	@Test
	internal func selectingAnotherProfilesFavoriteKeepsTheSelection() throws {
		var organization = IntegrationFeatureTests().fixture()
		let otherProfile = Profile.ID(rawValue: UUID(90))
		let favorite = BrowserCore.Tab(
			id: .init(rawValue: UUID(91)),
			profileID: otherProfile,
			savedDestination: .init(title: "Other", url: URL(string: "https://example.com")!),
			restoration: .init(title: "Other", url: URL(string: "https://example.com")!)
		)
		organization.profiles.append(.init(id: otherProfile, name: "Other", favorites: [favorite.id]))
		organization.tabs.append(favorite)
		try organization.validate()

		let spaceID = organization.spaces[0].id
		let selected = organization.spaces[0].selectedTabID
		var state = MainFeature.State(organization: organization, spaceID: spaceID)
		state.sidebar.select(favorite.id)

		expectNoDifference(state.sidebar.organization.spaces[id: spaceID]?.selectedTabID, selected)
		try state.sidebar.organization.validate()
	}

	/// The pop-up read "The operation couldn't be completed. (BrowserCore.BrowserOrganization
	/// .ValidationError error 20.)".
	@Test
	internal func refusedSaveShowsASentence() {
		let error = BrowserOrganization.ValidationError.invalidSelection(
			.init(rawValue: UUID(1)),
			.init(rawValue: UUID(2))
		)
		let message = WorkspaceFailurePresentation.message(for: error)

		expectNoDifference(
			message,
			"Arx couldn't save your tabs, folders and spaces because they don't fit together. Your windows still show everything. Export them to keep a copy."
		)
	}
}
