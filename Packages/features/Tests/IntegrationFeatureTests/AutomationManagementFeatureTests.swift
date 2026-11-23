import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationManagementFeatureTests {
	@Test
	func profileItemsAppearOnlyForWholeProfileGrants() {
		var state = Self.state()
		var client = state.automationPreferences.clients[0]
		let items = AutomationInventoryBuilder.items(client: client, organization: state.workspace, snapshots: [:])
		#expect(items.contains { $0.kind == .profile && $0.id == Self.work.rawValue })

		client.scopes = [.space(Self.first, profileID: Self.work)]
		let narrow = AutomationInventoryBuilder.items(client: client, organization: state.workspace, snapshots: [:])
		#expect(!narrow.contains { $0.kind == .profile })

		// Without browser admin, profile and space management is denied even with a whole-profile grant.
		state.automationPreferences.clients[0].capabilities.remove(.browserAdmin)
		let request = Self.request(.renameProfile, target: Self.work.rawValue, state: state, name: "Renamed")
		#expect(!state.automationPreferences.clients[0].allows(request.operation.requiredCapabilities))
	}

	@Test
	func renamingAProfileGoesThroughTheSettingsTransaction() async throws {
		let state = Self.state()
		let (store, responses) = Self.store(state)
		let request = Self.request(.renameProfile, target: Self.work.rawValue, state: state, name: "Renamed")
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.profiles[id: Self.work]?.name, "Renamed")
		guard
			case let .command(result) = responses.value.last,
			result.status == .committed
		else {
			Issue.record("Rename did not commit: \(String(describing: responses.value.last))")
			return
		}
	}

	@Test
	func deletingANonEmptySpaceMovesItsContentsOrClosesThem() async throws {
		// Moving the contents keeps every tab.
		var state = Self.state()
		let (store, responses) = Self.store(state)
		let move = Self.request(.deleteSpace, target: Self.second.rawValue, state: state, destination: Self.first.rawValue)
		await store.send(.automation(.event(.host(.request(move)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.spaces[id: Self.second] == nil)
		expectNoDifference(Set(store.state.workspace.tabs.map(\.id)), Set(state.workspace.tabs.map(\.id)))
		#expect(store.state.workspace.spaces[id: Self.first]?.unpinnedTabs.contains(Self.secondTab) == true)
		guard case .command = responses.value.last else {
			Issue.record("Delete with move did not commit")
			return
		}

		// Without a destination the space's tabs close after each page allows it.
		state = Self.state()
		var closed: [BrowserCore.Tab.ID] = []
		let (closing, closingResponses) = Self.store(state) {
			$0.browserEngine.close = { closed.append($0) }
		}
		let delete = Self.request(.deleteSpace, target: Self.second.rawValue, state: state)
		await closing.send(.automation(.event(.host(.request(delete)))))
		await closing.finish()
		await closing.skipReceivedActions(strict: false)
		#expect(closing.state.workspace.spaces[id: Self.second] == nil)
		#expect(closing.state.workspace.tabs[id: Self.secondTab] == nil)
		expectNoDifference(closed, [Self.secondTab])
		guard case .command = closingResponses.value.last else {
			Issue.record("Delete without move did not commit")
			return
		}

		// A page that refuses to close keeps the space.
		let (refused, refusedResponses) = Self.store(Self.state()) {
			$0.browserEngine.permitsClosing = { _ in false }
		}
		await refused.send(.automation(.event(.host(.request(delete)))))
		await refused.finish()
		await refused.skipReceivedActions(strict: false)
		#expect(refused.state.workspace.spaces[id: Self.second] != nil)
		expectNoDifference(refusedResponses.value.last, .failure(.cancelled))
	}

	@Test
	func theLastSpaceCannotBeDeleted() async throws {
		var state = Self.state()
		state.workspace.spaces.remove(id: Self.second)
		state.workspace.spaces.remove(id: Self.elsewhere)
		state.workspace.tabs.remove(id: Self.secondTab)
		state.main.sidebar.organization = state.workspace
		let (store, responses) = Self.store(state)

		// Another profile's space doesn't count: the browser needs one space in all.
		let request = Self.request(.deleteSpace, target: Self.first.rawValue, state: state)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.spaces.count == 1)
		expectNoDifference(responses.value.last, .failure(.invalidRequest))
	}

	@Test
	func favoritesEditsCommitWithUndo() async throws {
		let state = Self.state()
		let (store, responses) = Self.store(state)
		let request = Self.request(.addFavorite, target: Self.firstTab.rawValue, state: state)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.profiles[id: Self.work]?.favorites, [Self.firstTab])
		guard case .command = responses.value.last else {
			Issue.record("addFavorite did not commit")
			return
		}

		// The main window's Undo restores the workspace from before the assistant's edit.
		await store.send(.main(.sidebar(.ui(.undo))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.main.sidebar.organization.profiles[id: Self.work]?.favorites, [])
	}

	@Test
	func crossProfileMovesReopenThroughTheSidebarTransfer() async throws {
		var state = Self.state()
		state.automationPreferences.clients[0].scopes.append(.profile(Self.home))
		var opened: [BrowserCore.Tab] = []
		var closed: [BrowserCore.Tab.ID] = []
		let (store, responses) = Self.store(state) {
			$0.browserEngine.snapshot = { _ in nil }
			$0.browserEngine.open = { opened.append($0) }
			$0.browserEngine.close = { closed.append($0) }
			$0.browserEngine.prepareProfile = { _ in }
		}
		let request = Self.request(.moveTab, target: Self.firstTab.rawValue, state: state, destination: Self.elsewhere.rawValue)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		// The source tab is gone, and a new tab with its URL exists in the other profile.
		#expect(store.state.workspace.tabs[id: Self.firstTab] == nil)
		let reopened = store.state.workspace.spaces[id: Self.elsewhere]?.unpinnedTabs.compactMap {
			store.state.workspace.tabs[id: $0]
		}
		expectNoDifference(reopened?.map(\.profileID), [Self.home])
		expectNoDifference(reopened?.map(\.restoration.url), [Self.url])
		guard
			case let .command(result) = responses.value.last,
			result.status == .committed
		else {
			Issue.record("The cross-profile move did not commit: \(String(describing: responses.value.last))")
			return
		}
	}

	@Test
	func spacesReorderAndTakeAThemeThroughSettings() async throws {
		var state = Self.state()
		let (store, _) = Self.store(state)
		let move = Self.request(.moveSpace, target: Self.second.rawValue, state: state, destination: Self.first.rawValue)
		await store.send(.automation(.event(.host(.request(move)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.spaces.map(\.id).prefix(2), [Self.second, Self.first])

		state = Self.state()
		let (themed, _) = Self.store(state)
		var request = Self.request(.setSpaceTheme, target: Self.first.rawValue, state: state)
		if case var .command(command) = request.operation {
			command.theme = "dark"
			request.operation = .command(command)
		}
		await themed.send(.automation(.event(.host(.request(request)))))
		await themed.finish()
		await themed.skipReceivedActions(strict: false)
		expectNoDifference(themed.state.workspace.spaces[id: Self.first]?.appearance?.theme, .dark)
	}

	@Test
	func windowsListOnlyGrantedSpacesAndFocusSettles() async throws {
		var state = Self.state()
		let client = state.automationPreferences.clients[0]
		let windows = state.automationWindows(for: client)
		expectNoDifference(windows.map(\.id), [state.main.id])
		expectNoDifference(windows.first?.selectedTabID, nil)

		var narrow = client
		narrow.scopes = [.space(Self.second, profileID: Self.work)]
		#expect(state.automationWindows(for: narrow).isEmpty)

		state.focusedWindowID = UUID(999)
		let (store, responses) = Self.store(state)
		let window = try #require(windows.first)
		let request = AutomationRequest(
			id: UUID(84),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .command(.init(
				operationID: UUID(83),
				action: .focusWindow,
				targetID: window.id,
				expectedRevision: state.automationWindows(for: client)[0].revision
			))
		)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.focusedWindowID, state.main.id)
		guard case .command = responses.value.last else {
			Issue.record("focusWindow did not settle: \(String(describing: responses.value.last))")
			return
		}
	}

	@Test
	func focusingTheMainWindowWaitsForLaunchOnboarding() async throws {
		var state = Self.state()
		let client = state.automationPreferences.clients[0]
		let window = try #require(state.automationWindows(for: client).first)

		// DEV-838: launch onboarding holds the main window back, so it isn't listed and a
		// request for it, made just before, is refused without opening it.
		state.windowIsOpen = false
		state.mainWindowWaitsForOnboarding = true
		state.onboarding = .init(destination: .init(profileID: Self.work, spaceID: Self.first))
		let (store, responses) = Self.store(state)
		let request = AutomationRequest(
			id: UUID(84),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .command(.init(
				operationID: UUID(83),
				action: .focusWindow,
				targetID: window.id,
				expectedRevision: window.revision
			))
		)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(!store.state.windowIsOpen)
		#expect(store.state.automationWindows(for: client).isEmpty)
		guard case .failure = responses.value.last else {
			Issue.record("focusWindow opened the held main window: \(String(describing: responses.value.last))")
			return
		}
	}

	@Test
	func ungroupingAFolderKeepsItsChildren() async throws {
		var state = Self.state()
		let folder = Folder(id: .init(rawValue: UUID(1010)), spaceID: Self.first, name: "Group", children: [.tab(Self.firstTab)])
		state.workspace.folders.append(folder)
		state.workspace.spaces[id: Self.first]?.unpinnedTabs = []
		state.workspace.spaces[id: Self.first]?.savedItems = [.folder(folder.id)]
		state.workspace.tabs[id: Self.firstTab]?.savedDestination = .init(title: "Page", url: Self.url)
		state.main.sidebar.organization = state.workspace
		let (store, _) = Self.store(state)
		let request = Self.request(.ungroupFolder, target: folder.id.rawValue, state: state)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.workspace.folders.isEmpty)
		expectNoDifference(store.state.workspace.spaces[id: Self.first]?.savedItems, [.tab(Self.firstTab)])
	}

	// MARK: - Fixture

	// Far from the IDs `.incrementing` hands out for new spaces, tabs and requests.

	static let work: Profile.ID = .init(rawValue: UUID(1000))
	static let home: Profile.ID = .init(rawValue: UUID(1001))
	static let first: Space.ID = .init(rawValue: UUID(1002))
	static let second: Space.ID = .init(rawValue: UUID(1003))
	static let elsewhere: Space.ID = .init(rawValue: UUID(1004))
	static let firstTab: BrowserCore.Tab.ID = .init(rawValue: UUID(1005))
	static let secondTab: BrowserCore.Tab.ID = .init(rawValue: UUID(1006))
	static let url: URL = URL(string: "https://capturecontext.dev/")!

	static func state() -> AppFeature.State {
		let tabs: [BrowserCore.Tab] = [firstTab, secondTab].map {
			.init(id: $0, profileID: work, restoration: .init(title: "Page", url: url))
		}
		let organization = BrowserOrganization(
			profiles: [.init(id: work, name: "Work"), .init(id: home, name: "Home")],
			spaces: [
				.init(id: first, profileID: work, name: "First", unpinnedTabs: [firstTab]),
				.init(id: second, profileID: work, name: "Second", unpinnedTabs: [secondTab]),
				.init(id: elsewhere, profileID: home, name: "Elsewhere"),
			],
			tabs: tabs
		)
		let client = AutomationClient(
			id: UUID(80),
			name: "Agent",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [.profile(work)],
			capabilities: [.read, .organize, .browserAdmin],
			approvalPolicy: .never,
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: first),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.windowIsOpen = true
		state.automation.sessions[UUID(81)] = client.id
		return state
	}

	static func request(
		_ action: AutomationCommand.Action,
		target: UUID,
		state: AppFeature.State,
		name: String? = nil,
		destination: UUID? = nil
	) -> AutomationRequest {
		let client = state.automationPreferences.clients[0]
		let items = AutomationInventoryBuilder.items(client: client, organization: state.workspace, snapshots: [:])
		let revision = items.first { $0.id == target }?.revision ?? String(repeating: "0", count: 64)
		return .init(
			id: UUID(84),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .command(.init(
				operationID: UUID(83),
				action: action,
				targetID: target,
				expectedRevision: revision,
				destinationID: destination,
				destinationRevision: destination.flatMap { id in items.first { $0.id == id }?.revision },
				name: name
			))
		)
	}

	static func store(
		_ state: AppFeature.State,
		dependencies: (inout DependencyValues) -> Void = { _ in }
	) -> (TestStoreOf<AppFeature>, LockIsolated<[AutomationResult]>) {
		let responses = LockIsolated<[AutomationResult]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.withValue { $0.append(value) } }
			$0.automationControl.authorize = { _ in true }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.close = { _ in }
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.continuousClock = ImmediateClock()
			dependencies(&$0)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return (store, responses)
	}
}
