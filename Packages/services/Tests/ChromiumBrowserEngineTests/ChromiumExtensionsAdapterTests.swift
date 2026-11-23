import BrowserCore
import BrowserExtensionsClient
import CustomDump
import Foundation
import Testing
import _TestSupport

@testable
import ChromiumBrowserEngine

@testable
import ChromiumEngine

@MainActor
internal struct ChromiumExtensionsAdapterTests {
	private let profile: Profile.ID = .init(rawValue: UUID(90))
	private let other: Profile.ID = .init(rawValue: UUID(91))
	private let extensionID: String = String(repeating: "a", count: 32)

	@Test
	internal func retainedClientAvailabilityFollowsRuntimeReadiness() {
		let available = ExtensionAvailability()
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { available.value },
			ordinaryProfileExists: { _ in true },
			inspect: { _ in throw BrowserExtensionsClient.Failure.unavailable },
			manage: { _, _, _ in throw BrowserExtensionsClient.Failure.unavailable }
		)
		let client = adapter.client
		#expect(!client.isAvailable)
		available.value = true
		#expect(client.isAvailable)
		available.value = false
		#expect(!client.isAvailable)
	}

	@Test
	internal func defaultClientIsUnavailable() async throws {
		let client = BrowserExtensionsClient.liveValue

		#expect(!client.isAvailable)
		await #expect(throws: BrowserExtensionsClient.Failure.unavailable) {
			try await client.inspect(profile)
		}
	}

	@Test
	internal func optionsConsumesOpaqueAuthorityWithoutRequiringAMutationRevision() async throws {
		let native = try inventory(hasOptions: true)
		var opened = 0
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			optionsAvailable: { true },
			openOptions: { id, authority in
				#expect(id == extensionID)
				#expect(authority == native)
				opened += 1
				return native
			},
			available: { true },
			ordinaryProfileExists: { $0 == profile },
			inspect: { _ in native },
			manage: { _, _, _ in throw BrowserExtensionsClient.Failure.failed }
		)
		let before = try await adapter.client.inspect(profile)
		let request = BrowserExtensionViewRequest(inventory: before, extensionID: extensionID)
		let after = try await adapter.client.openOptions(request)
		#expect(after.profileID == profile)
		#expect(after.id != before.id)
		#expect(after.revision == before.revision)
		await #expect(throws: BrowserExtensionsClient.Failure.staleInventory) {
			try await adapter.client.openOptions(request)
		}
		#expect(opened == 1)
	}

	@Test
	internal func legacyProfileAndPermissionsRetainTheirIdentity() async throws {
		let native = try inventory()
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			ordinaryProfileExists: { $0 == profile },
			inspect: { key in
				#expect(key == nil)
				return native
			},
			manage: { _, _, _ in throw BrowserExtensionsClient.Failure.failed }
		)

		let value = try await adapter.client.inspect(profile)

		expectNoDifference(value.profileID, profile)
		expectNoDifference(value.extensions[0].requiredPermissions.hosts, ["https://required.example/*"])
		expectNoDifference(value.extensions[0].optionalPermissions.apis, ["bookmarks"])
		expectNoDifference(value.extensions[0].activePermissions.hosts, ["https://active.example/*"])
		expectNoDifference(value.extensions[0].withheldPermissions.hosts, ["https://withheld.example/*"])
	}

	@Test
	internal func profilesOutsideTheLiveOrdinaryWorkspaceNeverReachNativeInspection() async throws {
		let native = try inventory()
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			ordinaryProfileExists: { $0 == profile },
			inspect: { _ in
				Issue.record("An unknown or private profile reached native inspection")
				return native
			},
			manage: { _, _, _ in
				Issue.record("An unknown or private profile reached native mutation")
				return native
			}
		)

		await #expect(throws: BrowserExtensionsClient.Failure.missingProfile) {
			try await adapter.client.inspect(other)
		}
	}

	@Test
	internal func cancellationDoesNotPublishOrReplayAnAlreadyAcceptedNativeMutation() async throws {
		let before = try inventory()
		let after = try inventory(revision: 12, enabled: false, reasons: [1])
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		var calls = 0
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			ordinaryProfileExists: { _ in true },
			inspect: { _ in before },
			manage: { _, _, _ in
				calls += 1
				started.continuation.yield(())
				for await _ in release.stream { break }

				return after
			}
		)
		let current = try await adapter.client.inspect(profile)
		let request = BrowserExtensionRequest(
			inventory: current,
			extensionID: extensionID,
			action: .disable
		)

		let task = Task { try await adapter.client.manage(request) }
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)

		task.cancel()
		release.continuation.finish()

		await #expect(throws: CancellationError.self) { try await task.value }
		await #expect(throws: BrowserExtensionsClient.Failure.staleInventory) {
			try await adapter.client.manage(request)
		}
		#expect(calls == 1)
	}

	@Test(arguments: ["token", "profile", "revision", "extension"])
	internal func forgedOrExpiredRequestsCannotReachNativeManagement(change: String) async throws {
		let native = try inventory()
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			ordinaryProfileExists: { _ in true },
			inspect: { _ in native },
			manage: { _, _, _ in
				Issue.record("A mismatched request reached native management")
				return native
			}
		)
		let current = try await adapter.client.inspect(profile)
		let modified = BrowserExtensionInventory(
			id: change == "token" ? UUID(99) : current.id,
			profileID: change == "profile" ? other : current.profileID,
			revision: change == "revision" ? current.revision + 1 : current.revision,
			extensions: current.extensions
		)
		let request = BrowserExtensionRequest(
			inventory: modified,
			extensionID: change == "extension" ? String(repeating: "b", count: 32) : extensionID,
			action: .disable
		)

		await #expect(throws: BrowserExtensionsClient.Failure.staleInventory) {
			try await adapter.client.manage(request)
		}
	}

	@Test(arguments: [[1, 2], [2], [1, 1 << 29]])
	internal func permissionAndUnknownReasonsCannotGrantEnable(reasons: [Int]) async throws {
		let native = try inventory(enabled: false, reasons: reasons, forceEnable: true)
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			ordinaryProfileExists: { _ in true },
			inspect: { _ in native },
			manage: { _, _, _ in
				Issue.record("Permission review must not be bypassed")
				return native
			}
		)

		let value = try await adapter.client.inspect(profile)

		expectNoDifference(value.extensions[0].disableReasons.map(\.rawValue), reasons)
		await #expect(throws: BrowserExtensionsClient.Failure.reviewRequired) {
			try await adapter.client.manage(.init(
				inventory: value,
				extensionID: extensionID,
				action: .enable
			))
		}
	}

	@Test
	internal func managementReturnsAuthoritativeInventoryAndConsumesPriorAuthority() async throws {
		let before = try inventory()
		let after = try inventory(revision: 12, enabled: false, reasons: [1])
		var calls = 0
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			ordinaryProfileExists: { _ in true },
			inspect: { _ in before },
			manage: { action, id, native in
				guard case .disable = action else {
					Issue.record("Wrong action")
					return before
				}

				calls += 1
				expectNoDifference(id, extensionID)
				expectNoDifference(native, before)

				return after
			}
		)
		let value = try await adapter.client.inspect(profile)
		let request = BrowserExtensionRequest(
			inventory: value,
			extensionID: extensionID,
			action: .disable
		)

		let refreshed = try await adapter.client.manage(request)

		#expect(refreshed.id != value.id && refreshed.revision == 12)
		expectNoDifference(refreshed.extensions[0].state, .disabled)
		await #expect(throws: BrowserExtensionsClient.Failure.staleInventory) {
			try await adapter.client.manage(request)
		}
		#expect(calls == 1)
	}

	@Test(arguments: [false, true])
	internal func mismatchedOrUnchangedNativeResultsCannotReportSuccess(wrongProfile: Bool) async throws {
		let before = try inventory()
		let after = try inventory(
			profileID: wrongProfile ? other.rawValue : nil,
			revision: 12,
			enabled: !wrongProfile,
			reasons: wrongProfile ? [1] : []
		)
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			ordinaryProfileExists: { _ in true },
			inspect: { _ in before },
			manage: { _, _, _ in after }
		)
		let value = try await adapter.client.inspect(profile)
		let request = BrowserExtensionRequest(
			inventory: value,
			extensionID: extensionID,
			action: .disable
		)

		await #expect(throws: wrongProfile ? BrowserExtensionsClient.Failure.invalidResponse : .failed) {
			try await adapter.client.manage(request)
		}
		await #expect(throws: BrowserExtensionsClient.Failure.staleInventory) {
			try await adapter.client.manage(request)
		}
	}

	@Test(arguments: [false, true])
	internal func profileDeletionDuringNativeAwaitRejectsInventory(managing: Bool) async throws {
		let before = try inventory()
		let after = try inventory(revision: 12, enabled: false, reasons: [1])
		let availability = ExtensionProfileAvailability()
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			ordinaryProfileExists: { _ in availability.exists },
			inspect: { _ in
				if !managing {
					started.continuation.yield(())
					for await _ in release.stream { break }
				}

				return before
			},
			manage: { _, _, _ in
				started.continuation.yield(())
				for await _ in release.stream { break }

				return after
			}
		)
		let current = managing ? try await adapter.client.inspect(profile) : nil

		let task = Task {
			if let current {
				return try await adapter.client.manage(.init(
					inventory: current,
					extensionID: extensionID,
					action: .disable
				))
			}

			return try await adapter.client.inspect(profile)
		}
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)

		availability.exists = false
		release.continuation.yield(())
		release.continuation.finish()

		await #expect(throws: BrowserExtensionsClient.Failure.missingProfile) {
			try await task.value
		}
	}

	@Test
	internal func verifiedInstallPromptIsExactOneUseAuthorityAndBlocksInventory() async throws {
		let before = try inventory()
		let after = try inventory(revision: 12)
		let nativePrompt = installPrompt()
		var resolutions = 0
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			installationAvailable: { true },
			ordinaryProfileExists: { $0 == profile },
			inspect: { _ in before },
			manage: { _, _, _ in throw ChromiumExtensionFailure.failed },
			readPackage: { _ in .init(data: Data([1]), sourceBasename: "Selected.crx") },
			prepareInstallation: { package, expectedID, inventory in
				#expect(package.data == Data([1]) && expectedID == nil && inventory == before)
				return nativePrompt
			},
			resolveInstallation: { prompt, accept in
				#expect(prompt == nativePrompt && accept)
				resolutions += 1
				return after
			}
		)
		let inventory = try await adapter.client.inspect(profile)
		let prompt = try await adapter.client.prepareInstallation(.init(
			inventory: inventory,
			selectedFile: URL(filePath: "/tmp/Selected.crx")
		))
		#expect(prompt.profileID == profile && prompt.inventoryID == inventory.id)
		await #expect(throws: BrowserExtensionsClient.Failure.busy) {
			try await adapter.client.inspect(profile)
		}
		let forged = BrowserExtensionInstallPrompt(
			id: prompt.id,
			profileID: prompt.profileID,
			inventoryID: UUID(44),
			revision: prompt.revision,
			candidate: prompt.candidate
		)
		await #expect(throws: BrowserExtensionsClient.Failure.staleInventory) {
			try await adapter.client.resolveInstallation(forged, true)
		}
		#expect(resolutions == 0)
		let result = try await adapter.client.resolveInstallation(prompt, true)
		#expect(result.revision == 12)
		await #expect(throws: BrowserExtensionsClient.Failure.staleInventory) {
			try await adapter.client.resolveInstallation(prompt, true)
		}
		#expect(resolutions == 1)
	}

	@Test
	internal func decliningVerifiedUpdateRefreshesOnlyAfterNativeDrainAndNeverAccepts() async throws {
		let before = try inventory()
		var inspections = 0
		var approvals: [Bool] = []
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			installationAvailable: { true },
			ordinaryProfileExists: { _ in true },
			inspect: { _ in
				inspections += 1
				return before
			},
			manage: { _, _, _ in throw ChromiumExtensionFailure.failed },
			readPackage: { _ in .init(data: Data([1]), sourceBasename: "Selected.crx") },
			prepareInstallation: { _, expectedID, _ in
				#expect(expectedID == extensionID)
				return installPrompt(isUpdate: true)
			},
			resolveInstallation: { _, accept in
				approvals.append(accept)
				throw ChromiumExtensionFailure.cancelled
			}
		)
		let inventory = try await adapter.client.inspect(profile)
		let prompt = try await adapter.client.prepareInstallation(.init(
			inventory: inventory,
			selectedFile: URL(filePath: "/tmp/Selected.crx"),
			expectedExtensionID: extensionID
		))
		#expect(inspections == 1)
		let refreshed = try await adapter.client.resolveInstallation(prompt, false)
		#expect(refreshed.revision == before.revision && refreshed.id != inventory.id)
		#expect(inspections == 2 && approvals == [false])
	}

	@Test
	internal func ownerLossAfterNativeVerificationCancelsTheExactPrompt() async throws {
		let before = try inventory()
		let nativePrompt = installPrompt()
		var exists = true
		var cancelled: [ChromiumExtensionInstallPrompt] = []
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			installationAvailable: { true },
			ordinaryProfileExists: { _ in exists },
			inspect: { _ in before },
			manage: { _, _, _ in throw ChromiumExtensionFailure.failed },
			readPackage: { _ in .init(data: Data([1]), sourceBasename: "Selected.crx") },
			prepareInstallation: { _, _, _ in
				exists = false
				return nativePrompt
			},
			cancelInstallation: { cancelled.append($0) }
		)
		let inventory = try await adapter.client.inspect(profile)
		await #expect(throws: BrowserExtensionsClient.Failure.missingProfile) {
			try await adapter.client.prepareInstallation(.init(
				inventory: inventory,
				selectedFile: URL(filePath: "/tmp/Selected.crx")
			))
		}
		#expect(cancelled == [nativePrompt])
		exists = true
		_ = try await adapter.client.inspect(profile)
	}

	@Test
	internal func unpackedLoadConsumesExactInventoryAuthorityAndPreservesTheReason() async throws {
		let before = try inventory()
		let after = try inventory(revision: 12, unpacked: true)
		let folder = URL(fileURLWithPath: "/tmp/arx-unpacked", isDirectory: true)
		var calls: [URL] = []
		let failure = ExtensionLoadFailure()
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			ordinaryProfileExists: { _ in true },
			inspect: { _ in before },
			manage: { _, _, _ in before },
			unpackedAvailable: { true },
			loadUnpacked: { directory, native in
				calls.append(directory)
				expectNoDifference(native, before)
				if let value = failure.value { throw value }
				return after
			}
		)
		#expect(adapter.client.isUnpackedAvailable)

		failure.value = .invalidManifest("Manifest is not valid JSON.")
		let first = try await adapter.client.inspect(profile)
		await #expect(throws: BrowserExtensionsClient.Failure.invalidManifest("Manifest is not valid JSON.")) {
			try await adapter.client.loadUnpacked(.init(inventory: first, directory: folder))
		}
		await #expect(throws: BrowserExtensionsClient.Failure.staleInventory) {
			try await adapter.client.loadUnpacked(.init(inventory: first, directory: folder))
		}

		failure.value = nil
		let second = try await adapter.client.inspect(profile)
		let loaded = try await adapter.client.loadUnpacked(.init(inventory: second, directory: folder))
		#expect(loaded.revision == 12)
		#expect(loaded.extensions[0].canReload && loaded.extensions[0].allows(.reload))
		expectNoDifference(loaded.extensions[0].sourcePath, "/tmp/arx-unpacked")
		expectNoDifference(calls, [folder, folder])
	}

	@Test
	internal func unpackedLoadIsUnavailableWithoutItsOwnCapability() async throws {
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			ordinaryProfileExists: { _ in true },
			inspect: { [self] _ in try inventory() },
			manage: { [self] _, _, _ in try inventory() },
			loadUnpacked: { _, _ in
				Issue.record("Unavailable folder loading reached native code")
				throw ChromiumExtensionFailure.unavailable
			}
		)
		let value = try await adapter.client.inspect(profile)
		#expect(!adapter.client.isUnpackedAvailable)
		await #expect(throws: BrowserExtensionsClient.Failure.unavailable) {
			try await adapter.client.loadUnpacked(.init(inventory: value, directory: URL(fileURLWithPath: "/tmp")))
		}
	}

	@Test
	internal func reloadReachesNativeOnlyForAReloadableRowAndKeepsIt() async throws {
		let packed = try inventory()
		let unpacked = try inventory(revision: 12, unpacked: true)
		let reloaded = try inventory(revision: 13, unpacked: true)
		var source = packed
		var actions: [ChromiumExtensionAction] = []
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			ordinaryProfileExists: { _ in true },
			inspect: { _ in source },
			manage: { action, _, _ in
				actions.append(action)
				return reloaded
			}
		)
		let packedValue = try await adapter.client.inspect(profile)
		await #expect(throws: BrowserExtensionsClient.Failure.blockedByPolicy) {
			try await adapter.client.manage(.init(inventory: packedValue, extensionID: extensionID, action: .reload))
		}

		source = unpacked
		let value = try await adapter.client.inspect(profile)
		let refreshed = try await adapter.client.manage(.init(inventory: value, extensionID: extensionID, action: .reload))
		#expect(refreshed.revision == 13)
		#expect(actions.count == 1)
		if case .reload = actions.first {} else { Issue.record("Wrong action") }
	}

	/// DEV-765. A store request reaches the one consumer, prepares once against
	/// the exact displayed inventory, and its native token never leaves the adapter.
	@Test
	internal func webstoreRequestIsOneUseAndKeepsItsNativeToken() async throws {
		let before = try inventory()
		let storeID = String(repeating: "b", count: 32)
		let native = ChromiumWebstoreInstallRequest(
			runtimeID: UUID(89),
			token: 5,
			profileID: nil,
			extensionID: storeID
		)
		let nativePrompt = ChromiumExtensionInstallPrompt(
			runtimeID: UUID(89),
			requestID: 1,
			token: 7,
			profileID: nil,
			inventoryRevision: 11,
			candidate: .init(
				id: storeID,
				name: "Store item",
				version: "1.0",
				packageSHA256: String(repeating: "c", count: 64),
				sourceBasename: ChromiumWebstoreInstallRequest.sourceName,
				isUpdate: false,
				requiredPermissions: .init(apis: ["storage"], hosts: ["<all_urls>"]),
				optionalPermissions: .init(apis: [], hosts: []),
				warnings: []
			)
		)
		let declined = WebstoreDeclines()
		var prepared = 0
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			installationAvailable: { true },
			ordinaryProfileExists: { $0 == profile },
			inspect: { _ in before },
			manage: { _, _, _ in throw ChromiumExtensionFailure.failed },
			webstoreAvailable: { true },
			prepareWebstore: { request, inventory in
				#expect(request == native && inventory == before)
				prepared += 1
				return nativePrompt
			},
			declineWebstore: { declined.values.append($0) }
		)

		#expect(!adapter.offerWebstore(native))
		var requests = adapter.client.webstoreInstallRequests().makeAsyncIterator()
		#expect(adapter.offerWebstore(native))
		let request = try #require(await requests.next())
		#expect(request.profileID == profile && request.extensionID == storeID)

		let inventory = try await adapter.client.inspect(profile)
		let prompt = try await adapter.client.prepareWebstoreInstallation(request, inventory)
		#expect(prompt.candidate.extensionID == storeID && !prompt.candidate.isUpdate)
		#expect(prompt.candidate.sourceBasename == "Chrome Web Store")
		adapter.client.cancelInstallation(prompt)

		await #expect(throws: BrowserExtensionsClient.Failure.staleInventory) {
			try await adapter.client.prepareWebstoreInstallation(request, inventory)
		}
		#expect(prepared == 1)
		#expect(declined.values.isEmpty)

		#expect(adapter.offerWebstore(native))
		let second = try #require(await requests.next())
		adapter.client.declineWebstoreInstallation(second)
		adapter.client.declineWebstoreInstallation(second)
		#expect(declined.values == [native])
	}

	@Test
	internal func webstoreRequestForAnUnknownProfileIsRefused() {
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			installationAvailable: { true },
			ordinaryProfileExists: { $0 == profile },
			inspect: { _ in throw ChromiumExtensionFailure.failed },
			manage: { _, _, _ in throw ChromiumExtensionFailure.failed },
			webstoreAvailable: { true }
		)
		_ = adapter.client.webstoreInstallRequests()
		#expect(!adapter.offerWebstore(.init(
			runtimeID: UUID(89),
			token: 5,
			profileID: other.rawValue,
			extensionID: extensionID
		)))
	}

	@Test
	internal func webstoreUpdateNeedsAStoreExtensionAndKeepsTheInventoryWhenNothingIsNewer() async throws {
		let local = try inventory()
		let store = try inventory(fromWebStore: true)
		let after = try inventory(revision: 12, fromWebStore: true)
		var useStore = false
		var newer = false
		var prepared: [UInt64] = []
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			installationAvailable: { true },
			ordinaryProfileExists: { $0 == profile },
			inspect: { _ in useStore ? store : local },
			manage: { _, _, _ in throw ChromiumExtensionFailure.failed },
			resolveInstallation: { _, accept in
				#expect(accept)
				return after
			},
			webstoreUpdateAvailable: { true },
			prepareWebstoreUpdate: { id, inventory in
				#expect(id == extensionID)
				prepared.append(inventory.revision)
				guard newer else { throw ChromiumExtensionFailure.upToDate }
				return installPrompt(isUpdate: true, permissionIncrease: true)
			}
		)
		#expect(adapter.client.isWebstoreUpdateAvailable)

		// A package-installed extension isn't the store's to update.
		let localInventory = try await adapter.client.inspect(profile)
		await #expect(throws: BrowserExtensionsClient.Failure.invalidRequest) {
			try await adapter.client.prepareWebstoreUpdate(.init(inventory: localInventory, extensionID: extensionID))
		}
		#expect(prepared.isEmpty)

		useStore = true
		let inventory = try await adapter.client.inspect(profile)
		let request = BrowserWebstoreUpdateRequest(inventory: inventory, extensionID: extensionID)
		await #expect(throws: BrowserExtensionsClient.Failure.upToDate) {
			try await adapter.client.prepareWebstoreUpdate(request)
		}

		// Nothing newer leaves the same inventory usable for the next check.
		newer = true
		let prompt = try await adapter.client.prepareWebstoreUpdate(request)
		#expect(prompt.candidate.isUpdate && prompt.candidate.permissionIncrease)
		await #expect(throws: BrowserExtensionsClient.Failure.busy) {
			try await adapter.client.inspect(profile)
		}
		let result = try await adapter.client.resolveInstallation(prompt, true)
		#expect(result.revision == 12)
		// The update used the inventory up.
		await #expect(throws: BrowserExtensionsClient.Failure.staleInventory) {
			try await adapter.client.prepareWebstoreUpdate(request)
		}
		#expect(prepared == [11, 11])
	}

	/// DEV-845. An extension from another browser installs by ID through the same review,
	/// only when the profile doesn't have it yet.
	@Test
	internal func webstoreImportInstallsAnExtensionTheProfileDoesNotHave() async throws {
		let installed = try inventory()
		let empty = ChromiumExtensionInventory(runtimeID: UUID(89), profileID: nil, revision: 11, extensions: [])
		let after = try inventory(revision: 12, fromWebStore: true)
		var hasIt = true
		var prepared: [String] = []
		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: profile,
			available: { true },
			installationAvailable: { true },
			ordinaryProfileExists: { $0 == profile },
			inspect: { _ in hasIt ? installed : empty },
			manage: { _, _, _ in throw ChromiumExtensionFailure.failed },
			resolveInstallation: { _, accept in
				#expect(accept)
				return after
			},
			webstoreImportAvailable: { true },
			prepareWebstoreImport: { id, inventory in
				#expect(inventory.revision == 11)
				prepared.append(id)
				return installPrompt()
			}
		)
		#expect(adapter.client.isWebstoreImportAvailable)
		#expect(!adapter.client.isWebstoreUpdateAvailable)

		// The profile already has it: nothing is downloaded.
		let current = try await adapter.client.inspect(profile)
		await #expect(throws: BrowserExtensionsClient.Failure.invalidRequest) {
			try await adapter.client.prepareWebstoreImport(.init(inventory: current, extensionID: extensionID))
		}
		#expect(prepared.isEmpty)

		hasIt = false
		let inventory = try await adapter.client.inspect(profile)
		let prompt = try await adapter.client.prepareWebstoreImport(.init(inventory: inventory, extensionID: extensionID))
		#expect(!prompt.candidate.isUpdate)
		#expect(prompt.candidate.extensionID == extensionID)
		await #expect(throws: BrowserExtensionsClient.Failure.busy) {
			try await adapter.client.inspect(profile)
		}
		let result = try await adapter.client.resolveInstallation(prompt, true)
		#expect(result.revision == 12)
		// The install used the inventory up.
		await #expect(throws: BrowserExtensionsClient.Failure.staleInventory) {
			try await adapter.client.prepareWebstoreImport(.init(inventory: inventory, extensionID: extensionID))
		}
		#expect(prepared == [extensionID])
	}

	private func installPrompt(
		isUpdate: Bool = false,
		permissionIncrease: Bool? = nil
	) -> ChromiumExtensionInstallPrompt {
		.init(
			runtimeID: UUID(89),
			requestID: 1,
			token: 7,
			profileID: nil,
			inventoryRevision: 11,
			candidate: .init(
				id: extensionID,
				name: "Verified fixture",
				version: "1.0",
				packageSHA256: String(repeating: "a", count: 64),
				sourceBasename: "Selected.crx",
				isUpdate: isUpdate,
				requiredPermissions: .init(apis: ["storage"], hosts: []),
				optionalPermissions: .init(apis: [], hosts: []),
				warnings: [],
				permissionIncrease: permissionIncrease
			)
		)
	}

	private func inventory(
		profileID: UUID? = nil,
		revision: UInt64 = 11,
		enabled: Bool = true,
		reasons: [Int] = [],
		forceEnable: Bool = false,
		hasOptions: Bool = false,
		unpacked: Bool = false,
		fromWebStore: Bool = false
	) throws -> ChromiumExtensionInventory {
		var payload: [String: Any] = [
			"id": extensionID,
			"name": "Fixture",
			"version": "1.0",
			"manifestVersion": 3,
			"location": unpacked ? 4 : 1,
			"fromWebStore": fromWebStore,
			"state": enabled ? "enabled" : "disabled",
			"disableReasons": reasons,
			"permissionsIncreased": reasons.contains(2),
			"isFixture": false,
			"canEnable": forceEnable || (!enabled && reasons == [1]),
			"canDisable": enabled,
			"canRemove": true,
			"canOpenOptions": hasOptions,
			"requiredPermissions": ["apis": ["storage"], "hosts": ["https://required.example/*"]],
			"optionalPermissions": ["apis": ["bookmarks"], "hosts": []],
			"activePermissions": ["apis": ["storage"], "hosts": ["https://active.example/*"]],
			"withheldPermissions": ["apis": [], "hosts": ["https://withheld.example/*"]],
		]
		if unpacked {
			payload["canReload"] = true
			payload["sourcePath"] = "/tmp/arx-unpacked"
		}
		let item = try JSONDecoder().decode(
			ChromiumExtension.self,
			from: JSONSerialization.data(withJSONObject: payload)
		)

		return .init(
			runtimeID: UUID(89),
			profileID: profileID,
			revision: revision,
			extensions: [item]
		)
	}
}

@MainActor
private final class ExtensionProfileAvailability {
	internal var exists: Bool = true
}

@MainActor
private final class ExtensionAvailability {
	internal var value: Bool = false
}

// Reference storage lets the test change the native failure after the `@Sendable` closure captured it.
@MainActor
private final class ExtensionLoadFailure {
	internal var value: ChromiumExtensionFailure?
}

@MainActor
private final class WebstoreDeclines {
	internal var values: [ChromiumWebstoreInstallRequest] = []
}
