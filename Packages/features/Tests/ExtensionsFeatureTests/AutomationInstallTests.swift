import BrowserCore
import BrowserExtensionsClient
import CustomDump
import ExtensionsFeature
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-951. An MCP client's `installExtension` goes through the same review as Add to Arx,
/// and the sheet reports how it ended.
@Suite(.dependencies)
@MainActor
internal struct AutomationInstallTests {
	private typealias Outcome = ExtensionsFeature.AutomationInstallOutcome

	private let profile: Profile = .init(id: .init(rawValue: UUID(1)), name: "Personal")
	private let other: Profile = .init(id: .init(rawValue: UUID(2)), name: "Work")
	private let installedID: String = String(repeating: "a", count: 32)
	private let storeID: String = String(repeating: "b", count: 32)
	private let requestID: UUID = UUID(70)

	@Test(arguments: [true, false])
	internal func theReviewIsTheApproval(accept: Bool) async throws {
		let before = inventory()
		let after = inventory(revision: 2, adding: storeID)
		let prompt = prompt(in: before)
		let imported = LockIsolated<[BrowserWebstoreImportRequest]>([])
		let resolved = LockIsolated<[Bool]>([])
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let store = Store(initialState: loaded(before)) {
			Self.recording(outcomes)
		} withDependencies: {
			$0.browserExtensions = client(
				prepare: { request in
					imported.withValue { $0.append(request) }
					return prompt
				},
				resolve: { received, accepted in
					#expect(received == prompt)
					resolved.withValue { $0.append(accepted) }
					return accepted ? after : before
				}
			)
		}

		await store.send(.automationInstallRequested(request())).finish()

		expectNoDifference(imported.value, [.init(inventory: before, extensionID: storeID)])
		expectNoDifference(store.pendingInstallation, prompt)
		#expect(store.reviewRequester == "Codex")
		#expect(resolved.value.isEmpty && outcomes.value.isEmpty, "Nothing installs before the review is answered")

		await store.send(.ui(.respondToInstallation(prompt, accept))).finish()

		expectNoDifference(resolved.value, [accept])
		expectNoDifference(
			outcomes.value,
			[requestID: accept ? .installed(name: "Store item", version: "3.1") : .declined(name: "Store item", version: "3.1")]
		)
		#expect(store.automationInstall == nil && store.reviewRequester == nil && !store.isWorking)
		if accept { #expect(store.selectedID == storeID) }
	}

	@Test
	internal func nothingDownloadsBeforeTheAppChecksTheLoadedProfile() async throws {
		let before = inventory()
		let prepared = LockIsolated(0)
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let store = Store(initialState: loaded(before)) {
			Self.recording(outcomes, proceeds: false)
		} withDependencies: {
			$0.browserExtensions = client(prepare: { _ in
				prepared.withValue { $0 += 1 }
				return prompt(in: before)
			})
		}

		await store.send(.automationInstallRequested(request())).finish()
		#expect(store.automationInstall?.stage == .checking && prepared.value == 0)
		// Holding the sheet: the person can't start a package or folder install meanwhile.
		await store.send(.ui(.choosePackage(nil))).finish()
		#expect(store.packageSelection == nil)
		await store.send(.automationInstallProceed(UUID(71))).finish()
		#expect(prepared.value == 0, "Another request's go-ahead changes nothing")

		await store.send(.automationInstallProceed(requestID)).finish()

		#expect(prepared.value == 1 && store.pendingInstallation != nil && outcomes.value.isEmpty)
	}

	@Test
	internal func anInstalledItemReportsSoWithoutAReview() async throws {
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let store = Store(initialState: loaded(inventory())) {
			Self.recording(outcomes)
		} withDependencies: {
			$0.browserExtensions = client(prepare: { _ in
				Issue.record("An installed item must not download")
				throw BrowserExtensionsClient.Failure.failed
			})
		}

		await store.send(.automationInstallRequested(request(extensionID: installedID))).finish()

		expectNoDifference(outcomes.value, [requestID: .alreadyInstalled(name: "Fixture", version: "1")])
		#expect(store.pendingInstallation == nil && store.selectedID == installedID && !store.isWorking)
	}

	@Test(arguments: [
		BrowserExtensionsClient.Failure.invalidPackage,
		.blockedByPolicy,
		.timeout,
		.invalidManifest("line 3"),
	])
	internal func aPackageTheStoreOrChromiumRefusesFailsWithItsReason(_ failure: BrowserExtensionsClient.Failure) async throws {
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let store = Store(initialState: loaded(inventory())) {
			Self.recording(outcomes)
		} withDependencies: {
			$0.browserExtensions = client(prepare: { _ in throw failure })
		}

		await store.send(.automationInstallRequested(request())).finish()

		expectNoDifference(outcomes.value, [requestID: .failed(failure, name: nil, version: nil)])
		#expect(store.pendingInstallation == nil && store.automationInstall == nil && store.error == failure)
	}

	@Test(arguments: [1, 2, 3])
	internal func aProfileThatKeepsMovingWhileTheStoreDownloadsIsReadAgain(staleResults: Int) async throws {
		let reads = LockIsolated(0)
		let imported = LockIsolated<[BrowserWebstoreImportRequest]>([])
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let store = Store(initialState: loaded(inventory())) {
			Self.recording(outcomes)
		} withDependencies: {
			$0.browserExtensions = client(
				prepare: { request in
					imported.withValue { $0.append(request) }
					if imported.value.count <= staleResults { throw BrowserExtensionsClient.Failure.staleInventory }
					return prompt(in: inventory(revision: request.revision))
				},
				inspect: { _ in

					// Each read finds the just-started profile moved on again.
					reads.withValue { $0 += 1 }
					return inventory(revision: UInt64(reads.value + 1))
				}
			)
		}

		await store.send(.automationInstallRequested(request())).finish()
		let attempts = min(staleResults + 1, ExtensionsFeature.AutomationInstall.maximumStaleAttempts)
		await waitWhile { imported.value.count < attempts || (store.isWorking && store.pendingInstallation == nil) }

		// Every preparation after the first uses the sheet's own new read of the profile.
		expectNoDifference(imported.value.map(\.revision), (1...attempts).map(UInt64.init))
		expectNoDifference(reads.value, attempts - 1)
		if staleResults >= ExtensionsFeature.AutomationInstall.maximumStaleAttempts {
			expectNoDifference(outcomes.value, [requestID: .failed(.staleInventory, name: nil, version: nil)])
			#expect(store.automationInstall == nil && store.pendingInstallation == nil)
		} else {
			expectNoDifference(store.pendingInstallation, prompt(in: inventory(revision: UInt64(attempts))))
			#expect(store.automationInstall?.stage == .reviewing && outcomes.value.isEmpty)
		}
	}

	@Test
	internal func aCancelWhileTheProfileIsReadAgainEndsTheRetries() async throws {
		let imported = LockIsolated(0)
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		let store = Store(initialState: loaded(inventory())) {
			Self.recording(outcomes)
		} withDependencies: {
			$0.browserExtensions = client(
				prepare: { _ in
					imported.withValue { $0 += 1 }
					throw BrowserExtensionsClient.Failure.staleInventory
				},
				inspect: { _ in
					started.continuation.yield(())
					for await _ in release.stream { break }
					return inventory(revision: 2)
				}
			)
		}

		let install = store.send(.automationInstallRequested(request()))
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)
		await store.send(.automationInstallCancelled(requestID)).finish()
		release.continuation.finish()
		await install.finish()
		for _ in 0..<100 { await Task.yield() }

		#expect(imported.value == 1, "A request nobody waits for doesn't download again")
		#expect(store.automationInstall == nil && outcomes.value.isEmpty)
	}

	@Test
	internal func anItemInstalledWhileTheProfileIsReadAgainIsReported() async throws {
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let store = Store(initialState: loaded(inventory())) {
			Self.recording(outcomes)
		} withDependencies: {
			$0.browserExtensions = client(
				prepare: { _ in throw BrowserExtensionsClient.Failure.staleInventory },
				inspect: { _ in inventory(revision: 2, adding: storeID) }
			)
		}

		await store.send(.automationInstallRequested(request())).finish()
		await waitWhile { outcomes.value.isEmpty }

		expectNoDifference(outcomes.value, [requestID: .alreadyInstalled(name: "Store item", version: "3.1")])
	}

	@Test
	internal func anApprovedInstallChromiumRefusesFails() async throws {
		let before = inventory()
		let prompt = prompt(in: before)
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let store = Store(initialState: loaded(before)) {
			Self.recording(outcomes)
		} withDependencies: {
			$0.browserExtensions = client(
				prepare: { _ in prompt },
				resolve: { _, _ in throw BrowserExtensionsClient.Failure.limitExceeded }
			)
		}

		await store.send(.automationInstallRequested(request())).finish()
		await store.send(.ui(.respondToInstallation(prompt, true))).finish()

		expectNoDifference(outcomes.value, [requestID: .failed(.limitExceeded, name: "Store item", version: "3.1")])
	}

	@Test
	internal func aPackageForAnotherItemIsRefused() async throws {
		let before = inventory()
		let wrong = prompt(in: before, extensionID: String(repeating: "c", count: 32))
		let cancelled = LockIsolated<[BrowserExtensionInstallPrompt]>([])
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let store = Store(initialState: loaded(before)) {
			Self.recording(outcomes)
		} withDependencies: {
			$0.browserExtensions = client(prepare: { _ in wrong }, cancel: { prompt in cancelled.withValue { $0.append(prompt) } })
		}

		await store.send(.automationInstallRequested(request())).finish()

		expectNoDifference(outcomes.value, [requestID: .failed(.invalidResponse, name: nil, version: nil)])
		expectNoDifference(cancelled.value, [wrong])
		#expect(store.pendingInstallation == nil)
	}

	@Test(arguments: ["profile", "closed", "review", "selection", "store", "update", "unavailable"])
	internal func aRequestTheSheetCannotTakeStartsNothing(reason: String) async throws {
		var state = loaded(inventory())
		switch reason {
		case "closed": state.isPresented = false
		case "review": state.pendingInstallation = prompt(in: inventory())
		case "selection": state.packageSelection = .init(inventory: inventory(), expectedExtensionID: nil)
		case "store": state.webstoreRequest = .init(id: UUID(91), profileID: profile.id, extensionID: storeID)
		case "update": state.updateCheck = .init(remaining: [installedID])
		default: break
		}
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let store = Store(initialState: state) {
			Self.recording(outcomes)
		} withDependencies: {
			$0.browserExtensions = client(
				importAvailable: reason != "unavailable",
				prepare: { _ in
					Issue.record("A refused request must not download")
					throw BrowserExtensionsClient.Failure.failed
				}
			)
		}

		await store.send(.automationInstallRequested(request(profileID: reason == "profile" ? other.id : profile.id))).finish()

		expectNoDifference(outcomes.value, [requestID: reason == "unavailable" ? .unavailable : .busy])
		#expect(store.automationInstall == nil)
	}

	@Test(arguments: ["dismiss", "profile"])
	internal func closingTheSheetOnTheReviewDeclines(how: String) async throws {
		let before = inventory()
		let prompt = prompt(in: before)
		let cancelled = LockIsolated<[BrowserExtensionInstallPrompt]>([])
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let store = Store(initialState: loaded(before)) {
			Self.recording(outcomes)
		} withDependencies: {
			$0.browserExtensions = client(
				prepare: { _ in prompt },
				resolve: { _, _ in
					Issue.record("Closing the sheet must not install")
					return before
				},
				cancel: { prompt in cancelled.withValue { $0.append(prompt) } },
				inspect: { _ in inventory(profileID: other.id) }
			)
		}

		await store.send(.automationInstallRequested(request())).finish()
		#expect(store.pendingInstallation == prompt)
		if how == "dismiss" {
			await store.send(.ui(.dismiss)).finish()
		} else {
			await store.send(.configure(other)).finish()
		}

		expectNoDifference(outcomes.value, [requestID: .declined(name: "Store item", version: "3.1")])
		expectNoDifference(cancelled.value, [prompt])
		#expect(store.automationInstall == nil && store.pendingInstallation == nil)
	}

	@Test
	internal func aCancelledRequestTakesItsReviewAway() async throws {
		let before = inventory()
		let prompt = prompt(in: before)
		let cancelled = LockIsolated<[BrowserExtensionInstallPrompt]>([])
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let store = Store(initialState: loaded(before)) {
			Self.recording(outcomes)
		} withDependencies: {
			$0.browserExtensions = client(
				prepare: { _ in prompt },
				resolve: { _, _ in
					Issue.record("A cancelled request's review must not install")
					return before
				},
				cancel: { prompt in cancelled.withValue { $0.append(prompt) } },
				inspect: { _ in before }
			)
		}

		await store.send(.automationInstallRequested(request())).finish()
		#expect(store.pendingInstallation == prompt)
		await store.send(.automationInstallCancelled(UUID(71))).finish()
		#expect(store.pendingInstallation == prompt, "Another request's cancel changes nothing")

		await store.send(.automationInstallCancelled(requestID)).finish()

		#expect(store.pendingInstallation == nil && store.automationInstall == nil)
		expectNoDifference(cancelled.value, [prompt])
		expectNoDifference(store.inventory, before)
		await store.send(.ui(.respondToInstallation(prompt, true))).finish()
		#expect(outcomes.value.isEmpty, "Nobody is waiting for an outcome")
	}

	@Test
	internal func aDownloadOutlivesItsRequestThenTheSheetReloads() async throws {
		let before = inventory()
		let prompt = prompt(in: before)
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		let cancelled = LockIsolated<[BrowserExtensionInstallPrompt]>([])
		let reads = LockIsolated(0)
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let store = Store(initialState: loaded(before)) {
			Self.recording(outcomes)
		} withDependencies: {
			$0.browserExtensions = client(
				prepare: { _ in
					started.continuation.yield(())
					for await _ in release.stream { break }
					return prompt
				},
				cancel: { prompt in cancelled.withValue { $0.append(prompt) } },
				inspect: { _ in
					reads.withValue { $0 += 1 }
					#expect(cancelled.value == [prompt], "The profile is read again only once the package is dropped")
					return before
				}
			)
		}

		let install = store.send(.automationInstallRequested(request()))
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)
		await store.send(.automationInstallCancelled(requestID)).finish()
		#expect(store.automationInstall?.stage == .discarding && store.isWorking && reads.value == 0)

		release.continuation.finish()
		await install.finish()
		await waitWhile { reads.value == 0 }

		#expect(store.automationInstall == nil && store.pendingInstallation == nil)
		expectNoDifference(cancelled.value, [prompt])
		#expect(reads.value == 1 && outcomes.value.isEmpty)
	}

	@Test
	internal func aRequestWaitsForTheSheetToLoadTheProfile() async throws {
		let loadedInventory = inventory()
		let prompt = prompt(in: loadedInventory)
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		let outcomes = LockIsolated<[UUID: Outcome]>([:])
		let store = Store(initialState: ExtensionsFeature.State(profile: profile, isAvailable: true)) {
			Self.recording(outcomes)
		} withDependencies: {
			$0.browserExtensions = client(
				prepare: { request in
					#expect(request.inventoryID == loadedInventory.id)
					return prompt
				},
				inspect: { _ in
					started.continuation.yield(())
					for await _ in release.stream { break }
					return loadedInventory
				}
			)
		}

		let load = store.send(.ui(.present))
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)
		await store.send(.automationInstallRequested(request())).finish()
		#expect(store.automationInstall?.stage == .waiting && store.pendingInstallation == nil)

		release.continuation.finish()
		await load.finish()
		await waitWhile { store.pendingInstallation == nil }

		expectNoDifference(store.pendingInstallation, prompt)
		#expect(store.automationInstall?.stage == .reviewing && outcomes.value.isEmpty)
	}

	// MARK: - Helpers

	/// The feature, recording each outcome and, unless `proceeds` is false, answering the
	/// loaded inventory's check the way the app does when it passes.
	private static func recording(
		_ outcomes: LockIsolated<[UUID: Outcome]>,
		proceeds: Bool = true
	) -> some ReducerOf<ExtensionsFeature> {
		CombineReducers {
			ExtensionsFeature()
			Reduce<ExtensionsFeature.State, ExtensionsFeature.Action> { _, action in
				switch action {
				case let .delegate(.automationInstallFinished(id, outcome, _)):
					outcomes.withValue { $0[id] = outcome }
					return .none
				case let .delegate(.automationInstallInventoryLoaded(id, _)) where proceeds:
					return .send(.automationInstallProceed(id))
				default:
					return .none
				}
			}
		}
	}

	private func client(
		importAvailable: Bool = true,
		prepare: @escaping @MainActor @Sendable (BrowserWebstoreImportRequest) async throws -> BrowserExtensionInstallPrompt,
		resolve: @escaping @MainActor @Sendable (BrowserExtensionInstallPrompt, Bool) async throws -> BrowserExtensionInventory = { _, _ in
			throw BrowserExtensionsClient.Failure.failed
		},
		cancel: @escaping @MainActor @Sendable (BrowserExtensionInstallPrompt) -> Void = { _ in },
		inspect: @escaping @MainActor @Sendable (Profile.ID) async throws -> BrowserExtensionInventory = { _ in
			throw BrowserExtensionsClient.Failure.failed
		}
	) -> BrowserExtensionsClient {
		.init(
			isAvailable: true,
			installationAvailability: { true },
			inspect: inspect,
			resolveInstallation: resolve,
			cancelInstallation: cancel,
			webstoreImportAvailability: { importAvailable },
			prepareWebstoreImport: prepare
		)
	}

	private func request(
		profileID: Profile.ID? = nil,
		extensionID: String? = nil
	) -> ExtensionsFeature.AutomationInstall {
		.init(id: requestID, profileID: profileID ?? profile.id, extensionID: extensionID ?? storeID, requester: "Codex")
	}

	private func prompt(
		in inventory: BrowserExtensionInventory,
		extensionID: String? = nil
	) -> BrowserExtensionInstallPrompt {
		.init(
			id: UUID(80),
			profileID: inventory.profileID,
			inventoryID: inventory.id,
			revision: inventory.revision,
			candidate: .init(
				extensionID: extensionID ?? storeID,
				name: "Store item",
				version: "3.1",
				packageSHA256: String(repeating: "c", count: 64),
				sourceBasename: "Chrome Web Store",
				isUpdate: false,
				requiredPermissions: .init(apis: ["storage"], hosts: ["https://example.com/*"]),
				optionalPermissions: .init(apis: [], hosts: []),
				warnings: [.init(message: "Read and change your data on example.com", details: [])]
			)
		)
	}

	private func loaded(_ inventory: BrowserExtensionInventory) -> ExtensionsFeature.State {
		var state = ExtensionsFeature.State(profile: profile, isAvailable: true)
		state.isPresented = true
		state.inventory = inventory
		state.selectedID = inventory.extensions.first?.id
		return state
	}

	private func inventory(
		profileID: Profile.ID? = nil,
		revision: UInt64 = 1,
		adding added: String? = nil
	) -> BrowserExtensionInventory {
		var extensions: [BrowserExtension] = [
			.init(id: installedID, name: "Fixture", version: "1", state: .enabled, canDisable: true, canRemove: true),
		]
		if let added {
			extensions.append(.init(id: added, name: "Store item", version: "3.1", fromWebStore: true, state: .enabled, canDisable: true, canRemove: true))
		}
		return .init(
			id: UUID(Int(revision) + 10),
			profileID: profileID ?? profile.id,
			revision: revision,
			extensions: extensions
		)
	}
}
