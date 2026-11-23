import BrowserCore
import BrowserExtensionsClient
import CustomDump
import ExtensionsFeature
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1210. A store update the automatic check turned down for asking more permissions waits for
/// review: the row's mark opens it, declining keeps the installed version until a newer one turns
/// up, and the mark goes when the extension changes some other way.
@Suite(.dependencies)
@MainActor
internal struct ExtensionUpdateReviewTests {
	private let profile: Profile = .init(id: .init(rawValue: UUID(1)), name: "Personal")
	private let other: Profile.ID = .init(rawValue: UUID(2))
	private let storeID: String = String(repeating: "s", count: 32)
	private let otherStoreID: String = String(repeating: "t", count: 32)

	// MARK: - The record

	@Test
	internal func aDeclinedVersionIsNeverMarkedAgainButANewerOneIs() {
		var reviews = ExtensionUpdateReviews()
		reviews.offered(review(version: "2"))
		expectNoDifference(reviews.pending(in: profile.id).map(\.version), ["2"])
		#expect(reviews.pending(in: other).isEmpty)

		reviews.declined(review(version: "2"))
		#expect(reviews.pending.isEmpty)
		reviews.offered(review(version: "2"))
		#expect(reviews.pending.isEmpty)

		reviews.offered(review(version: "3"))
		expectNoDifference(reviews.review(storeID, in: profile.id)?.version, "3")

		// A newer offer replaces the mark rather than adding one.
		reviews.offered(review(version: "4"))
		expectNoDifference(reviews.pending.map(\.version), ["4"])
	}

	@Test
	internal func anExtensionThatChangedOrWentLosesItsMarkInItsProfileOnly() {
		var reviews = ExtensionUpdateReviews()
		reviews.offered(review(version: "2"))
		reviews.offered(review(extensionID: otherStoreID, version: "5"))
		reviews.offered(.init(profileID: other, extensionID: storeID, installedVersion: "1", version: "2", permissions: []))

		// The same installed version: the review still applies.
		reviews.reconcile(with: inventory(storeVersion: "1"))
		#expect(reviews.pending.count == 3)

		// Updated some other way in this profile, and the other extension removed.
		reviews.reconcile(with: inventory(storeVersion: "2", includesOther: false))
		expectNoDifference(reviews.pending.map(\.profileID), [other])

		reviews.declined(.init(profileID: profile.id, extensionID: storeID, installedVersion: "2", version: "3", permissions: []))
		reviews.reconcile(with: inventory(storeVersion: "3"))
		#expect(reviews.declined.isEmpty)
	}

	@Test
	internal func theRecordKeepsWithinItsLimitAndSurvivesUserDefaults() {
		var reviews = ExtensionUpdateReviews()
		for index in 0..<(ExtensionUpdateReviews.limit + 5) {
			reviews.offered(review(extensionID: String(format: "%032d", index), version: "2"))
		}
		#expect(reviews.pending.count == ExtensionUpdateReviews.limit)
		expectNoDifference(reviews.pending.first?.extensionID, String(format: "%032d", 5))

		reviews.declined(review(version: "9"))
		expectNoDifference(ExtensionUpdateReviews(rawValue: reviews.rawValue), reviews)
		#expect(ExtensionUpdateReviews(rawValue: "not json") == nil)

		// Equal by the lists, whatever order the JSON gives its keys.
		let copy = ExtensionUpdateReviews(pending: reviews.pending, declined: reviews.declined)
		#expect(copy == reviews)
		#expect(copy.rawValue == reviews.rawValue)

		reviews.withdrawn(String(format: "%032d", 5), in: profile.id)
		#expect(reviews.review(String(format: "%032d", 5), in: profile.id) == nil)
	}

	// MARK: - The sheet

	@Test(arguments: [true, false])
	internal func theRowsMarkOpensTheReviewOfThatUpdate(accept: Bool) async throws {
		let before = inventory(storeVersion: "1")
		let after = inventory(storeVersion: accept ? "2" : "1", revision: 2)
		let prompt = updatePrompt(in: before)
		let prepared = LockIsolated<[String]>([])
		let resolved = LockIsolated<[Bool]>([])
		let state = loaded(before)
		state.$updateReviews.withLock { $0.offered(review(version: "2")) }
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in after },
				resolveInstallation: { _, accept in
					resolved.withValue { $0.append(accept) }
					return after
				},
				webstoreUpdateAvailability: { true },
				prepareWebstoreUpdate: { request in
					prepared.withValue { $0.append(request.extensionID) }
					return prompt
				}
			)
		}
		expectNoDifference(store.pendingUpdateReviews.map(\.extensionID), [storeID])

		store.send(.ui(.reviewUpdate(storeID)))
		await waitWhile { store.pendingInstallation == nil }

		// Only that extension is checked, and its review shows.
		expectNoDifference(prepared.value, [storeID])
		expectNoDifference(store.pendingInstallation, prompt)
		expectNoDifference(store.selectedID, storeID)

		store.send(.ui(.respondToInstallation(prompt, accept)))
		await waitWhile { store.updateCheckResult == nil }

		expectNoDifference(resolved.value, [accept])

		// Installed, the version changed and the mark went; declined, it went and that version
		// is remembered.
		#expect(store.pendingUpdateReviews.isEmpty)
		expectNoDifference(store.updateReviews.declined.map(\.version), accept ? [] : ["2"])
		expectNoDifference(store.updateCheckResult, .init(updated: accept ? 1 : 0, declined: accept ? 0 : 1, failed: 0))
	}

	/// Declining a package of the very version that waits, from Update from Package…, counts as
	/// declining the store's offer; another version doesn't.
	@Test(arguments: ["2", "3"])
	internal func decliningThatVersionFromAPackageCountsToo(version: String) async throws {
		let before = inventory(storeVersion: "1")
		let prompt = updatePrompt(in: before, version: version)
		var state = loaded(before)
		state.pendingInstallation = prompt
		state.isWorking = true
		state.$updateReviews.withLock { $0.offered(review(version: "2")) }
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in before },
				resolveInstallation: { _, _ in before }
			)
		}

		store.send(.ui(.respondToInstallation(prompt, false)))

		expectNoDifference(store.updateReviews.declined.map(\.version), version == "2" ? ["2"] : [])
		expectNoDifference(store.pendingUpdateReviews.map(\.version), version == "2" ? [] : ["2"])
	}

	@Test
	internal func aReviewTheSiteMenuAskedForWaitsForTheInventory() async throws {
		let before = inventory(storeVersion: "1")
		let prompt = updatePrompt(in: before)
		var state = ExtensionsFeature.State(profile: profile, isAvailable: true)
		state.isPresented = true
		state.updateReviewsEnabled = true
		state.isWebstoreUpdateAvailable = true
		state.$updateReviews.withLock { $0.offered(review(version: "2")) }
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in before },
				resolveInstallation: { _, _ in before },
				webstoreUpdateAvailability: { true },
				prepareWebstoreUpdate: { _ in prompt }
			)
		}

		store.send(.ui(.refresh))
		store.send(.reviewUpdateRequested(storeID))
		#expect(store.requestedReview == storeID)
		await waitWhile { store.pendingInstallation == nil }

		expectNoDifference(store.pendingInstallation, prompt)
		#expect(store.requestedReview == nil)
	}

	/// A review the site menu asks for during a running Check for Updates starts when the check
	/// ends.
	@Test
	internal func aReviewAskedForDuringACheckStartsWhenItEnds() async throws {
		let before = inventory(storeVersion: "1")
		let prompt = updatePrompt(in: before)
		let prepared = LockIsolated<[String]>([])
		let state = loaded(before)
		state.$updateReviews.withLock { $0.offered(review(version: "2")) }
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in before },
				resolveInstallation: { _, _ in before },
				webstoreUpdateAvailability: { true },
				prepareWebstoreUpdate: { request in
					prepared.withValue { $0.append(request.extensionID) }

					// The Check for Updates finds nothing; the review then finds the offer.
					guard prepared.value.count > 2 else { throw BrowserExtensionsClient.Failure.upToDate }
					return prompt
				}
			)
		}

		store.send(.ui(.checkForUpdates))
		store.send(.reviewUpdateRequested(storeID))
		#expect(store.requestedReview == storeID)
		await waitWhile { store.pendingInstallation == nil }

		expectNoDifference(prepared.value, [storeID, otherStoreID, storeID])
		expectNoDifference(store.pendingInstallation, prompt)
		#expect(store.requestedReview == nil)
	}

	/// A review asked for while a package picker is open starts once the picker is cancelled.
	@Test
	internal func aReviewAskedForDuringAPickerStartsWhenItsCancelled() async throws {
		let before = inventory(storeVersion: "1")
		let prompt = updatePrompt(in: before)
		var state = loaded(before)
		state.isInstallationAvailable = true
		state.$updateReviews.withLock { $0.offered(review(version: "2")) }
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in before },
				resolveInstallation: { _, _ in before },
				webstoreUpdateAvailability: { true },
				prepareWebstoreUpdate: { _ in prompt }
			)
		}

		store.send(.ui(.choosePackage(nil)))
		let selection = try #require(store.packageSelection)
		store.send(.reviewUpdateRequested(storeID))
		#expect(store.requestedReview == storeID && store.updateCheck == nil)

		store.send(.ui(.cancelPackageSelection(selection)))
		await waitWhile { store.pendingInstallation == nil }

		expectNoDifference(store.pendingInstallation, prompt)
		#expect(store.requestedReview == nil)
	}

	/// A review asked for while a package was being prepared goes on after that preparation fails,
	/// once the profile is read again.
	@Test
	internal func aReviewAskedForDuringAFailedPreparationStartsAfterIt() async throws {
		let before = inventory(storeVersion: "1")
		let prompt = updatePrompt(in: before)
		let inspected = LockIsolated(0)
		var state = loaded(before)
		state.isInstallationAvailable = true
		state.$updateReviews.withLock { $0.offered(review(version: "2")) }
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in
					inspected.withValue { $0 += 1 }
					return before
				},
				prepareInstallation: { _ in
					try await Task.sleep(for: .milliseconds(50))
					throw BrowserExtensionsClient.Failure.invalidPackage
				},
				resolveInstallation: { _, _ in before },
				webstoreUpdateAvailability: { true },
				prepareWebstoreUpdate: { _ in prompt }
			)
		}

		store.send(.ui(.choosePackage(nil)))
		let selection = try #require(store.packageSelection)
		store.send(.ui(.selectPackage(selection, URL(filePath: "/tmp/Selected.crx"))))
		store.send(.reviewUpdateRequested(storeID))
		#expect(store.requestedReview == storeID)
		await waitWhile { store.pendingInstallation == nil }

		#expect(inspected.value == 1)
		expectNoDifference(store.pendingInstallation, prompt)
		#expect(store.requestedReview == nil)
	}

	@Test
	internal func anUpToDateExtensionLosesItsMark() async throws {
		let before = inventory(storeVersion: "1")
		let state = loaded(before)
		state.$updateReviews.withLock { $0.offered(review(version: "2")) }
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in before },
				webstoreUpdateAvailability: { true },
				prepareWebstoreUpdate: { _ in throw BrowserExtensionsClient.Failure.upToDate }
			)
		}

		store.send(.ui(.reviewUpdate(storeID)))
		await waitWhile { store.updateCheckResult == nil }

		#expect(store.pendingUpdateReviews.isEmpty)
		#expect(store.updateReviews.declined.isEmpty)
	}

	@Test
	internal func aLoadedInventoryClearsMarksOfExtensionsThatChangedElsewhere() async throws {
		let updated = inventory(storeVersion: "2", revision: 2)
		let state = loaded(inventory(storeVersion: "1"))
		state.$updateReviews.withLock { $0.offered(review(version: "2")) }
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(isAvailable: true, inspect: { _ in updated })
		}

		store.send(.ui(.refresh))
		await waitWhile { store.inventory != updated }

		#expect(store.pendingUpdateReviews.isEmpty)
	}

	@Test
	internal func withTheFeatureFlagOffNothingIsMarkedOrReviewed() async throws {
		let before = inventory(storeVersion: "1")
		var state = loaded(before)
		state.updateReviewsEnabled = false
		state.$updateReviews.withLock { $0.offered(review(version: "2")) }
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				webstoreUpdateAvailability: { true },
				prepareWebstoreUpdate: { _ in
					Issue.record("Off, the mark opens no review")
					throw BrowserExtensionsClient.Failure.upToDate
				}
			)
		}

		#expect(store.pendingUpdateReviews.isEmpty)
		store.send(.ui(.reviewUpdate(storeID)))
		#expect(store.updateCheck == nil)
	}

	// MARK: - Fixture

	private func review(
		extensionID: String? = nil,
		version: String
	) -> ExtensionUpdateReviews.Review {
		.init(
			profileID: profile.id,
			extensionID: extensionID ?? storeID,
			installedVersion: "1",
			version: version,
			permissions: ["storage", "tabs"]
		)
	}

	private func loaded(_ inventory: BrowserExtensionInventory) -> ExtensionsFeature.State {
		var state = ExtensionsFeature.State(profile: profile, isAvailable: true)
		state.isPresented = true
		state.inventory = inventory
		state.selectedID = inventory.extensions.first?.id
		state.isWebstoreUpdateAvailable = true
		state.updateReviewsEnabled = true
		return state
	}

	private func inventory(
		storeVersion: String,
		revision: UInt64 = 1,
		includesOther: Bool = true
	) -> BrowserExtensionInventory {
		var extensions: [BrowserExtension] = [
			.init(
				id: storeID,
				name: "Store",
				version: storeVersion,
				fromWebStore: true,
				state: .enabled,
				canDisable: true,
				canRemove: true
			),
		]
		if includesOther {
			extensions.append(.init(
				id: otherStoreID,
				name: "Other store",
				version: "1",
				fromWebStore: true,
				state: .enabled,
				canDisable: true,
				canRemove: true
			))
		}
		return .init(id: UUID(Int(revision) + 10), profileID: profile.id, revision: revision, extensions: extensions)
	}

	private func updatePrompt(
		in inventory: BrowserExtensionInventory,
		version: String = "2"
	) -> BrowserExtensionInstallPrompt {
		.init(
			id: UUID(95),
			profileID: inventory.profileID,
			inventoryID: inventory.id,
			revision: inventory.revision,
			candidate: .init(
				extensionID: storeID,
				name: "Store",
				version: version,
				packageSHA256: String(repeating: "e", count: 64),
				sourceBasename: "Chrome Web Store",
				isUpdate: true,
				requiredPermissions: .init(apis: ["storage", "tabs"], hosts: []),
				optionalPermissions: .init(apis: [], hosts: []),
				warnings: [],
				permissionIncrease: true
			)
		)
	}
}
