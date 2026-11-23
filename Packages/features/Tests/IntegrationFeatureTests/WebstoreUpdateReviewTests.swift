import BrowserCore
import BrowserExtensionsClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

extension IntegrationFeatureTests {
	/// DEV-1210. The periodic check says which updates it turned down for asking more
	/// permissions, against the version each would replace.
	@Test
	internal func periodicStoreCheckReportsTheUpdatesItTurnedDown() async throws {
		let profileID = Profile.ID(rawValue: UUID(40))
		let increaseID = String(repeating: "d", count: 32)
		let currentID = String(repeating: "e", count: 32)
		let inventory = BrowserExtensionInventory(
			id: UUID(1),
			profileID: profileID,
			revision: 1,
			extensions: [increaseID, currentID].map { id in
				.init(id: id, name: id, version: "1", fromWebStore: true, state: .enabled, canDisable: true, canRemove: true)
			}
		)
		let client = BrowserExtensionsClient(
			isAvailable: true,
			installationAvailability: { true },
			inspect: { _ in inventory },
			resolveInstallation: { _, _ in inventory },
			webstoreUpdateAvailability: { true },
			prepareWebstoreUpdate: { request in
				guard request.extensionID == increaseID else { throw BrowserExtensionsClient.Failure.upToDate }
				return Self.reviewPrompt(increaseID, profileID: profileID)
			}
		)

		let outcome = await WebstoreRouting.updateWebstoreExtensions(of: profileID, client: client)

		expectNoDifference(outcome.needsReview, [
			.init(profileID: profileID, extensionID: increaseID, installedVersion: "1", version: "2", permissions: ["storage", "tabs", "https://example.com/*"]),
		])
		expectNoDifference(outcome.inventory, inventory)

		// The store had nothing newer for the other one: a mark it had is withdrawn.
		expectNoDifference(outcome.upToDate, [currentID])
	}

	/// DEV-1210. What a profile's check turned down is remembered, except a version the person
	/// declined, and an extension that changed meanwhile loses its mark.
	@Test(arguments: [true, false])
	internal func aTurnedDownUpdateWaitsForReviewWithTheFeatureFlag(enabled: Bool) async throws {
		let durable = fixture()
		let profileID = durable.profiles[0].id
		let increaseID = String(repeating: "d", count: 32)
		let declinedID = String(repeating: "f", count: 32)
		let goneID = String(repeating: "g", count: 32)
		let withdrawnID = String(repeating: "h", count: 32)

		// Updated some other way while the check ran: its offer no longer applies.
		let changedID = String(repeating: "i", count: 32)
		var state = AppFeature.State(main: .init(organization: durable, spaceID: durable.spaces[0].id))
		state.settings.extensions.updateReviewsEnabled = enabled
		state.settings.extensions.$updateReviews.withLock {
			$0.declined(.init(profileID: profileID, extensionID: declinedID, installedVersion: "1", version: "2", permissions: []))
			$0.offered(.init(profileID: profileID, extensionID: goneID, installedVersion: "1", version: "2", permissions: []))
			$0.offered(.init(profileID: profileID, extensionID: withdrawnID, installedVersion: "1", version: "2", permissions: []))
		}
		let before = state.settings.extensions.updateReviews
		let inventory = BrowserExtensionInventory(
			id: UUID(1),
			profileID: profileID,
			revision: 1,
			extensions: [increaseID, declinedID, withdrawnID, changedID].map { id in
				.init(id: id, name: id, version: id == changedID ? "2" : "1", fromWebStore: true, state: .enabled, canDisable: true, canRemove: true)
			}
		)
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.webstoreUpdatesChecked(
			profileID,
			needsReview: [increaseID, declinedID, changedID].map {
				.init(profileID: profileID, extensionID: $0, installedVersion: "1", version: "2", permissions: ["tabs"])
			},
			upToDate: [withdrawnID],
			inventory: inventory
		)))

		let reviews = store.state.settings.extensions.updateReviews
		guard enabled else {
			expectNoDifference(reviews, before)
			return
		}

		// The withdrawn offer and the removed extension lost their marks.
		expectNoDifference(reviews.pending(in: profileID).map(\.extensionID), [increaseID])
		expectNoDifference(reviews.declined.map(\.extensionID), [declinedID])
	}

	/// DEV-1210. The site menu's Review Update… opens the profile's sheet, and the review of that
	/// update shows once the inventory is in.
	@Test
	internal func siteMenuReviewOpensTheSheetOnTheUpdatesReview() async throws {
		let organization = fixture()
		let profileID = organization.profiles[0].id
		let extensionID = String(repeating: "d", count: 32)
		let inventory = BrowserExtensionInventory(
			id: UUID(1),
			profileID: profileID,
			revision: 1,
			extensions: [
				.init(id: extensionID, name: "Store", version: "1", fromWebStore: true, state: .enabled, canDisable: true, canRemove: true),
			]
		)
		let prompt = Self.reviewPrompt(extensionID, profileID: profileID)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.settings.extensions.updateReviewsEnabled = true
		state.settings.extensions.$updateReviews.withLock {
			$0.offered(.init(profileID: profileID, extensionID: extensionID, installedVersion: "1", version: "2", permissions: ["tabs"]))
		}
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in inventory },
				webstoreUpdateAvailability: { true },
				prepareWebstoreUpdate: { request in
					#expect(request.extensionID == extensionID)
					return prompt
				}
			)
		}

		await store.send(.main(.delegate(.reviewExtensionUpdate(profileID, extensionID: extensionID)))).finish()
		await waitWhile { store.settings.extensions.pendingInstallation == nil }

		#expect(store.settingsIsOpen)
		#expect(store.settings.extensions.isPresented)
		expectNoDifference(store.settings.extensions.pendingInstallation, prompt)
		expectNoDifference(store.settings.extensions.selectedID, extensionID)
	}

	private static func reviewPrompt(
		_ extensionID: String,
		profileID: Profile.ID
	) -> BrowserExtensionInstallPrompt {
		.init(
			id: UUID(),
			profileID: profileID,
			inventoryID: UUID(1),
			revision: 1,
			candidate: .init(
				extensionID: extensionID,
				name: extensionID,
				version: "2",
				packageSHA256: String(repeating: "a", count: 64),
				sourceBasename: "Chrome Web Store",
				isUpdate: true,
				requiredPermissions: .init(apis: ["storage", "tabs"], hosts: ["https://example.com/*"]),
				optionalPermissions: .init(apis: [], hosts: []),
				warnings: [],
				permissionIncrease: true
			)
		)
	}
}
