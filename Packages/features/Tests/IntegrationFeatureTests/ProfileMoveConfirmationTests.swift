import AppUI
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1184: every way a window moves a tab to a space of another profile asks first, saying
/// where it goes and that the page reloads there without its sign-ins: a drag in the sidebar,
/// Move Items…, a drop on a space and the selected tab's move. Escape cancels and moves nothing;
/// Move does it.
@Suite(.dependencies)
@MainActor
internal struct ProfileMoveConfirmationTests {
	private static let other: Profile.ID = .init(rawValue: UUID(200))
	private static let side: Space.ID = .init(rawValue: UUID(201))

	private static let oneTab: ProfileMoveConfirmation.Content = .init(
		subject: .tab,
		spaceName: "Side",
		profileName: "Other"
	)

	/// A drag of a tab onto another profile's space in the sidebar.
	@Test
	internal func aDragAsks() async throws {
		let (store, organization) = makeStore()
		await store.send(.sidebar(.ui(.move(item(organization.tabs[0]), .unpinnedRoot, Self.side))))
		await store.skipReceivedActions(strict: false)
		try await expectAsksAndCancels(store, organization: organization, question: Self.oneTab)
	}

	/// Move Items… with another profile's space chosen.
	@Test
	internal func moveItemsAsks() async throws {
		let (store, organization) = makeStore()
		await store.send(.sidebar(.delegate(.chooseMoveDestination([item(organization.tabs[0])]))))
		#expect(store.state.movePicker != nil)
		await store.send(.ui(.chooseMoveDestination(Self.side, nil)))
		await store.skipReceivedActions(strict: false)
		try await expectAsksAndCancels(store, organization: organization, question: Self.oneTab)
	}

	/// Tabs dropped on another profile's space in the switcher; two tabs say so.
	@Test
	internal func aDropOnASpaceAsks() async throws {
		let (store, organization) = makeStore()
		await store.send(.sidebar(.ui(.tabsDroppedOnSpace(organization.tabs.map(item), Self.side))))
		await store.skipReceivedActions(strict: false)
		try await expectAsksAndCancels(
			store,
			organization: organization,
			question: .init(subject: .tabs(2), spaceName: "Side", profileName: "Other")
		)
	}

	/// The selected tab's move to another profile's space.
	@Test
	internal func theSelectedTabsMoveAsks() async throws {
		let (store, organization) = makeStore()
		await store.send(.ui(.moveSelectedTab(Self.side)))
		await store.skipReceivedActions(strict: false)
		try await expectAsksAndCancels(store, organization: organization, question: Self.oneTab)
	}

	/// A whole space moved to another profile names the space and the profile.
	@Test
	internal func aSpaceMoveAsks() async throws {
		let (store, organization) = makeStore()
		let work = organization.spaces[0]
		await store.send(.ui(.moveSpaceToProfile(work.id, Self.other)))
		let question = try #require(store.state.pendingTabMove?.profileMoveConfirmation)
		expectNoDifference(question, .init(subject: .space("Work"), spaceName: "Work", profileName: "Other"))
		expectNoDifference(question.title, "Move “Work” to the Other profile?")
		expectNoDifference(
			question.detail,
			"The pages reload in the Other profile. Their sign-ins don’t carry over, so you may need to sign in again."
		)
		await store.send(.ui(.cancelProfileMove))
		#expect(store.state.pendingTabMove == nil)
		await store.finish()
	}

	/// Move reopens the page in the other profile's space.
	@Test
	internal func moveMovesIt() async throws {
		let (store, organization) = makeStore()
		await store.send(.sidebar(.ui(.move(item(organization.tabs[0]), .unpinnedRoot, Self.side))))
		await store.skipReceivedActions(strict: false)
		#expect(store.state.pendingTabMove?.profileMoveConfirmation == Self.oneTab)
		await store.send(.ui(.confirmProfileMove))
		await store.receive(\.event.movedAcrossProfiles)
		await store.skipReceivedActions(strict: false)
		await store.finish()

		let result = store.state.sidebar.organization
		#expect(result.tabs[id: organization.tabs[0].id] == nil)
		let moved = try #require(result.spaces[id: Self.side]?.unpinnedTabs.first)
		expectNoDifference(result.tabs[id: moved]?.profileID, Self.other)
		#expect(store.state.pendingTabMove == nil)
	}

	/// A move within the profile asks nothing.
	@Test
	internal func aMoveWithinTheProfileDoesntAsk() async throws {
		let (store, organization) = makeStore()
		let personal = organization.spaces[1].id
		await store.send(.sidebar(.ui(.move(item(organization.tabs[0]), .unpinnedRoot, personal))))
		await store.skipReceivedActions(strict: false)
		await store.finish()
		#expect(store.state.pendingTabMove == nil)
		expectNoDifference(store.state.sidebar.organization.location(of: organization.tabs[0].id), .unpinned(personal))
	}

	// MARK: - Fixture

	/// The question shows as `question`; Escape (Cancel) closes it and moves nothing.
	private func expectAsksAndCancels(
		_ store: TestStoreOf<MainFeature>,
		organization: BrowserOrganization,
		question: ProfileMoveConfirmation.Content,
		sourceLocation: SourceLocation = #_sourceLocation
	) async throws {
		let pending = try #require(store.state.pendingTabMove, sourceLocation: sourceLocation)
		expectNoDifference(pending.profileMoveConfirmation, question)
		await store.send(.ui(.cancelProfileMove))
		await store.finish()
		#expect(store.state.pendingTabMove == nil, sourceLocation: sourceLocation)
		expectNoDifference(store.state.sidebar.organization, organization)
	}

	private func item(_ tab: BrowserCore.Tab) -> SidebarItem.ID {
		.tab(tab.id.rawValue)
	}

	/// The window on Work, with its two tabs, Personal in the same profile and Side in Other.
	private func makeStore() -> (TestStoreOf<MainFeature>, BrowserOrganization) {
		var organization = IntegrationFeatureTests().fixture()
		organization.profiles.append(.init(id: Self.other, name: "Other"))
		organization.spaces.append(.init(id: Self.side, profileID: Self.other, name: "Side"))
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)

		// The window shows its selected tab, as it does by the time anyone moves it.
		state.sidebar.select(organization.tabs[0].id)
		state.viewer.item.tab = organization.tabs[0]
		let snapshots = organization
		let store = TestStore(initialState: state) { MainFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { id in
				snapshots.tabs[id: id].map { .init(navigation: .init(url: $0.restoration.url), revision: 1) }
			}
			$0.browserEngine.prepareProfile = { _ in }
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
			$0.browserEngine.permitsClosing = { _ in true }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return (store, store.state.sidebar.organization)
	}
}
