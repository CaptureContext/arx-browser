import BrowserCore
import BrowserExtensionsClient
import CustomDump
import ExtensionsFeature
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-801: an installed extension's settings are easy to reach.
extension IntegrationFeatureTests {
	private static let plainID: String = .init(repeating: "a", count: 32)
	private static let optionsID: String = .init(repeating: "b", count: 32)

	private func discoveryInventory(
		_ profileID: Profile.ID,
		revision: UInt64 = 1
	) -> BrowserExtensionInventory {
		.init(
			id: UUID(Int(revision) + 80),
			profileID: profileID,
			revision: revision,
			extensions: [
				.init(id: Self.plainID, name: "Plain", version: "1", state: .enabled, canDisable: true, canRemove: true),
				.init(
					id: Self.optionsID,
					name: "With Options",
					version: "1",
					fromWebStore: true,
					state: .enabled,
					canDisable: true,
					canRemove: true,
					canOpenOptions: true
				),
			]
		)
	}

	/// Clicking an extension in the site menu opens the profile's sheet on that extension,
	/// not on the first one in the list.
	@Test
	internal func siteMenuExtensionOpensTheSheetOnIt() async throws {
		let organization = fixture()
		let profileID = organization.profiles[0].id
		let inventory = discoveryInventory(profileID)
		let store = Store(initialState: AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))) {
			AppFeature()
		} withDependencies: {
			$0.browserExtensions = .init(isAvailable: true, inspect: { _ in inventory })
		}

		await store.send(.main(.delegate(.showExtension(profileID, extensionID: Self.optionsID)))).finish()

		#expect(store.settingsIsOpen)
		#expect(store.settings.extensions.isPresented)
		expectNoDifference(store.settings.extensions.inventory, inventory)
		expectNoDifference(store.settings.extensions.selectedID, Self.optionsID)
	}

	/// Options in an extension's site-menu menu opens its options page with the profile's
	/// current inventory. An extension without one, or a profile the workspace doesn't have,
	/// opens nothing.
	@Test
	internal func siteMenuOptionsOpenTheExtensionsOptionsPage() async throws {
		let organization = fixture()
		let profileID = organization.profiles[0].id
		let inventory = discoveryInventory(profileID)
		let opened = LockIsolated<[BrowserExtensionViewRequest]>([])
		let store = Store(initialState: AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))) {
			AppFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				optionsAvailability: { true },
				openOptions: { request in
					opened.withValue { $0.append(request) }
					return inventory
				},
				inspect: { _ in inventory }
			)
		}

		await store.send(.main(.delegate(.openExtensionOptions(profileID, extensionID: Self.optionsID)))).finish()
		await store.send(.main(.delegate(.openExtensionOptions(profileID, extensionID: Self.plainID)))).finish()
		await store.send(.ui(.openExtensionOptions(.init(rawValue: UUID(99)), extensionID: Self.optionsID))).finish()

		expectNoDifference(opened.value, [.init(inventory: inventory, extensionID: Self.optionsID)])
		#expect(!store.settingsIsOpen)
	}

	/// Opening options reads the inventory, which replaces the authority an open sheet on that
	/// profile holds, and a failed open consumes it too. The sheet reads again on every path,
	/// so its next action isn't refused as stale.
	@Test(arguments: ["failed", "noOptions"])
	internal func siteMenuOptionsRefreshAnOpenSheetOnThatProfile(outcome: String) async throws {
		let organization = fixture()
		let profile = organization.profiles[0]
		let reads = LockIsolated(1)
		let inventories = (1...8).map { discoveryInventory(profile.id, revision: UInt64($0)) }
		let inspect: @Sendable () -> BrowserExtensionInventory = {
			reads.withValue { $0 += 1 }
			return inventories[reads.value - 1]
		}
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.settingsIsOpen = true
		state.settings.extensions.profile = profile
		state.settings.extensions.isAvailable = true
		state.settings.extensions.isPresented = true
		state.settings.extensions.optionsAvailable = true
		state.settings.extensions.inventory = discoveryInventory(profile.id)
		let store = Store(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				optionsAvailability: { true },
				openOptions: { _ in throw BrowserExtensionsClient.Failure.staleInventory },
				inspect: { _ in inspect() }
			)
		}

		let extensionID = outcome == "failed" ? Self.optionsID : Self.plainID
		await store.send(.ui(.openExtensionOptions(profile.id, extensionID: extensionID))).finish()
		await waitWhile { store.settings.extensions.inventory?.revision != 3 }

		// Revision 2 was the site menu's read; the sheet's own read is revision 3.
		expectNoDifference(store.settings.extensions.inventory?.revision, 3)
		#expect(!store.settings.extensions.isWorking)
	}

	/// Settings' search finds Extensions and opens the selected profile's sheet.
	@Test
	internal func settingsSearchOpensTheExtensionsSheet() async throws {
		let organization = fixture()
		let profileID = organization.profiles[0].id
		let inventory = discoveryInventory(profileID)
		let store = Store(initialState: AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))) {
			AppFeature()
		} withDependencies: {
			$0.browserExtensions = .init(isAvailable: true, inspect: { _ in inventory })
		}

		let entry = try #require(SettingsCategory.profiles.searchIndex.first { $0.destination == .extensions })
		#expect(entry.keywords.contains { $0.localizedCaseInsensitiveContains("Chrome Web Store") })

		await store.send(.ui(.openSettings)).finish()
		await store.send(.settings(.ui(.searchResultChosen(.extensions)))).finish()

		expectNoDifference(store.settings.category, .profiles)
		expectNoDifference(store.settings.page, .profile)
		expectNoDifference(store.settings.selectedProfileID, profileID)
		#expect(store.settings.extensions.isPresented)
		expectNoDifference(store.settings.extensions.inventory, inventory)
	}

	/// After Install, the sheet shows what was just installed, with its Options.
	@Test
	internal func acceptedInstallSelectsTheNewExtension() async throws {
		let organization = fixture()
		let profile = organization.profiles[0]
		let before = BrowserExtensionInventory(
			id: UUID(90),
			profileID: profile.id,
			revision: 1,
			extensions: [discoveryInventory(profile.id).extensions[0]]
		)
		let after = discoveryInventory(profile.id, revision: 2)
		let prompt = BrowserExtensionInstallPrompt(
			id: UUID(91),
			profileID: profile.id,
			inventoryID: before.id,
			revision: before.revision,
			candidate: .init(
				extensionID: Self.optionsID,
				name: "With Options",
				version: "1",
				packageSHA256: String(repeating: "c", count: 64),
				sourceBasename: "Chrome Web Store",
				isUpdate: false,
				requiredPermissions: .init(apis: [], hosts: []),
				optionalPermissions: .init(apis: [], hosts: []),
				warnings: []
			)
		)
		var state = ExtensionsFeature.State(profile: profile, isAvailable: true)
		state.isPresented = true
		state.isWorking = true
		state.inventory = before
		state.selectedID = Self.plainID
		state.pendingInstallation = prompt
		let store = Store(initialState: state) {
			ExtensionsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				resolveInstallation: { _, accept in
					#expect(accept)
					return after
				}
			)
		}

		await store.send(.ui(.respondToInstallation(prompt, true))).finish()

		expectNoDifference(store.inventory, after)
		expectNoDifference(store.selectedID, Self.optionsID)
	}
}
