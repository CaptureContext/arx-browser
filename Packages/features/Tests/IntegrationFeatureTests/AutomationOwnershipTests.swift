import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct AutomationOwnershipTests {
	@Test(arguments: [false, true], [false, true])
	internal func movingDisplayedTabClearsItsOldPlacement(
		inactivePane: Bool,
		additionalWindow: Bool
	) async throws {
		var state = fixture()
		let target = state.workspace.tabs[0]
		let other = state.workspace.tabs[1]
		state.main.viewer.item = .init(tab: inactivePane ? other : target)
		state.main.sidebar.select(inactivePane ? other.id : target.id)
		if inactivePane { state.main.viewer.panes.append(.init(id: UUID(71), item: .init(tab: target))) }
		let hostID = additionalWindow ? UUID(72) : state.main.id
		if additionalWindow {
			var window = MainFeature.State(
				organization: state.main.sidebar.organization,
				spaceID: state.main.sidebar.spaceID,
				id: hostID
			)
			window.viewer = state.main.viewer
			state.windows.append(window)
			state.main.viewer.item = .init()
			state.main.viewer.panes.removeAll { $0.id == UUID(71) }
		}
		let command = try command(
			.moveTab,
			targetID: target.id.rawValue,
			destinationID: state.workspace.spaces[1].id.rawValue,
			state: state
		)
		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.browserEngine.open = { _ in Issue.record("Moving an existing session must not reopen it") }
			$0.browserEngine.close = { _ in Issue.record("Moving an existing session must not close it") }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.automation(.event(.host(.request(request(command))))))
		await store.receive(\.automation.event.inspected)
		expectNoDifference(store.state.workspace.location(of: target.id), .unpinned(state.workspace.spaces[1].id))
		let host = try #require(additionalWindow ? store.state.windows[id: hostID] : store.state.main)
		#expect(!host.viewer.panes.contains { $0.item.tab?.id == target.id })
		if inactivePane { expectNoDifference(host.viewer.item.tab?.id, other.id) }
		expectNoDifference(store.state.main.sidebar.undo.last?.before, state.workspace)

		// The agent's change is its step in the window (DEV-1030).
		#expect(store.state.main.sidebar.undo.last?.author != .person)
		await store.finish()
		expectNoDifference(responses.last, .command(.init(operationID: command.operationID, status: .committed, targetID: target.id.rawValue)))
	}

	@Test
	internal func backgroundOrganizationEditPreservesWindowLocalSelection() async throws {
		var state = fixture()
		let selected = state.workspace.tabs[1]
		state.main.viewer.item = .init(tab: selected)
		state.main.sidebar.select(selected.id)
		let command = try command(.createFolder, targetID: state.workspace.spaces[0].id.rawValue, state: state)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.automationControl.respond = { _, _ in }
		}
		await store.send(.automation(.event(.host(.request(request(command)))))).finish()
		expectNoDifference(store.main.sidebar.selectedTab?.id, selected.id)
		expectNoDifference(store.main.viewer.item.tab?.id, selected.id)
	}

	@Test(arguments: [AutomationCommand.Action.pinTab, .unpinTab])
	internal func pinChangesKeepTheMountedSessionAndLocalSelection(action: AutomationCommand.Action) async throws {
		var state = fixture()
		let target = state.workspace.tabs[0]
		let other = state.workspace.tabs[1]
		let spaceID = state.workspace.spaces[0].id
		if action == .unpinTab {
			try state.workspace.move(.tab(target.id.rawValue), to: .savedRoot, in: spaceID)
			state.main.sidebar.organization = state.workspace
		}
		state.main.viewer.item = .init(tab: other, generation: 3)
		state.main.sidebar.select(other.id)
		var owner = MainFeature.State(organization: state.workspace, spaceID: spaceID, id: UUID(72))
		owner.viewer.item = .init(tab: state.workspace.tabs[0], generation: 7)
		owner.sidebar.select(target.id)
		state.windows.append(owner)
		let command = try command(action, targetID: target.id.rawValue, destinationID: spaceID.rawValue, state: state)
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.automationControl.respond = { _, _ in }
			$0.browserEngine.open = { _ in Issue.record("Pinning a mounted tab must not reopen it") }
			$0.browserEngine.close = { _ in Issue.record("Pinning a mounted tab must not close it") }
		}
		await store.send(.automation(.event(.host(.request(request(command)))))).finish()
		expectNoDifference(store.main.viewer.item.tab?.id, other.id)
		expectNoDifference(store.main.sidebar.selectedTab?.id, other.id)
		expectNoDifference(store.windows[id: owner.id]?.viewer.item.generation, 7)
		expectNoDifference(store.windows[id: owner.id]?.viewer.item.tab?.id, target.id)
		expectNoDifference(store.windows[id: owner.id]?.sidebar.selectedTab?.id, target.id)
		#expect((store.workspace.tabs[0].savedDestination != nil) == (action == .pinTab))
	}

	@Test(arguments: ["pane", "close", "window", "settings", "downloads", "little", "unchanged"])
	internal func nativeOpenOnlyTakesFocusWhileTheAcceptedPresentationIsCurrent(change: String) async throws {
		var state = fixture()
		state.main.viewer.item = .init(tab: state.workspace.tabs[0])
		state.main.viewer.panes.append(.init(id: UUID(71), item: .init(tab: state.workspace.tabs[1])))
		if change == "little" {
			let tab = BrowserCore.Tab(
				id: .init(rawValue: UUID(76)),
				profileID: state.workspace.profiles[0].id,
				restoration: .init(title: "Little", url: URL(string: "https://capturecontext.dev/little")!)
			)
			state.littleWindows.append(.init(id: UUID(75), spaceID: state.main.sidebar.spaceID, tab: tab))
			state.littleWindows[id: UUID(75)]?.viewer = .init(tab: tab)
			state.focusedWindowID = UUID(75)
		}
		if change == "downloads" { state.downloadsReady = true }
		let initialPaneID = state.main.viewer.activePaneID
		let closeWindow = change == "close"
		var command = try command(.openTab, targetID: state.workspace.spaces[0].id.rawValue, state: state)
		command.url = URL(string: "https://capturecontext.dev/agent-created")!
		command.focus = true
		let started = AsyncStream<BrowserCore.Tab>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		var responses: [AutomationResult] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.automationControl.authorize = { _ in true }
			$0.browserEngine.openAuthorized = { tab, authorize in
				guard authorize() else { throw AutomationFailure.denied }
				started.continuation.yield(tab)
				for await _ in release.stream { break }
			}
			$0.browserEngine.open = { tab in
				if change != "unchanged", tab.id != .init(rawValue: UUID(76)) {
					Issue.record("A late focus must not replace the user's current page")
				}
			}
			$0.browserEngine.close = { _ in Issue.record("The authorized background tab must remain available") }
		}
		let task = store.send(.automation(.event(.host(.request(request(command))))))
		var iterator = started.stream.makeAsyncIterator()
		let tab = try #require(await iterator.next())
		switch change {
		case "close":
			await store.send(.ui(.closeWindow)).finish()

		case "pane":
			await store.send(.main(.viewer(.ui(.focus(UUID(71)))))).finish()

		case "window":
			await store.send(.ui(.newWindow)).finish()

		case "settings":
			await store.send(.ui(.openSettings)).finish()

		case "downloads":
			await store.send(.ui(.openDownloads())).finish()

		case "little":
			let tab = try #require(store.littleWindows[id: UUID(75)]?.tab)
			await store.send(.littleWindows(.element(id: UUID(75), action: .viewer(.show(tab))))).finish()

		default:
			break
		}
		let expectedFocus = store.focusedWindowID
		let expectedViewer = store.main.viewer
		release.continuation.yield(())
		release.continuation.finish()
		await task.finish()
		expectNoDifference(store.workspace.tabs.last, tab)
		expectNoDifference(store.workspace.location(of: tab.id), .unpinned(state.workspace.spaces[0].id))
		if change == "unchanged" {
			expectNoDifference(store.main.viewer.item.tab?.id, tab.id)
			expectNoDifference(store.main.sidebar.selectedTab?.id, tab.id)
		} else {
			expectNoDifference(store.main.viewer, expectedViewer)
			expectNoDifference(store.main.viewer.activePaneID, change == "pane" ? UUID(71) : initialPaneID)
			expectNoDifference(store.focusedWindowID, expectedFocus)
		}
		expectNoDifference(store.windowIsOpen, !closeWindow)
		expectNoDifference(
			responses.last,
			.command(.init(operationID: command.operationID, status: .acceptedLoading, targetID: tab.id.rawValue))
		)
	}

	@Test(arguments: [false, true])
	internal func selectingAnExistingOwnerFocusesItsPaneBeforeReplying(inCollapsedFolder: Bool) async throws {
		var state = fixture()
		if inCollapsedFolder {
			let folderID = Folder.ID(rawValue: UUID(74))
			state.workspace.folders.append(.init(id: folderID, spaceID: state.workspace.spaces[0].id, name: "References", isExpanded: false))
			state.workspace.spaces[0].savedItems.append(.folder(folderID))
			try state.workspace.move(
				.tab(state.workspace.tabs[0].id.rawValue),
				to: .inside(.folder(folderID.rawValue)),
				in: state.workspace.spaces[0].id
			)
			state.workspace.folders[0].isExpanded = false
			state.main.sidebar.organization = state.workspace
		}
		let target = state.workspace.tabs[0]
		let other = state.workspace.tabs[1]
		let paneID = UUID(71)
		let windowID = UUID(72)
		var owner = MainFeature.State(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: windowID)
		owner.viewer.item = .init(tab: other)
		owner.viewer.panes.append(.init(id: paneID, item: .init(tab: target)))
		owner.sidebar.select(other.id)
		state.windows.append(owner)
		let snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [
			target.id: .init(navigation: .init(url: target.restoration.url), revision: 1)
		]
		let items = AutomationInventoryBuilder.items(
			client: state.automationPreferences.clients[0],
			organization: state.workspace,
			snapshots: snapshots
		)
		let item = try #require(items.first { $0.id == target.id.rawValue })
		let command = AutomationCommand(
			operationID: UUID(83),
			action: .selectTab,
			targetID: item.id,
			expectedRevision: item.revision
		)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.automationControl.respond = { _, _ in }
			$0.browserEngine.snapshot = { snapshots[$0] }
			$0.browserEngine.open = { _ in Issue.record("Selecting the existing owner must not rehost its session") }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.automation(.event(.host(.request(request(command))))))
		await store.receive(\.automation.event.inspected)
		expectNoDifference(store.state.focusedWindowID, windowID)
		expectNoDifference(store.state.windows[id: windowID]?.viewer.activePaneID, paneID)
		expectNoDifference(store.state.windows[id: windowID]?.sidebar.selectedTab?.id, target.id)
		await store.finish()
		expectNoDifference(store.state.automationResponseValidation(request(command), result: .command(.init(
			operationID: command.operationID,
			status: .committed,
			targetID: target.id.rawValue
		)), snapshots: snapshots), nil)
	}

	@Test(arguments: ["replacement", "close", "peek", "owner", "capture", "lifecycle"])
	internal func queuedSpaceResumeCannotReplaceANewerPresentation(change: String) async {
		var state = fixture()
		let target = state.workspace.tabs[0]
		state.main.viewer.item = .init(tab: target, generation: 1)
		let context = TabPresentationContext(state)
		switch change {
		case "replacement":
			state.main.viewer.item = .init(tab: state.workspace.tabs[1], generation: 2)

		case "close":
			state.windowIsOpen = false

		case "peek":
			state.peeks.append(.init(id: UUID(73), source: .init(
			windowID: state.main.id,
			paneID: state.main.viewer.activePaneID,
			tabID: target.id,
			spaceID: state.main.sidebar.spaceID,
			profileID: target.profileID,
			identity: "Fixture"
		), tab: target, isTemporary: false))

		case "capture":
			state.captureSessions.append(.init(id: UUID(77), source: .init(
			host: .pane(windowID: state.main.id, paneID: state.main.viewer.activePaneID),
			tabID: target.id,
			profileID: target.profileID,
			spaceID: state.main.sidebar.spaceID
		), title: "Fixture", mode: .visible, sourceGeneration: 1, preparation: UUID(78)))

		case "owner":
			var owner = MainFeature.State(organization: state.workspace, spaceID: state.main.sidebar.spaceID, id: UUID(72))
			owner.viewer.item = .init(tab: target)
			state.windows.append(owner)

		default:
			state.main.pendingTabCloses.insert(target.id)
		}
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.open = { _ in Issue.record("A stale resume must not open or reattach a session") }
		}
		await store.send(.resumeTabPresentation(context))
		await store.finish()
	}

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture client",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: organization.spaces.map { .space($0.id, profileID: $0.profileID) },
			allowsRead: true,
			allowsManagement: true,
			mutationGrantUntil: Date(timeIntervalSince1970: 200),
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id
		return state
	}

	private func command(
		_ action: AutomationCommand.Action,
		targetID: UUID,
		destinationID: UUID? = nil,
		state: AppFeature.State
	) throws -> AutomationCommand {
		let items = AutomationInventoryBuilder.items(
			client: state.automationPreferences.clients[0],
			organization: state.workspace,
			snapshots: [:]
		)
		let target = try #require(items.first { $0.id == targetID })
		let destination = destinationID.flatMap { id in items.first { $0.id == id } }
		return .init(
			operationID: UUID(83),
			action: action,
			targetID: target.id,
			expectedRevision: target.revision,
			destinationID: destination?.id,
			destinationRevision: destination?.revision,
			name: "Assistant folder"
		)
	}

	private func request(_ command: AutomationCommand) -> AutomationRequest {
		.init(id: UUID(84), clientID: UUID(80), sessionID: UUID(81), operation: .command(command))
	}
}
