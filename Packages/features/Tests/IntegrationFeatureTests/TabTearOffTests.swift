import AgentClient
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import ChatFeature
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-793: a sidebar tab dropped outside every Arx window moves into Little Arx at the drop
/// point, with its page left open.
@Suite(
	.dependencies {
		$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
		$0.uuid = .incrementing
	}
)
@MainActor
internal struct TabTearOffTests {
	private static let point: CGPoint = .init(x: 320, y: 540)

	@Test
	internal func aDroppedTabMovesIntoLittleArxWithItsPageOpen() async throws {
		let state = fixture()
		let tab = state.workspace.tabs[1]
		let space = state.workspace.spaces[0].id
		var closed: [BrowserCore.Tab.ID] = []
		var released: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
			$0.browserSurface.release = { released.append($0) }
		}

		await store.send(.main(.ui(.dropTabOutsideWindows(tab.id, Self.point)))).finish()

		let little = try #require(store.littleWindows.first)
		#expect(store.littleWindows.count == 1)
		expectNoDifference(little.tab, tab)
		expectNoDifference(little.spaceID, space)
		expectNoDifference(little.origin, Self.point)
		expectNoDifference(store.focusedWindowID, little.id)
		#expect(!store.workspace.tabs.ids.contains(tab.id))
		#expect(!store.main.sidebar.organization.tabs.ids.contains(tab.id))
		#expect(!store.main.knownTabIDs.contains(tab.id))
		#expect(store.main.sidebar.undo.isEmpty)
		expectNoDifference(closed, [])
		#expect(released.contains(tab.id))
	}

	/// The app smoke's tear-off phase closes the Little Arx it opened: the window goes, its page
	/// closes once, and no other window takes the focus it had (DEV-855).
	@Test
	internal func aTornOffLittleArxCloses() async throws {
		let state = fixture()
		let tab = state.workspace.tabs[1]
		let closed = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { id in closed.withValue { $0.append(id) } }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserSurface.release = { _ in }
			$0.date = .constant(Date(timeIntervalSince1970: 1_000))
		}
		await store.send(.main(.ui(.dropTabOutsideWindows(tab.id, Self.point)))).finish()
		let little = try #require(store.littleWindows.first)
		#expect(little.openerWindowID == nil)
		await store.send(.littleWindows(.element(id: little.id, action: .ui(.task)))).finish()

		await store.send(.littleWindows(.element(id: little.id, action: .ui(.close)))).finish()

		#expect(store.littleWindows.isEmpty)
		#expect(store.focusedWindowID == nil)
		expectNoDifference(closed.value, [tab.id])
	}

	@Test
	internal func theShownTabLeavesItsWindowShowingAnother() async throws {
		let state = fixture()
		let shown = state.workspace.tabs[0]
		let other = state.workspace.tabs[1]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}

		await store.send(.main(.ui(.dropTabOutsideWindows(shown.id, Self.point)))).finish()

		expectNoDifference(store.littleWindows.first?.tab.id, shown.id)
		#expect(store.main.viewer.item.tab?.id != shown.id)
		#expect(store.main.sidebar.organization.tabs.ids.contains(other.id))
	}

	@Test
	internal func anotherWindowsTabMovesToo() async throws {
		var state = fixture()
		let windowID = UUID(40)
		state.windows.append(MainFeature.State(
			organization: state.workspace,
			spaceID: state.workspace.spaces[0].id,
			id: windowID
		))
		let tab = state.workspace.tabs[1]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}

		await store.send(.windows(.element(id: windowID, action: .ui(.dropTabOutsideWindows(tab.id, Self.point))))).finish()

		expectNoDifference(store.littleWindows.first?.tab, tab)
		#expect(!store.workspace.tabs.ids.contains(tab.id))
		#expect(!store.main.sidebar.organization.tabs.ids.contains(tab.id))
	}

	@Test
	internal func aTabInASplitLeavesItsGroup() async throws {
		var state = fixture()
		let first = state.workspace.tabs[0].id
		let second = state.workspace.tabs[1].id
		try state.workspace.joinSplit([second], with: first, newID: .init(rawValue: UUID(60)))
		state.main.sidebar.organization = state.workspace
		state.unsavedOrganization = state.workspace
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}

		await store.send(.main(.ui(.dropTabOutsideWindows(second, Self.point)))).finish()

		expectNoDifference(store.littleWindows.first?.tab.id, second)
		#expect(store.workspace.split(containing: first) == nil)
		#expect(store.workspace.splits.isEmpty)
	}

	@Test
	internal func aChatTabMovesIntoLittleArx() async throws {
		var state = fixture()
		let chat = BrowserCore.Tab(
			id: .init(rawValue: UUID(30)),
			profileID: state.workspace.profiles[0].id,
			restoration: .init(title: "Chat", url: URL(string: "arx://chat")!)
		)
		try state.workspace.update {
			$0.tabs.append(chat)
			$0.spaces[0].unpinnedTabs.append(chat.id)
		}
		state.main.sidebar.organization = state.workspace
		state.main.knownTabIDs.insert(chat.id)
		var closed: [BrowserCore.Tab.ID] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { closed.append($0) }
		}

		await store.send(.main(.ui(.dropTabOutsideWindows(chat.id, Self.point)))).finish()

		#expect(chat.isChat)
		expectNoDifference(store.littleWindows.first?.tab, chat)
		#expect(!store.workspace.tabs.ids.contains(chat.id))
		expectNoDifference(closed, [])
	}

	@Test
	internal func aTornOffChatTabKeepsItsComposer() async throws {
		var state = fixture()
		let chat = try addChatTab(to: &state)
		let profileID = chat.profileID
		var chats = ChatFeature.State(id: profileID)
		var surface = ChatSurface(newChatProvider: .claude)
		surface.draft = "Half-written question"
		chats.surfaces[.tab(chat.id.rawValue)] = surface
		state.chats.append(chats)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}

		await store.send(.main(.ui(.dropTabOutsideWindows(chat.id, Self.point)))).finish()

		expectNoDifference(store.littleWindows.first?.tab.id, chat.id)
		expectNoDifference(store.chats[id: profileID]?.surfaces[.tab(chat.id.rawValue)]?.draft, "Half-written question")
		#expect(store.tabsTearingOff.isEmpty)
	}

	@Test(arguments: [true, false])
	internal func aPendingTearOffKeepsItsChatSurface(pending: Bool) throws {
		var state = fixture()
		let chat = try addChatTab(to: &state)
		var chats = ChatFeature.State(id: chat.profileID)
		chats.surfaces[.tab(chat.id.rawValue)] = ChatSurface(newChatProvider: .claude)
		state.chats.append(chats)
		if pending { state.tabsTearingOff = [chat.id] }
		var organization = state.workspace
		try organization.update { $0.removeTab(chat.id) }

		// The window publishes its organization without the tab before Little Arx shows it.
		_ = AppFeature()._reduce(into: &state, action: .main(.delegate(.organizationChanged(organization))))

		#expect((state.chats[id: chat.profileID]?.surfaces[.tab(chat.id.rawValue)] != nil) == pending)
	}

	@Test
	internal func aChatTabInLittleArxFollowsItsChat() async throws {
		var state = fixture()
		let chat = try addChatTab(to: &state)
		state.chats.append(ChatFeature.State(id: chat.profileID))
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}
		await store.send(.main(.ui(.dropTabOutsideWindows(chat.id, Self.point)))).finish()
		let conversationID = AgentConversation.ID(rawValue: UUID(80))

		await store.send(.chats(.element(
			id: chat.profileID,
			action: .delegate(.surfaceChanged(.tab(chat.id.rawValue), conversationID))
		))).finish()

		let little = try #require(store.littleWindows.first)
		expectNoDifference(little.tab.chatAddress?.conversationID, conversationID.rawValue)
		#expect(little.tab.isChat)
	}

	@Test
	internal func theTornOffTabLeavesTheMoveSelection() async throws {
		var state = fixture()
		let kept = state.workspace.tabs[0].id
		let tab = state.workspace.tabs[1].id
		state.main.sidebar.moveSelection = [.tab(kept.rawValue), .tab(tab.rawValue)]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}

		await store.send(.main(.ui(.dropTabOutsideWindows(tab, Self.point)))).finish()

		expectNoDifference(store.main.sidebar.moveSelection, [.tab(kept.rawValue)])
	}

	@Test
	internal func closingLittleArxForgetsTheChatTabsSurface() async throws {
		var state = fixture()
		let chat = try addChatTab(to: &state)
		var chats = ChatFeature.State(id: chat.profileID)
		var surface = ChatSurface(newChatProvider: .claude)
		surface.draft = "Left behind"
		chats.surfaces[.tab(chat.id.rawValue)] = surface
		state.chats.append(chats)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.date = .constant(Date(timeIntervalSince1970: 1_000))
		}
		await store.send(.main(.ui(.dropTabOutsideWindows(chat.id, Self.point)))).finish()
		let little = try #require(store.littleWindows.first)
		#expect(store.chats[id: chat.profileID]?.surfaces[.tab(chat.id.rawValue)] != nil)

		await store.send(.littleWindows(.element(id: little.id, action: .ui(.close)))).finish()

		#expect(store.littleWindows.isEmpty)
		#expect(store.chats[id: chat.profileID]?.surfaces[.tab(chat.id.rawValue)] == nil)
	}

	@Test
	internal func aTabAPeekShowsStays() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[1]
		state.peeks.append(.init(
			id: UUID(81),
			source: .init(
				windowID: state.main.id,
				paneID: state.main.viewer.activePaneID,
				tabID: state.workspace.tabs[0].id,
				spaceID: state.main.sidebar.spaceID,
				profileID: tab.profileID,
				identity: "Fixture"
			),
			tab: tab,
			isTemporary: false
		))
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}

		await store.send(.main(.ui(.dropTabOutsideWindows(tab.id, Self.point)))).finish()

		#expect(store.littleWindows.isEmpty)
		#expect(store.main.sidebar.organization.tabs.ids.contains(tab.id))
		#expect(store.workspace.tabs.ids.contains(tab.id))
	}

	@Test
	internal func aProfileChangeInLittleArxForgetsTheChatTabsSurface() async throws {
		var state = fixture()
		let chat = try addChatTab(to: &state)
		var chats = ChatFeature.State(id: chat.profileID)
		chats.surfaces[.tab(chat.id.rawValue)] = ChatSurface(newChatProvider: .claude)
		state.chats.append(chats)
		let otherProfile = Profile.ID(rawValue: UUID(70))
		let otherSpace = Space.ID(rawValue: UUID(71))
		try state.workspace.update {
			$0.profiles.append(.init(id: otherProfile, name: "Other"))
			$0.spaces.append(.init(id: otherSpace, profileID: otherProfile, name: "Elsewhere"))
		}
		state.main.sidebar.organization = state.workspace
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}
		await store.send(.main(.ui(.dropTabOutsideWindows(chat.id, Self.point)))).finish()
		let little = try #require(store.littleWindows.first)

		await store.send(.littleWindows(.element(
			id: little.id,
			action: .event(.profileChangeDecision(otherProfile, otherSpace, true))
		))).finish()

		#expect(store.littleWindows.first?.tab.id != chat.id)
		#expect(store.chats[id: chat.profileID]?.surfaces[.tab(chat.id.rawValue)] == nil)
	}

	@Test
	internal func aTornOffChatTabGoesBackToTheSidebarWithoutAPage() async throws {
		var state = fixture()
		let chat = try addChatTab(to: &state)
		let destination = state.workspace.spaces[1].id
		let opened = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { tab in
				opened.withValue { $0.append(tab.id) }
				if tab.isChat { throw CancellationError() }
			}
			$0.browserEngine.close = { _ in }
		}
		await store.send(.main(.ui(.dropTabOutsideWindows(chat.id, Self.point)))).finish()
		let little = try #require(store.littleWindows.first)

		await store.send(.littleWindows(.element(id: little.id, action: .delegate(.promote(destination))))).finish()

		#expect(store.littleWindows.isEmpty)
		#expect(store.workspace.spaces[id: destination]?.unpinnedTabs.contains(chat.id) == true)
		#expect(!opened.value.contains(chat.id))
	}

	@Test
	internal func aTornOffTabKeepsItsVolume() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[1]
		state.media.isAvailable = true
		state.media.isObserving = true
		state.media.observationID = 1
		state.supportsTabVolume = true
		state.tabVolumes = [tab.id: 0.4]
		let volumes = LockIsolated<[BrowserCore.Tab.ID: Double]>([:])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
			$0.browserMedia.supportsVolume = { true }
			$0.browserMedia.setVolume = { id, volume in volumes.withValue { $0[id] = volume } }
		}
		await store.send(.main(.ui(.dropTabOutsideWindows(tab.id, Self.point)))).finish()

		// The next media snapshot keeps the volume of the page Little Arx holds.
		await store.send(.media(.event(.changed(state.media.snapshot, observationID: 1)))).finish()
		expectNoDifference(store.tabVolumes, [tab.id: 0.4])

		await store.send(.ui(.setTabVolume(tab.id, 0.2))).finish()
		expectNoDifference(store.tabVolumes, [tab.id: 0.2])
		expectNoDifference(volumes.value[tab.id], 0.2)
	}

	@Test
	internal func aTornOffPagesPinnedChatSurfaceGoes() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[1]
		state.main.chatPins[tab.id] = UUID(80)
		var chats = ChatFeature.State(id: tab.profileID)
		chats.surfaces[.pinned(tab.id.rawValue)] = ChatSurface(newChatProvider: .claude)
		state.chats.append(chats)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}

		await store.send(.main(.ui(.dropTabOutsideWindows(tab.id, Self.point)))).finish()

		expectNoDifference(store.littleWindows.first?.tab.id, tab.id)
		#expect(store.chats[id: tab.profileID]?.surfaces[.pinned(tab.id.rawValue)] == nil)
	}

	@Test(arguments: [false, true])
	internal func promotingATornOffChatKeepsItsSurfaceOnlyInItsProfile(acrossProfiles: Bool) async throws {
		var state = fixture()
		let chat = try addChatTab(to: &state)
		var chats = ChatFeature.State(id: chat.profileID)
		chats.surfaces[.tab(chat.id.rawValue)] = ChatSurface(newChatProvider: .claude)
		state.chats.append(chats)
		let otherProfile = Profile.ID(rawValue: UUID(70))
		let otherSpace = Space.ID(rawValue: UUID(71))
		try state.workspace.update {
			$0.profiles.append(.init(id: otherProfile, name: "Other"))
			$0.spaces.append(.init(id: otherSpace, profileID: otherProfile, name: "Elsewhere"))
		}
		state.main.sidebar.organization = state.workspace
		let destination = acrossProfiles ? otherSpace : state.workspace.spaces[1].id
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}
		await store.send(.main(.ui(.dropTabOutsideWindows(chat.id, Self.point)))).finish()
		let little = try #require(store.littleWindows.first)

		await store.send(.littleWindows(.element(id: little.id, action: .delegate(.promote(destination))))).finish()

		#expect(store.littleWindows.isEmpty)
		#expect(store.workspace.spaces[id: destination]?.unpinnedTabs.isEmpty == false)
		#expect((store.chats[id: chat.profileID]?.surfaces[.tab(chat.id.rawValue)] != nil) == !acrossProfiles)
	}

	@Test
	internal func aRefusedTearOffForgetsTheChatSurfaceAndClosesThePage() async throws {
		var state = fixture()
		let chat = try addChatTab(to: &state)
		var chats = ChatFeature.State(id: chat.profileID)
		chats.surfaces[.tab(chat.id.rawValue)] = ChatSurface(newChatProvider: .claude)
		state.chats.append(chats)
		try state.workspace.update { $0.removeTab(chat.id) }
		state.tabsTearingOff = [chat.id]
		let closed = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.close = { id in closed.withValue { $0.append(id) } }
		}

		// The space went away while the page's old host let go.
		await store.send(.event(.tabTornOff(chat, Space.ID(rawValue: UUID(99)), Self.point))).finish()

		#expect(store.littleWindows.isEmpty)
		#expect(store.tabsTearingOff.isEmpty)
		#expect(store.chats[id: chat.profileID]?.surfaces[.tab(chat.id.rawValue)] == nil)
		expectNoDifference(closed.value, [chat.id])
	}

	@Test
	internal func savedTabsAndFavoritesStay() async throws {
		var state = fixture()
		let favorite = state.workspace.tabs[0].id
		let saved = state.workspace.tabs[1].id
		try state.workspace.move(.tab(favorite.rawValue), to: .favoritesRoot, in: state.workspace.spaces[0].id)
		try state.workspace.move(.tab(saved.rawValue), to: .savedRoot, in: state.workspace.spaces[0].id)
		state.main.sidebar.organization = state.workspace
		let before = state.workspace
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}

		await store.send(.main(.ui(.dropTabOutsideWindows(favorite, Self.point)))).finish()
		await store.send(.main(.ui(.dropTabOutsideWindows(saved, Self.point)))).finish()

		#expect(store.littleWindows.isEmpty)
		expectNoDifference(store.main.sidebar.organization, before)
	}

	@Test
	internal func aPrivateWindowKeepsItsTabs() async throws {
		var state = fixture()
		let windowID = UUID(41)
		state.windows.append(MainFeature.State(
			organization: state.workspace,
			spaceID: state.workspace.spaces[0].id,
			isPrivate: true,
			id: windowID
		))
		let tab = state.workspace.tabs[1]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
		}

		await store.send(.windows(.element(id: windowID, action: .ui(.dropTabOutsideWindows(tab.id, Self.point))))).finish()

		#expect(store.littleWindows.isEmpty)
		#expect(store.windows[id: windowID]?.sidebar.organization.tabs.ids.contains(tab.id) == true)
	}

	@Test
	internal func littleArxNeverCarriesAPageIntoAnotherProfile() async throws {
		var state = fixture()
		let otherProfile = Profile.ID(rawValue: UUID(70))
		let otherSpace = Space.ID(rawValue: UUID(71))
		try state.workspace.update {
			$0.profiles.append(.init(id: otherProfile, name: "Other"))
			$0.spaces.append(.init(id: otherSpace, profileID: otherProfile, name: "Elsewhere"))
		}
		let tab = state.workspace.tabs[1]
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in }
		}

		await store.send(.event(.tabTornOff(tab, otherSpace, Self.point))).finish()

		#expect(store.littleWindows.isEmpty)
	}

	private func addChatTab(to state: inout AppFeature.State) throws -> BrowserCore.Tab {
		let chat = BrowserCore.Tab(
			id: .init(rawValue: UUID(30)),
			profileID: state.workspace.profiles[0].id,
			restoration: .init(title: "Chat", url: URL(string: "arx://chat")!)
		)
		try state.workspace.update {
			$0.tabs.append(chat)
			$0.spaces[0].unpinnedTabs.append(chat.id)
		}
		state.main.sidebar.organization = state.workspace
		state.main.knownTabIDs.insert(chat.id)
		return chat
	}

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))
		state.main.viewer.item = .init(tab: organization.tabs[0])
		return state
	}
}
