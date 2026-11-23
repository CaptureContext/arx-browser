@testable import AppFeature
import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// A request that targets one item derives that item alone, so its inventory work is the
/// same at 10 and 100 tabs (DEV-938). Authority is still checked at every step.
extension IntegrationFeatureTests {
	@Test(arguments: [AutomationCommand.Action.selectTab, .openTab])
	internal func targetedCommandsDeriveTheSameInventoryWorkAtTenAndHundredTabs(
		action: AutomationCommand.Action
	) async throws {
		let ten = try await targetedCommandDerivations(action, tabs: 10)
		let hundred = try await targetedCommandDerivations(action, tabs: 100)
		for counts in [ten, hundred] {
			expectNoDifference(counts.inventories, 0)

			// Revisions come from the cache or are digested for the few named items only.
			#expect(counts.revisions <= 4)
		}
		#expect(ten.locationWalks > 0)
		expectNoDifference(hundred.locationWalks, ten.locationWalks)
	}

	/// Every check of a command that names its tabs reads those sessions alone, not every tab's:
	/// the request's inspection, the engine's authorization callbacks and the response check
	/// (DEV-934).
	@Test(arguments: [AutomationCommand.Action.selectTab, .openTab])
	internal func targetedCommandsReadTheSameSessionsAtTenAndHundredTabs(
		action: AutomationCommand.Action
	) async throws {
		let ten = try await targetedCommandSessionReads(action, tabs: 10)
		let hundred = try await targetedCommandSessionReads(action, tabs: 100)
		expectNoDifference(ten.everyTab, 0)
		expectNoDifference(hundred.everyTab, 0)
		#expect(ten.reads > 0)
		expectNoDifference(hundred.reads, ten.reads)
	}

	@Test
	internal func inventoryStillReadsEverySession() async throws {
		let state = scalingFixture(tabs: 10)
		let client = state.automationPreferences.clients[0]
		let request = AutomationRequest(
			id: UUID(84),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .inventory(cursor: nil, limit: 100)
		)
		expectNoDifference(state.automationSnapshotTabIDs(for: request), Set(state.workspace.tabs.ids))
	}

	@Test
	internal func automationSynchronizationComparesEveryOrganizationField() {
		// matchesIgnoringSelection lists BrowserOrganization's stored properties by hand.
		// A new one must be compared there too, or a stale window copy could authorize.
		let fields = Mirror(reflecting: BrowserOrganization()).children.compactMap(\.label)
		expectNoDifference(
			fields,
			[
				"legacyProfileID", "retiredProfileIDs", "profiles", "spaces", "folders", "tabs", "archive", "splits",
				"tabGroups",
			]
		)

		let organization = fixture()
		var selected = organization
		selected.spaces[0].selectedTabID = organization.tabs[1].id
		#expect(organization.matchesIgnoringSelection(selected))
		var renamed = selected
		renamed.tabs[0].customTitle = "Renamed"
		#expect(!organization.matchesIgnoringSelection(renamed))
		var reordered = organization
		reordered.spaces[0].unpinnedTabs.reverse()
		#expect(!organization.matchesIgnoringSelection(reordered))
	}

	/// Runs one approved command through the reducer, then the final execution and response
	/// checks the app makes before releasing its result, counting inventory derivations.
	private func targetedCommandDerivations(
		_ action: AutomationCommand.Action,
		tabs count: Int
	) async throws -> AutomationInventoryBuilder.Derivations.Counts {
		var state = scalingFixture(tabs: count)
		let client = state.automationPreferences.clients[0]
		let target = state.workspace.tabs[count / 2]
		var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [:]
		for (index, tab) in state.workspace.tabs.enumerated() {
			snapshots[tab.id] = .init(navigation: .init(url: tab.restoration.url), revision: UInt64(index + 1))
		}
		let targetID = action == .openTab ? state.workspace.spaces[0].id.rawValue : target.id.rawValue
		let item = try #require(AutomationInventoryBuilder.item(
			targetID,
			client: client,
			organization: state.workspace,
			snapshots: snapshots
		))
		var command = AutomationCommand(
			operationID: UUID(85),
			action: action,
			targetID: item.id,
			expectedRevision: item.revision
		)
		if action == .openTab { command.url = URL(string: "https://capturecontext.dev/new")! }
		let request = AutomationRequest(
			id: UUID(84),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .command(command)
		)

		// The execution guard the engine calls back into, at the command's own snapshot.
		state.automation.pending[request.id] = .init(
			request: request,
			grantRevision: client.grantRevision,
			approved: true,
			executing: true
		)
		let guarded = state
		state.automation.pending[request.id] = nil

		var responses: [AutomationResult] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.append(value) }
			$0.automationControl.authorize = { _ in true }
			$0.browserEngine.snapshot = { snapshots[$0] }
			$0.browserEngine.openAuthorized = { _, authorize in
				guard authorize() else { throw AutomationFailure.denied }
			}
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let derivations = AutomationInventoryBuilder.Derivations()
		try await AutomationInventoryBuilder.$derivations.withValue(derivations) {
			#expect(guarded.automationCanExecute(request.id, snapshots: snapshots, now: Date(timeIntervalSince1970: 100)))
			await store.send(.automation(.event(.host(.request(request)))))
			await store.receive(\.automation.event.inspected)
			if action == .openTab { await store.receive(\.automation.event.opened) }
			await store.finish()
			let response = try #require(responses.last)
			guard case let .command(result) = response else {
				Issue.record("The command did not commit: \(response)")
				return
			}
			#expect(result.targetID != nil)
			#expect(store.state.automationResponseValidation(request, result: response, snapshots: snapshots) == nil)
		}
		return derivations.counts
	}

	/// Runs one approved command as the app does, counting the engine's session reads, including
	/// the authorization callback the engine makes while opening and the check before release.
	private func targetedCommandSessionReads(
		_ action: AutomationCommand.Action,
		tabs count: Int
	) async throws -> (reads: Int, everyTab: Int) {
		let state = scalingFixture(tabs: count)
		let client = state.automationPreferences.clients[0]
		let target = state.workspace.tabs[count / 2]
		var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot] = [:]
		for (index, tab) in state.workspace.tabs.enumerated() {
			snapshots[tab.id] = .init(navigation: .init(url: tab.restoration.url), revision: UInt64(index + 1))
		}
		let targetID = action == .openTab ? state.workspace.spaces[0].id.rawValue : target.id.rawValue
		let item = try #require(AutomationInventoryBuilder.item(
			targetID,
			client: client,
			organization: state.workspace,
			snapshots: snapshots
		))
		var command = AutomationCommand(
			operationID: UUID(85),
			action: action,
			targetID: item.id,
			expectedRevision: item.revision
		)
		if action == .openTab { command.url = URL(string: "https://capturecontext.dev/new")! }
		let request = AutomationRequest(
			id: UUID(84),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .command(command)
		)

		let reads = LockIsolated(0)
		let read: @MainActor @Sendable (BrowserCore.Tab.ID) -> BrowserSessionSnapshot? = { id in
			reads.withValue { $0 += 1 }
			return snapshots[id]
		}
		let responses = LockIsolated<[AutomationResult]>([])

		// The state the engine's callback sees: the command approved and executing.
		var guarded = state
		guarded.automation.pending[request.id] = .init(
			request: request,
			grantRevision: client.grantRevision,
			approved: true,
			executing: true
		)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.automationControl.respond = { _, value in responses.withValue { $0.append(value) } }

			// The engine's callback, as BrowserWindow answers it.
			$0.automationControl.authorize = { [guarded] id in
				guard let pending = guarded.automation.pending[id] else { return false }

				let sessions = AppFeature.State.automationSnapshots(
					of: guarded.automationSnapshotTabIDs(for: pending.request),
					reading: read
				)
				return guarded.automationCanExecute(id, snapshots: sessions, now: Date(timeIntervalSince1970: 100))
			}
			$0.browserEngine.snapshot = read
			$0.browserEngine.openAuthorized = { _, authorize in
				guard authorize() else { throw AutomationFailure.denied }
			}
			$0.date.now = Date(timeIntervalSince1970: 100)
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		let counts = WorkProbe.Counts()
		try await WorkProbe.$counts.withValue(counts) {
			await store.send(.automation(.event(.host(.request(request)))))
			await store.receive(\.automation.event.inspected)
			if action == .openTab { await store.receive(\.automation.event.opened) }
			await store.finish()
			let response = try #require(responses.value.last)
			guard case let .command(result) = response else {
				Issue.record("The command did not commit: \(response)")
				return
			}
			#expect(result.targetID != nil)
			// The check before the result is released, as BrowserWindow makes it.
			let sessions = AppFeature.State.automationSnapshots(
				of: store.state.automationSnapshotTabIDs(for: request, result: response),
				reading: read
			)
			#expect(store.state.automationResponseValidation(request, result: response, snapshots: sessions) == nil)
		}
		return (reads.value, counts[.everyAutomationSnapshot])
	}

	private func scalingFixture(tabs count: Int) -> AppFeature.State {
		let profile = Profile.ID(rawValue: UUID(0))
		let space = Space.ID(rawValue: UUID(1))
		let tabs: [BrowserCore.Tab] = (0..<count).map { index in
			.init(
				id: .init(rawValue: UUID(1000 + index)),
				profileID: profile,
				restoration: .init(title: "Page \(index)", url: URL(string: "https://capturecontext.dev/\(index)")!)
			)
		}
		let organization = BrowserOrganization(
			profiles: [.init(id: profile, name: "Default")],
			spaces: [.init(id: space, profileID: profile, name: "Work", unpinnedTabs: tabs.map(\.id), selectedTabID: tabs[0].id)],
			tabs: tabs
		)
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture client",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [.space(space, profileID: profile)],
			allowsRead: true,
			allowsManagement: true,
			mutationGrantUntil: Date(timeIntervalSince1970: 200),
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: space),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id
		return state
	}
}
