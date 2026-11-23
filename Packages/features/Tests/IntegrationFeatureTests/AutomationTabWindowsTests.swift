import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1157: with independent windows, MCP's inventory names the window that keeps each open
/// tab, and `openTab` can name the window that keeps the new one.
@Suite(.dependencies)
@MainActor
internal struct AutomationTabWindowsTests {
	private let windowID: UUID = UUID(50)

	@Test
	internal func inventoryNamesTheWindowThatKeepsEachOpenTab() async throws {
		var state = fixture()
		let open = state.workspace.spaces[0].unpinnedTabs
		state.windowTabOwners[open[1]] = windowID
		state.applyOpenTabFilters()

		let inventory = try await inventory(of: state)
		let tabs = Dictionary(uniqueKeysWithValues: inventory.items.filter { $0.kind == .tab }.map { ($0.id, $0) })
		expectNoDifference(tabs[open[0].rawValue]?.windowID, state.main.id)
		expectNoDifference(tabs[open[1].rawValue]?.windowID, windowID)

		// Windows say which is the main one, so an agent can pass either ID back.
		expectNoDifference(
			inventory.windows.map { [$0.id: $0.isMain] },
			[[state.main.id: true], [windowID: false]]
		)
	}

	@Test
	internal func aTabChangingWindowBetweenPagesMakesTheCursorStale() async throws {
		var state = fixture()
		let open = state.workspace.spaces[0].unpinnedTabs
		let first = try await inventory(of: state, limit: 1)
		let cursor = try #require(first.nextCursor)

		state.windowTabOwners[open[1]] = windowID
		state.applyOpenTabFilters()
		await #expect(throws: InventoryMissing(result: .failure(.staleCursor))) {
			try await inventory(of: state, cursor: cursor, limit: 1)
		}
	}

	@Test
	internal func aTabChangingWindowTellsSubscribers() throws {
		var state = fixture()
		let open = state.workspace.spaces[0].unpinnedTabs
		let client = state.automationPreferences.clients[0]
		let before = try #require(state.automationChanges(for: client, snapshots: { _ in nil }))

		state.windowTabOwners[open[1]] = windowID
		state.applyOpenTabFilters()
		let after = try #require(state.automationChanges(for: client, snapshots: { _ in nil }))

		#expect(after.tabs[open[1].rawValue] != before.tabs[open[1].rawValue])
		expectNoDifference(after.tabs[open[0].rawValue], before.tabs[open[0].rawValue])
	}

	@Test
	internal func withWindowsSharingTheirTabsNoTabNamesAWindow() async throws {
		var state = fixture()
		state.setIndependentWindows(false)

		let inventory = try await inventory(of: state)
		#expect(inventory.items.allSatisfy { $0.windowID == nil })
		#expect(inventory.items.contains { $0.kind == .tab })
	}

	@Test
	internal func openTabKeepsTheNewTabInTheWindowItNames() async throws {
		let state = fixture()
		var command = try openTab(in: state)
		command.windowID = windowID
		let (store, responses, opened) = commandStore(state)

		await store.send(.automation(.event(.host(.request(request(command))))))
		await store.receive(\.automation.event.inspected)
		await store.receive(\.automation.event.opened)
		await store.finish()

		let tab = try #require(opened.value.first)
		expectNoDifference(
			responses.value.last,
			.command(.init(operationID: command.operationID, status: .acceptedLoading, targetID: tab.id.rawValue))
		)
		expectNoDifference(store.state.windowTabOwners[tab.id], windowID)
		#expect(store.state.windows[id: windowID]?.sidebar.windowOpenTabs.contains(tab.id) == true)
		#expect(!store.state.main.sidebar.windowOpenTabs.contains(tab.id))

		// The inventory names it there too.
		let inventory = try await inventory(of: store.state)
		expectNoDifference(inventory.items.first { $0.id == tab.id.rawValue }?.windowID, windowID)
	}

	@Test
	internal func openTabWithoutAWindowLeavesTheNewTabInTheMainWindow() async throws {
		let state = fixture()
		let command = try openTab(in: state)
		let (store, _, opened) = commandStore(state)

		await store.send(.automation(.event(.host(.request(request(command))))))
		await store.receive(\.automation.event.inspected)
		await store.receive(\.automation.event.opened)
		await store.finish()

		let tab = try #require(opened.value.first)
		#expect(store.state.windowTabOwners[tab.id] == nil)
		#expect(store.state.main.sidebar.windowOpenTabs.contains(tab.id))
	}

	@Test
	internal func openTabNamingAWindowTheClientDoesNotSeeIsDenied() async throws {
		let state = fixture()
		var command = try openTab(in: state)
		command.windowID = UUID(77)
		let (store, responses, opened) = commandStore(state)

		await store.send(.automation(.event(.host(.request(request(command))))))
		await store.finish()

		expectNoDifference(responses.value, [.failure(.denied)])
		#expect(opened.value.isEmpty)
		expectNoDifference(store.state.workspace, state.workspace)
	}

	/// Two spaces of one profile, the first granted to the client, with the main window and an
	/// additional window on it, and independent windows on.
	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture client",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [.space(organization.spaces[0].id, profileID: organization.profiles[0].id)],
			allowsRead: true,
			allowsManagement: true,
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id

		// Approved for a while, so commands run without asking.
		state.automationPreferences.clients[0].mutationGrantUntil = Date(timeIntervalSince1970: 200)
		state.windowIsOpen = true
		state.setIndependentWindows(true)
		state.appendBrowserWindow(windowID, spaceID: organization.spaces[0].id)
		return state
	}

	private func inventory(
		of state: AppFeature.State,
		cursor: String? = nil,
		limit: Int = 100
	) async throws -> AutomationInventory {
		let responses = LockIsolated<[AutomationResult]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.withValue { $0.append(value) } }
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let request = AutomationRequest(
			id: UUID(90),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .inventory(cursor: cursor, limit: limit)
		)
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()

		guard case let .inventory(inventory) = responses.value.last else {
			throw InventoryMissing(result: responses.value.last)
		}
		return inventory
	}

	private struct InventoryMissing: Error, Equatable {
		var result: AutomationResult?
	}

	/// `openTab` in the granted space, as the inventory names it.
	private func openTab(in state: AppFeature.State) throws -> AutomationCommand {
		let items = AutomationInventoryBuilder.items(
			client: state.automationPreferences.clients[0],
			organization: state.workspace,
			snapshots: [:]
		)
		let space = try #require(items.first { $0.kind == .space })
		return .init(
			operationID: UUID(83),
			action: .openTab,
			targetID: space.id,
			expectedRevision: space.revision,
			url: URL(string: "https://window.example/new")!
		)
	}

	private func request(_ command: AutomationCommand) -> AutomationRequest {
		.init(id: UUID(84), clientID: UUID(80), sessionID: UUID(81), operation: .command(command))
	}

	private func commandStore(
		_ state: AppFeature.State
	) -> (
		store: TestStoreOf<AppFeature>,
		responses: LockIsolated<[AutomationResult]>,
		opened: LockIsolated<[BrowserCore.Tab]>
	) {
		let responses = LockIsolated<[AutomationResult]>([])
		let opened = LockIsolated<[BrowserCore.Tab]>([])

		// New tabs need IDs no profile, space or tab of the fixture has.
		let next = LockIsolated(1_000)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.withValue { $0.append(value) } }
			$0.automationControl.authorize = { _ in true }
			$0.browserEngine.openAuthorized = { tab, authorize in
				guard authorize() else { throw AutomationFailure.denied }
				opened.withValue { $0.append(tab) }
			}
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.uuid = UUIDGenerator { next.withValue { value in
				value += 1
				return UUID(value)
			} }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return (store, responses, opened)
	}
}
