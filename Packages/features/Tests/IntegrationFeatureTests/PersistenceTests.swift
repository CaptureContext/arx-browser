import AppFeature
import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

extension IntegrationFeatureTests {
	@Test
	internal func versionOneMigratesOnlyOnSuccessfulSave() async throws {
		let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
			.appendingPathComponent("workspace.json")
		defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
		try FileManager.default.createDirectory(
			at: file.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		struct Legacy: Encodable {
			var version: Int = 1
			var organization: BrowserOrganization
		}
		let original = try JSONEncoder().encode(Legacy(organization: fixture()))
		try original.write(to: file)
		let client = BrowserWorkspaceClient(file: file)
		expectNoDifference(try client.load(), fixture())
		expectNoDifference(try Data(contentsOf: file), original)
		try client.save(fixture())
		let header = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
		expectNoDifference(header["version"] as? Int, 4)
		expectNoDifference(try Data(contentsOf: file.appendingPathExtension("backup")), original)
	}

	@Test
	internal func failedReplacementKeepsDiskAndRetrySavesLatestState() async throws {
		let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
			.appendingPathComponent("workspace.json")
		defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
		try BrowserWorkspaceClient(file: file).save(fixture())
		let failure = LockIsolated(true)
		let client = BrowserWorkspaceClient(file: file) { data, destination in
			if destination == file, failure.value { throw CocoaError(.fileWriteOutOfSpace) }
			try data.write(to: destination, options: .atomic)
		}
		var edited = fixture()
		edited.spaces[0].name = "Renamed"
		#expect(throws: (any Error).self) { try client.save(edited) }
		expectNoDifference(try BrowserWorkspaceClient(file: file).load(), fixture())
		failure.setValue(false)
		try client.save(edited)
		expectNoDifference(try BrowserWorkspaceClient(file: file).load(), edited)
	}

	@Test
	internal func futureVersionAndExternalChangesAreNeverOverwritten() async throws {
		let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
			.appendingPathComponent("workspace.json")
		defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
		let client = BrowserWorkspaceClient(file: file)
		try client.save(fixture())
		try client.save(fixture())
		let future = Data(#"{"version":999}"#.utf8)
		try future.write(to: file)
		#expect(throws: (any Error).self) { try client.save(fixture()) }
		#expect(throws: (any Error).self) { try BrowserWorkspaceClient(file: file).load() }
		expectNoDifference(try Data(contentsOf: file), future)
	}

	@Test
	internal func recoveryPreservesDamagedOriginalAndUsesValidatedBackup() async throws {
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("workspace.json")
		let client = BrowserWorkspaceClient(file: file)
		try client.save(fixture())
		try client.save(fixture())
		let damaged = Data("damaged".utf8)
		try damaged.write(to: file)
		let recovered = BrowserWorkspaceClient(file: file)
		let result = try recovered.loadWithRecovery()
		#expect(result.usedBackup)
		expectNoDifference(result.organization, fixture())
		expectNoDifference(try Data(contentsOf: file), damaged)
		try recovered.save(fixture())
		let contents = try FileManager.default.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: nil
		)
		let preserved = try #require(contents.first { $0.lastPathComponent.contains("damaged-") })
		expectNoDifference(try Data(contentsOf: preserved), damaged)
	}

	@Test
	internal func saveFailureKeepsPendingEditsAndBlocksQuitUntilRecovery() async throws {
		let organization = fixture()
		let initial = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		let store = TestStore(initialState: initial) { AppFeature() }
		await store.send(.main(.delegate(.organizationChanged(organization)))) {
			$0.unsavedOrganization = organization
		}
		await store.receive(\.delegate.save)
		await store.send(.event(.saveFailed("Disk full"))) { $0.persistenceError = "Disk full" }
		await store.send(.ui(.quit)) { $0.quitAfterSaving = true }
		await store.receive(\.ui.retrySave)
		await store.receive(\.delegate.save)
		#expect(!store.state.shouldQuit)
		await store.send(.event(.saveSucceeded(organization))) {
			$0.persistenceError = nil
			$0.unsavedOrganization = nil
		}
		await store.receive(\.ui.quit) { $0.checkingQuit = true }
		await store.receive(\.event.quitDecision) {
			$0.checkingQuit = false
			$0.quitAfterSaving = false
			$0.shouldQuit = true
		}
		await store.receive(\.main.viewer.suspend)
		await store.receive(\.main.viewer.panes) {
			$0.main.viewer.item.generation = 1
			$0.main.viewer.observationGeneration = 1
		}
	}
}

extension IntegrationFeatureTests {
	@Test
	internal func discardingWorkspaceChangesStillHonorsPageCancellation() async throws {
		let organization = fixture()
		var state = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		state.unsavedOrganization = organization
		state.persistenceError = "Disk full"
		state.quitAfterSaving = true

		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.browserEngine.permitsClosing = { _ in false }
		}

		await store.send(.ui(.discardAndQuit)) {
			$0.discardUnsavedChangesOnQuit = true
		}
		await store.receive(\.ui.quit) {
			$0.checkingQuit = true
		}
		await store.receive(\.event.quitDecision) {
			$0.checkingQuit = false
			$0.quitAfterSaving = false
			$0.discardUnsavedChangesOnQuit = false
		}

		#expect(!store.state.shouldQuit)
		expectNoDifference(store.state.unsavedOrganization, organization)
	}
}

extension IntegrationFeatureTests {
	@Test
	internal func legacyDirectoryOwnerSurvivesMigrationRemovalAndRestart() throws {
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let file = directory.appendingPathComponent("workspace.json")
		let original = fixture()
		let encodedOrganization = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
		var legacyOrganization = try #require(encodedOrganization as? [String: Any])
		legacyOrganization.removeValue(forKey: "legacyProfileID")
		let legacy = try JSONSerialization.data(
			withJSONObject: [
				"version": 2,
				"revision": 4,
				"organization": legacyOrganization,
			]
		)
		try legacy.write(to: file)
		let client = BrowserWorkspaceClient(file: file)
		var restored = try #require(try client.load())
		expectNoDifference(restored.legacyProfileID, original.profiles[0].id)
		expectNoDifference(try Data(contentsOf: file), legacy)

		let replacement = Profile.ID(rawValue: UUID(40))
		restored.profiles = [.init(id: replacement, name: "Replacement")]
		restored.tabs = []
		restored.spaces = .init(
			uniqueElements: original.spaces.map { Space(id: $0.id, profileID: replacement, name: $0.name) }
		)
		try client.save(restored)
		let reopened = try #require(try BrowserWorkspaceClient(file: file).load())
		expectNoDifference(reopened.legacyProfileID, original.profiles[0].id)
		#expect(reopened.profiles.first?.id != reopened.legacyProfileID)
		expectNoDifference(reopened.spaces.map(\.profileID), [replacement, replacement])
		let header = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
		expectNoDifference(header["version"] as? Int, 4)
	}
}
