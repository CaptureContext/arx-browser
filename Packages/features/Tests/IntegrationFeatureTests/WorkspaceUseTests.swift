import BrowserCore
import BrowserWorkspaceClient
import Foundation
import Testing
import WorkspaceDatabase
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// Opening a space records its use in the synced store (DEV-980), even when no saved row changes,
/// so a deletion another Mac synced spares it.
@Suite(.dependencies)
@MainActor
internal struct WorkspaceUseTests {
	@Test
	internal func showingASpaceRecordsItsUse() async throws {
		let organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let directory: URL = .temporaryDirectory.appendingPathComponent("WorkspaceUseTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let client: BrowserWorkspaceClient = .init(
			file: directory.appendingPathComponent("arx-workspace.json"),
			storage: .sqlite,
			separatePreferencesConnection: true
		)
		_ = try client.loadWithRecovery()
		try client.save(organization)
		let database: WorkspaceDatabase = try #require(client.workspaceDatabase)

		// The first save recorded everything as edited.
		try await database.database.write { db in try UsageRecord.delete().execute(db) }
		let document: WorkspaceDocument = .init(client: client, organization: organization, preferences: .init())

		let first: Space.ID = organization.spaces[0].id
		let second: Space.ID = organization.spaces[1].id
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: first))
		}
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.workspaceDocument = document
			$0.workspaceSync.isAvailable = { true }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.main(.sidebar(.ui(.spaceSelected(second)))))
		await store.skipReceivedActions(strict: false)
		await store.finish()

		let used: Set<UUID> = try await database.database.read { db in
			Set(try UsageRecord.all.fetchAll(db).map(\.itemID))
		}
		#expect(used.contains(second.rawValue))
		#expect(used.contains(organization.profiles[0].id.rawValue))
		#expect(!used.contains(first.rawValue))
	}
}
