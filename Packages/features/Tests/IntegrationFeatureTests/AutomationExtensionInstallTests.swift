import BrowserAutomationClient
import BrowserCore
import BrowserExtensionsClient
import CustomDump
import ExtensionsFeature
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-951. `browser_settings` `installExtension`: the Extensions sheet's review is the approval,
/// whatever the client's approval policy, and the result says how it ended.
@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationExtensionInstallTests {
	private typealias Fixture = AutomationManagementFeatureTests

	private static let installedID: String = String(repeating: "a", count: 32)
	private static let storeID: String = String(repeating: "b", count: 32)

	@Test(arguments: [true, false])
	func theReviewAsksWhateverTheApprovalPolicy(accept: Bool) async throws {
		let state = Fixture.state()
		#expect(state.automationPreferences.clients[0].approvalPolicy == .never)
		let engine = Engine()
		let (store, responses) = Fixture.store(state) { $0.browserExtensions = engine.client() }

		let revision = try await Self.revision(store, responses)
		await store.send(.automation(.event(.host(.request(Self.install(revision))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		// No approval prompt: the Extensions sheet shows the review, naming the client.
		#expect(store.state.automation.pending[Self.installRequest]?.awaitingApproval != true)
		let sheet = store.state.settings.extensions
		#expect(sheet.isPresented && sheet.profile?.id == Fixture.work)
		let prompt = try #require(sheet.pendingInstallation)
		expectNoDifference(prompt.candidate.extensionID, Self.storeID)
		#expect(sheet.reviewRequester == "Agent")
		// The section read, then the sheet's own load: the install never reads the profile itself.
		expectNoDifference(engine.workReads.value, 2)
		#expect(engine.resolved.value.isEmpty, "Nothing installs before the person answers")
		#expect(responses.value.count == 1, "The install waits for the review")

		await store.send(.settings(.extensions(.ui(.respondToInstallation(prompt, accept)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(engine.resolved.value, [accept])
		guard case let .settings(result) = responses.value.last else {
			Issue.record("No result: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(result.installation, .init(
			profileID: Fixture.work.rawValue,
			extensionID: Self.storeID,
			outcome: accept ? .installed : .declined,
			name: "Store item",
			version: "3.1"
		))
		expectNoDifference(result.targetID, Self.storeID)
		expectNoDifference(
			result.extensions?.items.map(\.id),
			accept ? [Self.installedID, Self.storeID] : [Self.installedID]
		)
		#expect(result.extensions?.canInstall == true)
		#expect(store.state.automation.pending[Self.installRequest] == nil)
	}

	@Test(arguments: ["cancel", "disconnect"])
	func aReviewNobodyWaitsForGoesAway(how: String) async throws {
		let engine = Engine()
		let (store, responses) = Fixture.store(Fixture.state()) { $0.browserExtensions = engine.client() }

		let revision = try await Self.revision(store, responses)
		await store.send(.automation(.event(.host(.request(Self.install(revision))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		let prompt = try #require(store.state.settings.extensions.pendingInstallation)

		let event: AutomationHostEvent = how == "cancel" ? .cancel(Self.installRequest) : .disconnected(sessionID: UUID(81))
		await store.send(.automation(.event(.host(event))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(store.state.settings.extensions.pendingInstallation == nil)
		#expect(store.state.settings.extensions.automationInstall == nil)
		expectNoDifference(engine.cancelled.value, [prompt])

		// A late click on the old review installs nothing.
		await store.send(.settings(.extensions(.ui(.respondToInstallation(prompt, true)))))
		await store.finish()
		#expect(engine.resolved.value.isEmpty)
	}

	@Test
	func anOpenFilePickerIsBusy() async throws {
		var state = Fixture.state()
		let engine = Engine()
		let inventory = BrowserExtensionInventory(id: UUID(), profileID: Fixture.work, revision: 1, extensions: [])
		state.settings.extensions.profile = .init(id: Fixture.work, name: "Work")
		state.settings.extensions.isPresented = true
		state.settings.extensions.inventory = inventory
		state.settings.extensions.packageSelection = .init(inventory: inventory, expectedExtensionID: nil)
		let (store, responses) = Fixture.store(state) { $0.browserExtensions = engine.client() }

		await store.send(.automation(.event(.host(.request(Self.install(String(repeating: "0", count: 64)))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(responses.value.last, .failure(.busy))
		expectNoDifference(store.state.settings.extensions.inventory, inventory, "The picker's inventory stays")
		#expect(store.state.settings.extensions.packageSelection != nil)
	}

	@Test
	func anInstalledItemAnswersWithoutAReview() async throws {
		let engine = Engine()
		let (store, responses) = Fixture.store(Fixture.state()) { $0.browserExtensions = engine.client() }

		let revision = try await Self.revision(store, responses)
		await store.send(.automation(.event(.host(.request(Self.install(revision, extensionID: Self.installedID))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		guard case let .settings(result) = responses.value.last else {
			Issue.record("No result: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(result.installation?.outcome, .alreadyInstalled)
		expectNoDifference(result.extensions?.items.map(\.id), [Self.installedID])
		#expect(store.state.settings.extensions.pendingInstallation == nil)
		#expect(store.state.settings.extensions.automationInstall == nil)
		#expect(engine.prepared.value.isEmpty)
	}

	@Test
	func aFailedDownloadReportsItsReason() async throws {
		let engine = Engine(failure: .invalidPackage)
		let (store, responses) = Fixture.store(Fixture.state()) { $0.browserExtensions = engine.client() }

		let revision = try await Self.revision(store, responses)
		await store.send(.automation(.event(.host(.request(Self.install(revision))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		guard case let .settings(result) = responses.value.last else {
			Issue.record("No result: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(result.installation?.outcome, .failed)
		expectNoDifference(result.installation?.reason, "invalidPackage")
		#expect(store.state.settings.extensions.pendingInstallation == nil)
	}

	@Test
	func anUnattendedRunCantAsk() async throws {
		var state = Fixture.state()
		state.automation.isUnattended = true
		let engine = Engine()
		let (store, responses) = Fixture.store(state) { $0.browserExtensions = engine.client() }

		await store.send(.automation(.event(.host(.request(Self.install(String(repeating: "0", count: 64)))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(responses.value.last, .failure(.userActionRequired))
		#expect(!store.state.settings.extensions.isPresented && engine.prepared.value.isEmpty)
	}

	@Test
	func itIsOfferedOnlyWhereArxCanInstall() async throws {
		let engine = Engine(importAvailable: false)
		let (store, responses) = Fixture.store(Fixture.state()) { $0.browserExtensions = engine.client() }

		let revision = try await Self.revision(store, responses)
		guard case let .settings(list) = responses.value.last else { return }
		#expect(list.extensions?.canInstall == false)

		await store.send(.automation(.event(.host(.request(Self.install(revision))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(responses.value.last, .failure(.installationUnavailable))
		#expect(AutomationFailure.installationUnavailable.message != nil)
		#expect(!store.state.settings.extensions.isPresented)
	}

	@Test
	func anotherProfileOrAnOldRevisionIsRefused() async throws {
		let engine = Engine()
		let (store, responses) = Fixture.store(Fixture.state()) { $0.browserExtensions = engine.client() }

		await store.send(.automation(.event(.host(.request(Self.install(
			String(repeating: "0", count: 64),
			profileID: Fixture.home
		))))))
		await store.finish()
		expectNoDifference(responses.value.last, .failure(.denied))

		await store.send(.automation(.event(.host(.request(Self.install(
			String(repeating: "0", count: 64),
			id: UUID(141),
			operationID: UUID(161)
		))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(responses.value.last, .failure(.staleTarget))
		#expect(store.state.settings.extensions.automationInstall == nil && engine.prepared.value.isEmpty)
	}

	// MARK: - Helpers

	private static let installRequest: UUID = UUID(140)

	/// A profile with one extension, whose store install adds a second.
	@MainActor
	private final class Engine {
		let prepared = LockIsolated<[BrowserWebstoreImportRequest]>([])
		let resolved = LockIsolated<[Bool]>([])
		let cancelled = LockIsolated<[BrowserExtensionInstallPrompt]>([])

		/// Reads of the work profile's extensions.
		let workReads = LockIsolated(0)
		private let installed = LockIsolated(false)
		private let revision = LockIsolated<UInt64>(1)
		private let failure: BrowserExtensionsClient.Failure?
		private let importAvailable: Bool

		init(
			importAvailable: Bool = true,
			failure: BrowserExtensionsClient.Failure? = nil
		) {
			self.importAvailable = importAvailable
			self.failure = failure
		}

		func client() -> BrowserExtensionsClient {
			.init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { [self] profileID in
					if profileID == Fixture.work { workReads.withValue { $0 += 1 } }
					return inventory(profileID)
				},
				resolveInstallation: { [self] prompt, accept in
					resolved.withValue { $0.append(accept) }
					if accept {
						installed.setValue(true)
						revision.withValue { $0 += 1 }
					}
					return inventory(prompt.profileID)
				},
				cancelInstallation: { [self] prompt in cancelled.withValue { $0.append(prompt) } },
				webstoreImportAvailability: { [importAvailable] in importAvailable },
				prepareWebstoreImport: { [self] request in
					prepared.withValue { $0.append(request) }
					if let failure { throw failure }
					return .init(
						id: UUID(150),
						profileID: request.profileID,
						inventoryID: request.inventoryID,
						revision: request.revision,
						candidate: .init(
							extensionID: request.extensionID,
							name: "Store item",
							version: "3.1",
							packageSHA256: String(repeating: "c", count: 64),
							sourceBasename: "Chrome Web Store",
							isUpdate: false,
							requiredPermissions: .init(apis: ["storage"], hosts: []),
							optionalPermissions: .init(apis: [], hosts: []),
							warnings: []
						)
					)
				}
			)
		}

		/// The revision moves only when the profile's extensions change.
		private func inventory(_ profileID: Profile.ID) -> BrowserExtensionInventory {
			var extensions: [BrowserExtension] = [
				.init(id: AutomationExtensionInstallTests.installedID, name: "Fixture", version: "1", state: .enabled, canDisable: true, canRemove: true),
			]
			if installed.value {
				extensions.append(.init(
					id: AutomationExtensionInstallTests.storeID,
					name: "Store item",
					version: "3.1",
					fromWebStore: true,
					state: .enabled,
					canDisable: true,
					canRemove: true
				))
			}
			return .init(id: UUID(), profileID: profileID, revision: revision.value, extensions: extensions)
		}
	}

	/// Reads the work profile's extensions and returns the revision the install passes.
	private static func revision(
		_ store: TestStoreOf<AppFeature>,
		_ responses: LockIsolated<[AutomationResult]>
	) async throws -> String {
		let read = AutomationRequest(
			id: UUID(139),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .settings(.init(.read(.extensions, profileID: Fixture.work.rawValue)))
		)
		await store.send(.automation(.event(.host(.request(read)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		guard case let .settings(list) = responses.value.last else {
			Issue.record("No extension list: \(String(describing: responses.value.last))")
			throw AutomationFailure.invalidRequest
		}
		return list.revision
	}

	private static func install(
		_ revision: String,
		profileID: Profile.ID = Fixture.work,
		extensionID: String = storeID,
		id: UUID = installRequest,
		operationID: UUID = UUID(160)
	) -> AutomationRequest {
		.init(
			id: id,
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .settings(.init(.change(.init(
				operationID: operationID,
				expectedRevision: revision,
				edit: .installExtension(profileID: profileID.rawValue, extensionID: extensionID)
			))))
		)
	}
}
