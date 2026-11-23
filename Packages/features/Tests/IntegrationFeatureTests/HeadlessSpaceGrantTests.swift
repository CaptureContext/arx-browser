import BrowserAutomationClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// A headless run's own client is granted its run's whole profiles, so spaces that appear
/// during the run are in its grant (DEV-865).
extension AutomationManagementFeatureTests {
	@Test
	internal func aSpaceCreatedDuringAHeadlessRunIsInTheRunsGrant() async throws {
		var state = Self.state()
		let run = UUID(80)
		state.automationPreferences.clients[0].scopes = HeadlessRun.scopes(for: state.workspace)
		state.automationPreferences.clients[0].capabilities = [.read, .screenshots, .pageContent, .organize]
		state.automation.isUnattended = true
		state.automation.unattendedClientID = run

		// Another client of the persistent profile, allowed to create spaces.
		let admin = AutomationClient(
			id: UUID(90),
			name: "Admin",
			credentialDigest: String(repeating: "1", count: 64),
			scopes: [.profile(Self.work)],
			capabilities: [.read, .organize, .browserAdmin],
			approvalPolicy: .never,
			grantRevision: UUID(92)
		)
		state.automationPreferences.clients.append(admin)
		state.automation.sessions[UUID(91)] = admin.id
		let runClient = state.automationPreferences.clients[0]
		let (store, responses) = Self.store(state)

		let created = try await Self.run(
			.createSpace, target: Self.work.rawValue, name: "Created",
			client: admin.id, session: UUID(91), store: store, responses: responses
		)
		let space = try #require(created.flatMap { store.state.workspace.spaces[id: .init(rawValue: $0)] })

		// The grant itself didn't change, so nothing bound to it was dropped.
		expectNoDifference(store.state.automationPreferences.clients[0], runClient)

		// The run organizes the new space: a folder, a tab moved into it, then ungrouped.
		let folder = try #require(try await Self.run(
			.createFolder, target: space.id.rawValue, name: "Folder",
			client: run, session: UUID(81), store: store, responses: responses
		))
		_ = try await Self.run(
			.moveTab, target: Self.firstTab.rawValue, destination: folder,
			client: run, session: UUID(81), store: store, responses: responses
		)
		#expect(store.state.workspace.folders[id: .init(rawValue: folder)]?.children == [.tab(Self.firstTab)])
		_ = try await Self.run(
			.ungroupFolder, target: folder,
			client: run, session: UUID(81), store: store, responses: responses
		)
		#expect(store.state.workspace.folders[id: .init(rawValue: folder)] == nil)
		expectNoDifference(store.state.workspace.spaces[id: space.id]?.savedItems, [.tab(Self.firstTab)])
	}

	@Test
	internal func theRunsGrantIsEveryProfileOfItsRun() async throws {
		let organization = Self.state().workspace
		expectNoDifference(HeadlessRun.scopes(for: organization), [.profile(Self.work), .profile(Self.home)])
	}

	/// Sends one command for `client` and returns its result's target, failing on anything else.
	private static func run(
		_ action: AutomationCommand.Action,
		target: UUID,
		name: String? = nil,
		destination: UUID? = nil,
		client clientID: UUID,
		session: UUID,
		store: TestStoreOf<AppFeature>,
		responses: LockIsolated<[AutomationResult]>
	) async throws -> UUID? {
		let client = try #require(store.state.automationPreferences.clients.first { $0.id == clientID })
		let items = AutomationInventoryBuilder.items(client: client, organization: store.state.workspace, snapshots: [:])
		let revision = try #require(items.first { $0.id == target }?.revision, "\(action) target not granted")
		let request = AutomationRequest(
			id: UUID(),
			clientID: client.id,
			sessionID: session,
			operation: .command(.init(
				operationID: UUID(),
				action: action,
				targetID: target,
				expectedRevision: revision,
				destinationID: destination,
				destinationRevision: destination.flatMap { id in items.first { $0.id == id }?.revision },
				name: name
			))
		)
		let count = responses.value.count
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		guard
			responses.value.count > count,
			case let .command(result) = responses.value.last
		else {
			Issue.record("\(action) failed: \(String(describing: responses.value.last))")
			return nil
		}
		return result.targetID
	}
}
