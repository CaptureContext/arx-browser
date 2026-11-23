import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct WorkspacePersistenceTests {
	@Test
	internal func securitySyncFailureAfterRenameCanRetryWithoutLosingThePrivacyLock() async throws {
		let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: root) }
		let file = root.appendingPathComponent("workspace.json")
		let fail = LockIsolated(true)
		let workspace = BrowserWorkspaceClient(
			file: file,
			securitySynchronizer: { _ in
				if fail.value { throw BrowserWorkspaceClient.Failure.synchronizationFailed }
			}
		)
		let organization = IntegrationFeatureTests().fixture()
		try workspace.save(organization)
		let lock = UUID()
		var preferences = BrowserPreferences()
		preferences.automation.authenticationLockID = lock
		#expect(throws: BrowserWorkspaceClient.Failure.self) {
			try workspace.save(organization, preferences: preferences, synchronizeSecurityChange: true)
		}

		// Rename happened: failed durability must not be mistaken for no write.
		expectNoDifference(
			try BrowserWorkspaceClient(file: file).loadWithRecovery().preferences.automation.authenticationLockID,
			lock
		)
		fail.setValue(false)
		try workspace.save(organization, preferences: preferences, synchronizeSecurityChange: true)
		expectNoDifference(try BrowserWorkspaceClient(file: file).loadWithRecovery().preferences, preferences)
	}

	@Test(arguments: [false, true])
	internal func staleBackupRecoveryDisablesAndPersistsFreshAuthorization(missingPrimary: Bool) async throws {
		let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: root) }
		let file = root.appendingPathComponent("workspace.json")
		let organization = IntegrationFeatureTests().fixture()
		let clientID = UUID()
		let grant = UUID()
		let fresh = UUID()
		var preferences = BrowserPreferences()
		preferences.automation = .init(
			isEnabled: true,
			clients: [
				.init(
					id: clientID,
					name: "Recognizable",
					credentialDigest: String(repeating: "a", count: 64),
					scopes: [.space(organization.spaces[0].id, profileID: organization.profiles[0].id)],
					allowsRead: true,
					allowsScreenshots: true,
					allowsPageContent: true,
					allowsPageInteraction: true,
					allowsSignIn: true,
					allowsManagement: true,
					mutationGrantUntil: .distantFuture,
					grantRevision: grant
				),
			]
		)
		let original = BrowserWorkspaceClient(file: file)
		try original.save(organization, preferences: preferences)
		preferences.automation.authenticationLockID = UUID()
		try original.save(organization, preferences: preferences, synchronizeSecurityChange: true)
		if missingPrimary {
			try FileManager.default.removeItem(at: file)
		} else {
			try Data("corrupt".utf8).write(to: file)
		}
		let recovered = BrowserWorkspaceClient(file: file)
		let loaded = try recovered.loadWithRecovery().applyingAutomationRecoveryPolicy(makeID: { fresh })
		#expect(loaded.usedBackup && !loaded.preferences.automation.isEnabled)
		#expect(!loaded.preferences.automation.clients[0].allowsRead && loaded.preferences.automation.clients[0].scopes.isEmpty)
		expectNoDifference(loaded.preferences.automation.clients[0].grantRevision, fresh)
		try recovered.save(
			try #require(loaded.organization),
			preferences: loaded.preferences,
			synchronizeSecurityChange: true
		)
		let restarted = try BrowserWorkspaceClient(file: file).loadWithRecovery()
		#expect(!restarted.usedBackup && !restarted.preferences.automation.isEnabled)
		#expect(!restarted.preferences.automation.clients[0].allowsSignIn)
		expectNoDifference(restarted.preferences, loaded.preferences)
	}

	@Test(arguments: [false, true])
	internal func heldOlderSaveUsesTheCurrentWorkspaceAndPreferences(saveLatestFirst: Bool) async throws {
		let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace.json")
		defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
		let older = IntegrationFeatureTests().fixture()
		var current = older
		current.spaces[0].name = "Latest edit"
		current.spaces.removeLast()
		let client = BrowserWorkspaceClient(file: file)
		try client.save(older)
		let document = WorkspaceDocument(client: client, organization: current, preferences: .init())
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: current, spaceID: current.spaces[0].id))
		}
		state.settings.$chromeAppearance.withLock { $0.grain.intensity = 0.8 }
		state.unsavedOrganization = current
		state.downloadsReady = true
		var configured: [BrowserOrganization] = []
		let store = Store(initialState: state) {
			AppFeature()
			WorkspacePersistence(workspace: client)
		} withDependencies: {
			$0.workspaceDocument = document
			$0.browserDownloads.configure = { configured.append($0) }
			$0.continuousClock = ImmediateClock()
		}
		if saveLatestFirst { await store.send(.delegate(.save(current))).finish() }

		// This action was captured before the newer mutation and arrives after it.
		await store.send(.delegate(.save(older))).finish()
		let persisted = try BrowserWorkspaceClient(file: file).loadWithRecovery()
		expectNoDifference(persisted.organization, current)
		expectNoDifference(persisted.preferences, document.preferences)
		expectNoDifference(persisted.preferences.grainIntensity, 0.8)
		expectNoDifference(configured.last, current)
		expectNoDifference(store.workspace, current)
		#expect(store.unsavedOrganization == nil)
	}

	@Test
	internal func failedCurrentWriteKeepsPendingStateAndRetryPersistsIt() async throws {
		let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace.json")
		defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
		let older = IntegrationFeatureTests().fixture()
		try BrowserWorkspaceClient(file: file).save(older)
		var current = older
		current.spaces[0].name = "Retained unsaved edit"
		let fails = LockIsolated(true)
		let client = BrowserWorkspaceClient(file: file) { data, destination in
			if destination == file, fails.value { throw CocoaError(.fileWriteOutOfSpace) }
			try data.write(to: destination, options: .atomic)
		}
		var state = AppFeature.State(main: .init(organization: current, spaceID: current.spaces[0].id))
		state.unsavedOrganization = current
		let store = Store(initialState: state) {
			AppFeature()
			WorkspacePersistence(workspace: client)
		} withDependencies: {
			$0.continuousClock = ImmediateClock()
		}
		await store.send(.delegate(.save(older))).finish()
		expectNoDifference(store.unsavedOrganization, current)
		#expect(store.persistenceError != nil)
		expectNoDifference(try BrowserWorkspaceClient(file: file).load(), older)
		fails.setValue(false)
		await store.send(.ui(.retrySave)).finish()
		expectNoDifference(try BrowserWorkspaceClient(file: file).load(), current)
		#expect(store.unsavedOrganization == nil && store.persistenceError == nil)
	}

	@Test
	internal func discardIntentIgnoresHeldOrdinarySaves() async throws {
		let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace.json")
		defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
		let older = IntegrationFeatureTests().fixture()
		let client = BrowserWorkspaceClient(file: file)
		try client.save(older)
		var current = older
		current.spaces[0].name = "Discarded edit"
		var state = AppFeature.State(main: .init(organization: current, spaceID: current.spaces[0].id))
		state.unsavedOrganization = current
		state.discardUnsavedChangesOnQuit = true
		state.downloadsReady = true
		let store = Store(initialState: state) {
			AppFeature()
			WorkspacePersistence(workspace: client)
		} withDependencies: {
			$0.browserDownloads.configure = { _ in Issue.record("Discarded saves must not reconfigure native downloads") }
		}
		await store.send(.delegate(.save(current))).finish()
		expectNoDifference(try BrowserWorkspaceClient(file: file).load(), older)
		expectNoDifference(store.unsavedOrganization, current)
	}

	@Test
	internal func synchronizationFailureReachesTheInterfaceAsLocalizedText() async throws {
		let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace.json")
		defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
		let organization = IntegrationFeatureTests().fixture()
		let client = BrowserWorkspaceClient(
			file: file,
			securitySynchronizer: { _ in
				throw BrowserWorkspaceClient.Failure.synchronizationFailed
			}
		)
		try client.save(organization)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.automationPreferences.authenticationLockID = UUID()
		state.unsavedOrganization = organization
		let store = Store(initialState: state) {
			AppFeature()
			WorkspacePersistence(workspace: client)
		}
		await store.send(.delegate(.save(organization))).finish()
		expectNoDifference(
			store.persistenceError,
			"The security change could not be synchronized to storage. Automation remains paused."
		)
	}

	@Test
	internal func everyWorkspaceFailureHasItsOwnCatalogMessage() {
		let workspaceFailures: [BrowserWorkspaceClient.Failure] = [
			.unsupportedVersion(9),
			.unsupportedOrganization,
			.changedOnDisk,
			.synchronizationFailed,
		]
		let retirementFailures: [BrowserProfileRetirementStore.Failure] = [
			.ownershipChanged,
			.corrupt,
			.busy,
			.io,
			.limit,
		]
		let messages = workspaceFailures.map { WorkspaceFailurePresentation.message(for: $0 as any Error) }
		+ retirementFailures.map { WorkspaceFailurePresentation.message(for: $0 as any Error) }

		expectNoDifference(Set(messages).count, messages.count)
		for message in messages {
			// An unresolved catalog lookup returns its dotted key.
			#expect(!message.isEmpty && !message.contains(".failure."))
		}
		expectNoDifference(
			WorkspaceFailurePresentation.message(for: BrowserWorkspaceClient.Failure.unsupportedVersion(9)),
			"Your spaces and tabs were saved in format 9. Open them with a newer Arx version."
		)
	}

	@Test
	internal func otherErrorsKeepTheirSystemDescription() {
		let error = CocoaError(.fileWriteOutOfSpace)
		expectNoDifference(WorkspaceFailurePresentation.message(for: error), error.localizedDescription)
	}
}

// MARK: - Coalescing

extension WorkspacePersistenceTests {
	@Test
	internal func burstOfSaveRequestsWritesOnceAfterTheCoalescingInterval() async throws {
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("workspace.json")
		let writes = LockIsolated(0)
		let workspace = BrowserWorkspaceClient(file: file) { data, destination in
			if destination == file { writes.withValue { $0 += 1 } }
			try data.write(to: destination, options: .atomic)
		}
		let organization = IntegrationFeatureTests().fixture()
		let clock = TestClock()
		let initialState = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: initialState) {
			WorkspacePersistence(workspace: workspace)
		} withDependencies: {
			$0.continuousClock = clock
		}

		for _ in 0..<5 {
			await store.send(.delegate(.save(organization)))
		}
		await clock.advance(by: WorkspacePersistence.coalescingInterval)
		await store.receive(\.flushWorkspaceSave)
		await store.receive(\.event.saveSucceeded)

		expectNoDifference(writes.value, 1)
		expectNoDifference(try BrowserWorkspaceClient(file: file).load(), organization)
	}

	@Test
	internal func quitFlushesWithoutWaiting() async throws {
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("workspace.json")
		let workspace = BrowserWorkspaceClient(file: file)
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))
		state.quitAfterSaving = true
		let store = TestStore(initialState: state) {
			WorkspacePersistence(workspace: workspace)
		} withDependencies: {
			$0.continuousClock = TestClock()
		}

		await store.send(.delegate(.save(organization)))
		await store.receive(\.event.saveSucceeded)
		expectNoDifference(try BrowserWorkspaceClient(file: file).load(), organization)
	}

	@Test
	internal func anObsoleteTicketNeverOverwritesANewerSnapshot() async throws {
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("workspace.json")
		let workspace = BrowserWorkspaceClient(file: file)
		let older = IntegrationFeatureTests().fixture()
		var newer = IntegrationFeatureTests().fixture()
		newer.spaces[0].name = "Newer"
		let olderTicket = workspace.reserveSaveTicket()
		let newerTicket = workspace.reserveSaveTicket()

		#expect(try await workspace.save(newer, ticket: newerTicket))
		#expect(try await workspace.save(older, ticket: olderTicket) == false)
		expectNoDifference(try BrowserWorkspaceClient(file: file).load(), newer)
	}
}

extension WorkspacePersistenceTests {
	/// Clearing Arx before an import retires the old profiles only once the fresh workspace is
	/// saved, so that save is synchronized to disk (DEV-833).
	@Test
	internal func theSaveBeforeClearingRetiresProfilesIsSynchronized() async throws {
		let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: root) }
		let synchronized = LockIsolated(0)
		let workspace = BrowserWorkspaceClient(
			file: root.appendingPathComponent("workspace.json"),
			securitySynchronizer: { _ in synchronized.withValue { $0 += 1 } }
		)
		let organization = IntegrationFeatureTests().fixture()
		try workspace.save(organization)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.migrationClearing = .init(
			fresh: .init(profileID: .init(rawValue: UUID(80)), spaceID: .init(rawValue: UUID(81))),
			retiring: organization.profiles.map(\.id),
			step: .saving
		)
		let store = TestStore(initialState: state) { WorkspacePersistence(workspace: workspace) }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.delegate(.save(organization)))
		await store.receive(\.event.saveSucceeded)
		#expect(synchronized.value > 0)
	}
}
