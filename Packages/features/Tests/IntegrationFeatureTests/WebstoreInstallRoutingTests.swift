import BrowserCore
import BrowserExtensionsClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

extension IntegrationFeatureTests {
	/// DEV-801. Add to Chrome on the store opens Settings at the page's profile and presents
	/// its Extensions sheet; the request must reach the sheet after that, or the closed sheet
	/// declines it and the store's button just resets. Covers a closed Settings window, a sheet
	/// showing another profile, and a sheet already showing the profile.
	@Test(arguments: ["closed", "otherProfile", "sameProfile"])
	internal func storeInstallRequestReachesTheReview(sheet: String) async throws {
		let durable = fixture()
		let profile = durable.profiles[0]
		let otherProfile = Profile(id: .init(rawValue: UUID(72)), name: "Other")
		let inventory = BrowserExtensionInventory(
			id: UUID(71),
			profileID: profile.id,
			revision: 1,
			extensions: []
		)
		let request = BrowserWebstoreInstallRequest(
			id: UUID(70),
			profileID: profile.id,
			extensionID: String(repeating: "b", count: 32)
		)
		let prompt = BrowserExtensionInstallPrompt(
			id: UUID(73),
			profileID: profile.id,
			inventoryID: inventory.id,
			revision: inventory.revision,
			candidate: .init(
				extensionID: request.extensionID,
				name: "Store item",
				version: "1",
				packageSHA256: String(repeating: "a", count: 64),
				sourceBasename: "Chrome Web Store",
				isUpdate: false,
				requiredPermissions: .init(apis: [], hosts: ["<all_urls>"]),
				optionalPermissions: .init(apis: ["tabs"], hosts: []),
				warnings: []
			)
		)

		var state = AppFeature.State(main: .init(organization: durable, spaceID: durable.spaces[0].id))
		switch sheet {
		case "otherProfile":
			state.settingsIsOpen = true
			state.settings.extensions.profile = otherProfile
			state.settings.extensions.isAvailable = true
			state.settings.extensions.isPresented = true
			state.settings.extensions.isWebstoreAvailable = true
			state.settings.extensions.inventory = .init(id: UUID(74), profileID: otherProfile.id, revision: 1, extensions: [])

		case "sameProfile":
			state.settingsIsOpen = true
			state.settings.selectedProfileID = profile.id
			state.settings.extensionProfiles = Array(durable.profiles)
			state.settings.extensions.profile = profile
			state.settings.extensions.isAvailable = true
			state.settings.extensions.isPresented = true
			state.settings.extensions.isWebstoreAvailable = true
			state.settings.extensions.inventory = inventory

		default:
			break
		}

		let declined = LockIsolated<[BrowserWebstoreInstallRequest]>([])
		let prepared = LockIsolated<[BrowserWebstoreInstallRequest]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in inventory },
				cancelInstallation: { _ in Issue.record("The review must not be cancelled") },
				webstoreAvailability: { true },
				prepareWebstoreInstallation: { received, current in
					expectNoDifference(current, inventory)
					prepared.withValue { $0.append(received) }
					return prompt
				},
				declineWebstoreInstallation: { received in
					declined.withValue { $0.append(received) }
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.webstoreInstallRequested(request)))
		await store.skipReceivedActions()
		await store.finish()

		expectNoDifference(declined.value, [])
		expectNoDifference(prepared.value, [request])
		#expect(store.state.settingsIsOpen)
		#expect(store.state.settings.extensions.isPresented)
		expectNoDifference(store.state.settings.extensions.profile?.id, profile.id)
		expectNoDifference(store.state.settings.extensions.pendingInstallation, prompt)
	}
}
