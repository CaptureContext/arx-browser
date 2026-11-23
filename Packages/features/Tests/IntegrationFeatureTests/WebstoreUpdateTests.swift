import BrowserCore
import BrowserExtensionsClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

extension IntegrationFeatureTests {
	/// DEV-776. The periodic check installs only updates that ask for nothing new, skips
	/// extensions that aren't from the store, and leaves a permission increase for review.
	@Test
	internal func periodicStoreCheckInstallsOnlyQuietUpdates() async throws {
		let profileID = Profile.ID(rawValue: UUID(40))
		let quietID = String(repeating: "c", count: 32)
		let increaseID = String(repeating: "d", count: 32)
		let currentID = String(repeating: "e", count: 32)
		let localID = String(repeating: "f", count: 32)
		func inventory(_ revision: UInt64) -> BrowserExtensionInventory {
			.init(
				id: UUID(Int(revision)),
				profileID: profileID,
				revision: revision,
				extensions: [quietID, increaseID, currentID, localID].map { id in
					.init(
						id: id,
						name: id,
						version: "1",
						fromWebStore: id != localID,
						state: .enabled,
						canDisable: true,
						canRemove: true
					)
				}
			)
		}
		func prompt(
			_ id: String,
			_ revision: UInt64,
			increase: Bool
		) -> BrowserExtensionInstallPrompt {
			.init(
				id: UUID(),
				profileID: profileID,
				inventoryID: UUID(Int(revision)),
				revision: revision,
				candidate: .init(
					extensionID: id,
					name: id,
					version: "2",
					packageSHA256: String(repeating: "a", count: 64),
					sourceBasename: "Chrome Web Store",
					isUpdate: true,
					requiredPermissions: .init(apis: [], hosts: []),
					optionalPermissions: .init(apis: [], hosts: []),
					warnings: [],
					permissionIncrease: increase
				)
			)
		}

		let asked = LockIsolated<[String]>([])
		let accepted = LockIsolated<[String]>([])
		let declined = LockIsolated<[String]>([])
		let revision = LockIsolated<UInt64>(1)
		let client = BrowserExtensionsClient(
			isAvailable: true,
			installationAvailability: { true },
			inspect: { _ in inventory(revision.value) },
			resolveInstallation: { prompt, accept in

				// A decline waits for native cleanup and returns the refreshed inventory.
				guard accept else {
					declined.withValue { $0.append(prompt.candidate.extensionID) }
					return inventory(revision.value)
				}
				accepted.withValue { $0.append(prompt.candidate.extensionID) }
				revision.withValue { $0 += 1 }
				return inventory(revision.value)
			},
			cancelInstallation: { _ in Issue.record("Cancelling without waiting leaves the profile busy") },
			webstoreUpdateAvailability: { true },
			prepareWebstoreUpdate: { request in
				asked.withValue { $0.append(request.extensionID) }
				switch request.extensionID {
				case quietID: return prompt(quietID, request.revision, increase: false)
				case increaseID: return prompt(increaseID, request.revision, increase: true)
				default: throw BrowserExtensionsClient.Failure.upToDate
				}
			}
		)

		await WebstoreRouting.updateWebstoreExtensions(of: profileID, client: client)

		expectNoDifference(asked.value, [quietID, increaseID, currentID])
		expectNoDifference(accepted.value, [quietID])
		expectNoDifference(declined.value, [increaseID])
	}

	/// DEV-776. A sheet opened during the periodic check may have been refused as busy, with an
	/// Add to Chrome request waiting on its inventory. The check's end reloads it, and the
	/// waiting request goes on to its review.
	@Test
	internal func finishedPeriodicCheckReloadsAnOpenExtensionsSheet() async throws {
		let durable = fixture()
		let profile = durable.profiles[0]
		var state = AppFeature.State(main: .init(organization: durable, spaceID: durable.spaces[0].id))
		state.settings.extensions.profile = profile
		state.settings.extensions.isAvailable = true
		state.settings.extensions.isPresented = true
		state.settings.extensions.isWebstoreAvailable = true
		state.settings.extensions.error = .busy
		let request = BrowserWebstoreInstallRequest(
			id: UUID(70),
			profileID: profile.id,
			extensionID: String(repeating: "b", count: 32)
		)
		state.settings.extensions.webstoreRequest = request
		let inventory = BrowserExtensionInventory(id: UUID(71), profileID: profile.id, revision: 1, extensions: [])
		let prepared = LockIsolated<[UUID]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in inventory },
				webstoreAvailability: { true },
				prepareWebstoreInstallation: { request, _ in
					prepared.withValue { $0.append(request.id) }
					throw BrowserExtensionsClient.Failure.cancelled
				}
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.webstoreUpdateCheckFinished))
		await store.receive(\.settings.extensions.ui.refresh)
		await store.skipReceivedActions()

		expectNoDifference(prepared.value, [request.id])
		#expect(store.state.settings.extensions.webstoreRequest == nil)
	}

	@Test
	internal func finishedPeriodicCheckLeavesAClosedSheetAlone() async {
		let durable = fixture()
		let store = TestStore(initialState: AppFeature.State(main: .init(organization: durable, spaceID: durable.spaces[0].id))) {
			AppFeature()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.event(.webstoreUpdateCheckFinished))
		await store.finish()
	}
}
