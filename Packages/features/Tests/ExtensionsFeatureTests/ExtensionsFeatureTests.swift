import BrowserCore
import BrowserExtensionsClient
import CustomDump
import ExtensionsFeature
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct ExtensionsFeatureTests {
	private let profile: Profile = .init(id: .init(rawValue: UUID(1)), name: "Personal")
	private let other: Profile = .init(id: .init(rawValue: UUID(2)), name: "Work")
	private let extensionID: String = String(repeating: "a", count: 32)

	@Test(arguments: ["profile", "inventory", "revision", "disabled", "capability", "closed"])
	internal func staleOptionsActionCannotOpenAnotherProfileOrExtension(reason: String) async throws {
		let before = inventory(hasOptions: true)
		var state = loaded(before)
		state.optionsAvailable = true
		let request = BrowserExtensionViewRequest(inventory: before, extensionID: extensionID)
		switch reason {
		case "profile":
			state.profile = other
		case "inventory":
			state.inventory = inventory(revision: 2, hasOptions: true)
		case "revision":
			state.inventory = .init(
				id: before.id,
				profileID: before.profileID,
				revision: 2,
				extensions: before.extensions
			)
		case "disabled":
			state.inventory = inventory(enabled: false, hasOptions: true)
		case "capability":
			state.optionsAvailable = false
		case "closed":
			state.isPresented = false
		default:
			break
		}

		let store = TestStore(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				optionsAvailability: { true },
				openOptions: { _ in
					Issue.record("A stale options action reached the native boundary")
					return before
				}
			)
		}
		await store.send(.ui(.openOptions(request)))
		await store.finish()
	}

	@Test
	internal func optionsActionUsesOnlyItsExplicitInventoryAndRefreshesAuthority() async throws {
		let before = inventory(hasOptions: true)
		let after = inventory(revision: 2, hasOptions: true)
		var state = loaded(before)
		state.optionsAvailable = true
		let request = BrowserExtensionViewRequest(inventory: before, extensionID: extensionID)
		var opened: [BrowserExtensionViewRequest] = []
		let store = TestStore(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				optionsAvailability: { true },
				openOptions: { request in
					opened.append(request)
					return after
				}
			)
		}
		await store.send(.ui(.openOptions(request))) {
			$0.generation += 1
			$0.isWorking = true
		}
		await store.receive(\.event.finished) {
			$0.isWorking = false
			$0.inventory = after
		}
		await store.send(.ui(.openOptions(request)))
		expectNoDifference(opened, [request])
	}

	@Test
	internal func unavailableClientCannotPresentOrLoad() async throws {
		let store = TestStore(initialState: ExtensionsFeature.State(profile: profile)) {
			ExtensionsFeature()
		}

		await store.send(.ui(.present))
		await store.send(.ui(.refresh))
		await store.finish()
	}

	@Test
	internal func loadingUsesTheSelectedProfileAndPublishesAuthoritativeInventory() async throws {
		let value = inventory()
		let store = TestStore(initialState: ExtensionsFeature.State(profile: profile, isAvailable: true)) {
			ExtensionsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				inspect: { id in
					expectNoDifference(id, profile.id)
					return value
				}
			)
		}

		await store.send(.ui(.present)) {
			$0.isPresented = true
			$0.isWorking = true
			$0.generation = 1
		}
		await store.receive(\.event.finished) {
			$0.isWorking = false
			$0.inventory = value
			$0.selectedID = extensionID
		}
		await store.finish()
	}

	@Test
	internal func eachLoadReadsItsIconsAgainAndForgetsRemovedOnes() async throws {
		let first = iconInventory(revision: 1, icons: ["/x/a/32.png", "/x/b/32.png", nil])
		let second = iconInventory(revision: 2, icons: ["/x/a/32.png", nil, "/x/c/32.png"])
		let a = Data("a".utf8)
		let changedA = Data("a, changed".utf8)
		let c = Data("c".utf8)
		let inventories = LockIsolated([first, second])
		let reads = LockIsolated<[String]>([])
		let store = TestStore(initialState: ExtensionsFeature.State(profile: profile, isAvailable: true)) {
			ExtensionsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				inspect: { _ in inventories.withValue { $0.removeFirst() } },
				icon: { path in
					let count = reads.withValue {
						$0.append(path)
						return $0.count
					}
					return switch path {
					// An unpacked extension reloaded after its icon changed keeps its path.
					case "/x/a/32.png": count == 1 ? a : changedA
					case "/x/c/32.png": c
					default: nil
					}
				}
			)
		}

		await store.send(.ui(.present)) {
			$0.isPresented = true
			$0.isWorking = true
			$0.generation = 1
		}
		await store.receive(\.event.finished) {
			$0.isWorking = false
			$0.inventory = first
			$0.selectedID = first.extensions.first?.id
		}

		// An icon that couldn't be read keeps its letter.
		await store.receive(\.event.iconsRead) {
			$0.icons = ["/x/a/32.png": a]
		}

		await store.send(.ui(.refresh)) {
			$0.isWorking = true
			$0.generation = 2
			$0.inventory = nil
		}
		await store.receive(\.event.finished) {
			$0.isWorking = false
			$0.inventory = second
		}
		await store.receive(\.event.iconsRead) {
			$0.icons = ["/x/a/32.png": changedA, "/x/c/32.png": c]
		}
		await store.finish()

		expectNoDifference(reads.value, ["/x/a/32.png", "/x/b/32.png", "/x/a/32.png", "/x/c/32.png"])
	}

	@Test
	internal func removalRequiresTheExactConfirmationAndCannotExecuteTwice() async throws {
		let before = inventory()
		let after = BrowserExtensionInventory(
			id: UUID(12),
			profileID: profile.id,
			revision: 2,
			extensions: []
		)
		let request = BrowserExtensionRequest(
			inventory: before,
			extensionID: extensionID,
			action: .remove
		)
		var calls: [BrowserExtensionRequest] = []
		let store = TestStore(initialState: loaded(before)) {
			ExtensionsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				manage: { request in
					calls.append(request)
					return after
				}
			)
		}

		await store.send(.ui(.confirmRemoval(request)))
		await store.send(.ui(.requestRemoval(request))) { $0.pendingRemoval = request }

		let otherRequest = BrowserExtensionRequest(
			inventory: .init(id: UUID(99), profileID: profile.id, revision: 1, extensions: []),
			extensionID: extensionID,
			action: .remove
		)
		await store.send(.ui(.confirmRemoval(otherRequest)))
		#expect(calls.isEmpty)

		await store.send(.ui(.confirmRemoval(request))) {
			$0.pendingRemoval = nil
			$0.isWorking = true
			$0.generation = 1
		}
		await store.receive(\.event.finished) {
			$0.isWorking = false
			$0.inventory = after
			$0.selectedID = nil
		}
		await store.send(.ui(.confirmRemoval(request)))
		await store.finish()

		expectNoDifference(calls, [request])
	}

	@Test(arguments: [false, true])
	internal func managementDoesNotOptimisticallyChangeRows(failing: Bool) async throws {
		let before = inventory()
		let after = inventory(enabled: false, revision: 2)
		let request = BrowserExtensionRequest(
			inventory: before,
			extensionID: extensionID,
			action: .disable
		)
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		let store = Store(initialState: loaded(before)) {
			ExtensionsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				manage: { received in
					expectNoDifference(received, request)
					started.continuation.yield(())
					for await _ in release.stream { break }

					if failing { throw BrowserExtensionsClient.Failure.timeout }
					return after
				}
			)
		}

		let task = store.send(.ui(.setEnabled(request)))
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)

		#expect(store.isWorking)
		expectNoDifference(store.inventory, before)

		release.continuation.yield(())
		release.continuation.finish()
		await task.finish()

		#expect(!store.isWorking)
		expectNoDifference(store.inventory, failing ? nil : after)
		expectNoDifference(store.error, failing ? .timeout : nil)
	}

	@Test
	internal func privateWindowSwitchSendsOnlyWhatTheRowAllows() async throws {
		let before = inventory(canAllowInPrivate: true)
		let after = inventory(revision: 2, allowedInPrivate: true, canAllowInPrivate: true)
		let request = BrowserExtensionRequest(inventory: before, extensionID: extensionID, action: .allowInPrivate)
		let received = LockIsolated<[BrowserExtensionRequest]>([])
		let store = Store(initialState: loaded(before)) {
			ExtensionsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				manage: { request in
					received.withValue { $0.append(request) }
					return after
				}
			)
		}

		// Already off: turning it off again isn't sent.
		await store.send(.ui(.setAllowedInPrivate(.init(
			inventory: before,
			extensionID: extensionID,
			action: .disallowInPrivate
		)))).finish()

		// The switch never sends another kind of action.
		await store.send(.ui(.setAllowedInPrivate(.init(
			inventory: before,
			extensionID: extensionID,
			action: .disable
		)))).finish()
		await store.send(.ui(.setAllowedInPrivate(request))).finish()

		expectNoDifference(received.value, [request])
		expectNoDifference(store.inventory, after)
		#expect(store.inventory?.extensions.first?.allowedInPrivate == true)
	}

	@Test
	internal func privateWindowSwitchIsRefusedWithoutTheCapability() async throws {
		let before = inventory()
		let store = Store(initialState: loaded(before)) {
			ExtensionsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				manage: { _ in
					Issue.record("An engine without the switch must not be asked")
					return before
				}
			)
		}

		await store.send(.ui(.setAllowedInPrivate(.init(
			inventory: before,
			extensionID: extensionID,
			action: .allowInPrivate
		)))).finish()

		#expect(!store.isWorking && store.error == nil)
	}

	@Test
	internal func profileSwitchCancelsOldLoadAndRejectsItsLateResultAndActions() async throws {
		let before = inventory()
		let after = inventory(profileID: other.id)
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		let store = Store(initialState: ExtensionsFeature.State(profile: profile, isAvailable: true)) {
			ExtensionsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				inspect: { id in
					if id == other.id { return after }

					started.continuation.yield(())
					for await _ in release.stream { break }

					return before
				},
				manage: { _ in
					Issue.record("An old profile action must not be forwarded")
					return before
				}
			)
		}

		let task = store.send(.ui(.present))
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)
		let oldGeneration = store.generation

		await store.send(.configure(other)).finish()
		release.continuation.finish()
		await task.finish()
		await store.send(.event(.finished(oldGeneration, profile.id, .success(before)))).finish()
		await store.send(.ui(.setEnabled(.init(
			inventory: before,
			extensionID: extensionID,
			action: .disable
		)))).finish()

		expectNoDifference(store.profile, other)
		expectNoDifference(store.inventory, after)
		#expect(!store.isWorking && store.error == nil)
	}

	/// A profile switch right after presenting races both loads to register off the main actor.
	/// The newest load must finish whichever effect registers first.
	@Test
	internal func backToBackLoadsFinishWithTheNewestProfile() async throws {
		let before = inventory()
		let after = inventory(profileID: other.id)
		var lost = 0

		for _ in 0..<200 {
			let store = Store(initialState: ExtensionsFeature.State(profile: profile, isAvailable: true)) {
				ExtensionsFeature()
			} withDependencies: {
				$0.browserExtensions = .init(
					isAvailable: true,
					inspect: { id in id == other.id ? after : before }
				)
			}
			let older = store.send(.ui(.present))
			let newer = store.send(.configure(other))
			await older.finish()
			await newer.finish()

			if store.isWorking || store.inventory != after { lost += 1 }
		}

		#expect(lost == 0)
	}

	@Test
	internal func deletingTheSelectedProfileLoadsASurvivingProfileWithoutOldConfirmation() async throws {
		let value = inventory()
		let request = BrowserExtensionRequest(
			inventory: value,
			extensionID: extensionID,
			action: .remove
		)
		let replacement = inventory(profileID: other.id)
		var state = SettingsFeature.State(selectedProfileID: profile.id)
		state.extensions = loaded(value)
		state.extensionProfiles = [profile, other]
		state.extensions.pendingRemoval = request

		let store = Store(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				inspect: { id in
					expectNoDifference(id, other.id)
					return replacement
				},
				manage: { _ in
					Issue.record("Deleted profiles cannot mutate extensions")
					return value
				}
			)
		}

		await store.send(.configureExtensions([other])).finish()
		await store.send(.extensions(.ui(.confirmRemoval(request)))).finish()
		await store.send(.extensions(.event(.finished(0, profile.id, .success(value))))).finish()

		expectNoDifference(store.extensions.profile, other)
		expectNoDifference(store.extensions.inventory, replacement)
		#expect(store.extensions.pendingRemoval == nil && store.extensions.isPresented)
	}

	@Test(arguments: [[1, 2], [1, 1 << 29]])
	internal func pendingPermissionsAndUnknownReasonsCannotEnable(reasons: [Int]) async throws {
		var item = inventory(enabled: false).extensions[0]
		item.disableReasons = reasons.map { .init(rawValue: $0) }
		item.canEnable = true
		let value = BrowserExtensionInventory(
			id: UUID(10),
			profileID: profile.id,
			revision: 1,
			extensions: [item]
		)
		let store = TestStore(initialState: loaded(value)) {
			ExtensionsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				manage: { _ in
					Issue.record("Permission escalation must remain disabled")
					return value
				}
			)
		}

		await store.send(.ui(.setEnabled(.init(
			inventory: value,
			extensionID: extensionID,
			action: .enable
		))))
		await store.finish()
	}

	@Test
	internal func dismissInvalidatesCallbacksAndAReopenedPanelGetsNewAuthority() async throws {
		let before = inventory()
		let after = inventory(revision: 2)
		let request = BrowserExtensionRequest(
			inventory: before,
			extensionID: extensionID,
			action: .remove
		)
		let store = Store(initialState: loaded(before)) {
			ExtensionsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				inspect: { _ in after },
				manage: { _ in
					Issue.record("An old confirmation cannot survive dismissal")
					return after
				}
			)
		}

		await store.send(.ui(.requestRemoval(request))).finish()
		await store.send(.ui(.dismiss)).finish()
		await store.send(.event(.finished(0, profile.id, .success(before)))).finish()
		#expect(store.inventory == nil && !store.isPresented)

		await store.send(.ui(.present)).finish()
		await store.send(.ui(.confirmRemoval(request))).finish()

		expectNoDifference(store.inventory, after)
		#expect(store.pendingRemoval == nil)
	}

	@Test
	internal func packageSelectionPreparesVerifiedConsentBeforeOneExplicitInstall() async throws {
		let before = inventory()
		let after = inventory(revision: 2)
		let verified = installPrompt(in: before)
		var prepares = 0
		var resolutions: [Bool] = []
		var state = loaded(before)
		state.isInstallationAvailable = true
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				prepareInstallation: { request in
					#expect(request.inventoryID == before.id && request.profileID == profile.id)
					#expect(request.selectedFile.lastPathComponent == "Selected.crx")
					prepares += 1
					return verified
				},
				resolveInstallation: { prompt, accept in
					#expect(prompt == verified)
					resolutions.append(accept)
					return after
				}
			)
		}
		await store.send(.ui(.choosePackage(nil))).finish()
		let selection = try #require(store.packageSelection)
		#expect(prepares == 0 && resolutions.isEmpty)
		await store.send(.ui(.selectPackage(selection, URL(filePath: "/tmp/Selected.crx")))).finish()
		#expect(prepares == 1 && resolutions.isEmpty)
		#expect(store.pendingInstallation == verified && store.inventory == before && store.isWorking)
		await store.send(.ui(.refresh)).finish()
		await store.send(.ui(.respondToInstallation(installPrompt(in: before, id: UUID(90)), true))).finish()
		#expect(resolutions.isEmpty)
		await store.send(.ui(.respondToInstallation(verified, true))).finish()
		#expect(resolutions == [true] && store.inventory == after && !store.isWorking)
		await store.send(.ui(.respondToInstallation(verified, true))).finish()
		#expect(resolutions == [true])
	}

	@Test
	internal func dismissCancelsPendingConsentAndLatePromptCannotReopenIt() async throws {
		let before = inventory()
		let prompt = installPrompt(in: before)
		var cancellations: [BrowserExtensionInstallPrompt] = []
		var state = loaded(before)
		state.isInstallationAvailable = true
		state.isWorking = true
		state.pendingInstallation = prompt
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				cancelInstallation: { cancellations.append($0) }
			)
		}
		await store.send(.ui(.dismiss)).finish()
		#expect(cancellations == [prompt] && store.pendingInstallation == nil && store.inventory == nil)
		let latePreparation = ExtensionsFeature.PackageSelection(inventory: before, expectedExtensionID: nil)
		await store.send(.event(.prepared(0, latePreparation, .success(prompt)))).finish()
		#expect(cancellations == [prompt, prompt] && !store.isPresented && !store.isWorking)
	}

	@Test
	internal func profileChangeRejectsOldFilePickerAndCancelsLateVerifiedPackage() async throws {
		let before = inventory()
		let replacement = inventory(profileID: other.id)
		let prompt = installPrompt(in: before)
		let began = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		var cancellations: [BrowserExtensionInstallPrompt] = []
		var prepares = 0
		var state = loaded(before)
		state.isInstallationAvailable = true
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in replacement },
				prepareInstallation: { _ in
					prepares += 1
					began.continuation.yield(())
					for await _ in release.stream { break }
					return prompt
				},
				cancelInstallation: { cancellations.append($0) }
			)
		}
		await store.send(.ui(.choosePackage(nil))).finish()
		let selection = try #require(store.packageSelection)
		let task = store.send(.ui(.selectPackage(selection, URL(filePath: "/tmp/Selected.crx"))))
		var iterator = began.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)
		await store.send(.configure(other)).finish()
		release.continuation.finish()
		await task.finish()
		await store.send(.ui(.selectPackage(selection, URL(filePath: "/tmp/Selected.crx")))).finish()
		#expect(prepares == 1 && cancellations == [prompt])
		#expect(store.profile == other && store.inventory == replacement && store.pendingInstallation == nil)
	}

	@Test
	internal func verifiedEscalationRequiresNewConsentAndDeclinePreservesInstalledInventory() async throws {
		let before = inventory()
		let prompt = installPrompt(in: before, isUpdate: true)
		var approvals: [Bool] = []
		var state = loaded(before)
		state.isInstallationAvailable = true
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				prepareInstallation: { request in
					#expect(request.expectedExtensionID == extensionID)
					return prompt
				},
				resolveInstallation: { _, accept in
					approvals.append(accept)
					return before
				}
			)
		}
		await store.send(.ui(.choosePackage(extensionID))).finish()
		let selection = try #require(store.packageSelection)
		await store.send(.ui(.selectPackage(selection, URL(filePath: "/tmp/Update.crx")))).finish()
		#expect(store.pendingInstallation?.candidate.requiredPermissions.apis == ["storage", "tabs", "nativeMessaging"])
		#expect(approvals.isEmpty && store.inventory == before)
		await store.send(.ui(.respondToInstallation(prompt, false))).finish()
		#expect(approvals == [false] && store.inventory == before && !store.isWorking)
	}

	@Test
	internal func folderControlsRequireDeveloperModeAndTheNativeCapability() async throws {
		let before = inventory(unpacked: true)
		for (developerMode, capability) in [(false, true), (true, false)] {
			var state = loaded(before)
			state.developerModeEnabled = developerMode
			state.isUnpackedAvailable = capability
			let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
				$0.browserExtensions = .init(
					isAvailable: true,
					manage: { _ in
						Issue.record("Reload reached the client without its gate")
						return before
					},
					unpackedAvailability: { capability },
					loadUnpacked: { _ in
						Issue.record("A folder load reached the client without its gate")
						return before
					}
				)
			}
			#expect(!store.canLoadUnpacked)
			await store.send(.ui(.chooseUnpackedDirectory)).finish()
			#expect(store.directorySelection == nil)
			await store.send(.ui(.reload(.init(inventory: before, extensionID: extensionID, action: .reload)))).finish()
			#expect(!store.isWorking)
		}
	}

	@Test
	internal func folderSelectionLoadsIntoItsExactInventoryOnce() async throws {
		let before = inventory()
		let after = inventory(revision: 2, unpacked: true)
		let folder = URL(fileURLWithPath: "/tmp/arx-unpacked", isDirectory: true)
		var requests: [BrowserExtensionUnpackedRequest] = []
		let store = Store(initialState: developer(before)) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				unpackedAvailability: { true },
				loadUnpacked: { request in
					requests.append(request)
					return after
				}
			)
		}

		await store.send(.ui(.chooseUnpackedDirectory)).finish()
		let selection = try #require(store.directorySelection)
		expectNoDifference(selection.inventory, before)
		await store.send(.ui(.selectDirectory(selection, folder))).finish()
		await store.send(.ui(.selectDirectory(selection, folder))).finish()

		expectNoDifference(requests, [.init(inventory: before, directory: folder)])
		expectNoDifference(store.inventory, after)
		#expect(store.directorySelection == nil && store.error == nil)
	}

	@Test
	internal func profileChangeRejectsAnOldFolderPickerResult() async throws {
		let before = inventory()
		let store = Store(initialState: developer(before)) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				inspect: { [self] id in inventory(profileID: id, revision: 3) },
				unpackedAvailability: { true },
				loadUnpacked: { _ in
					Issue.record("A stale folder result reached the client")
					return before
				}
			)
		}
		await store.send(.ui(.chooseUnpackedDirectory)).finish()
		let selection = try #require(store.directorySelection)
		await store.send(.configure(other)).finish()
		#expect(store.directorySelection == nil)
		await store.send(.ui(.selectDirectory(selection, URL(fileURLWithPath: "/tmp")))).finish()
		expectNoDifference(store.inventory?.profileID, other.id)
	}

	@Test(arguments: [
		BrowserExtensionsClient.Failure.directoryMissing,
		.directoryUnreadable,
		.invalidManifest("Manifest is not valid JSON.  Line: 1, column: 1, Syntax error."),
	])
	internal func invalidFolderShowsItsActionableFailure(_ failure: BrowserExtensionsClient.Failure) async throws {
		let before = inventory()
		let store = Store(initialState: developer(before)) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				unpackedAvailability: { true },
				loadUnpacked: { _ in throw failure }
			)
		}
		await store.send(.ui(.chooseUnpackedDirectory)).finish()
		let selection = try #require(store.directorySelection)
		await store.send(.ui(.selectDirectory(selection, URL(fileURLWithPath: "/tmp/invalid")))).finish()
		expectNoDifference(store.error, failure)
		#expect(!store.isWorking)
	}

	@Test
	internal func reloadUsesTheRevisionCheckedManagementRequest() async throws {
		let before = inventory(unpacked: true)
		let after = inventory(revision: 2, unpacked: true)
		let request = BrowserExtensionRequest(inventory: before, extensionID: extensionID, action: .reload)
		var received: [BrowserExtensionRequest] = []
		let store = Store(initialState: developer(before)) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				manage: { request in
					received.append(request)
					return after
				},
				unpackedAvailability: { true }
			)
		}
		await store.send(.ui(.setEnabled(request))).finish()
		#expect(received.isEmpty)
		await store.send(.ui(.reload(request))).finish()
		await store.send(.ui(.reload(request))).finish()
		expectNoDifference(received, [request])
		expectNoDifference(store.inventory, after)
	}

	@Test
	internal func turningDeveloperModeOffHidesControlsWithoutTouchingInventory() async throws {
		let before = inventory(unpacked: true)
		let store = TestStore(initialState: developer(before)) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				manage: { _ in
					Issue.record("Turning developer mode off changed an extension")
					return before
				},
				unpackedAvailability: { true }
			)
		}
		await store.send(.configureDeveloperMode(false)) {
			$0.developerModeEnabled = false
		}
		#expect(!store.state.canLoadUnpacked)
		expectNoDifference(store.state.inventory, before)
		await store.send(.ui(.reload(.init(inventory: before, extensionID: extensionID, action: .reload))))
		await store.send(.configureDeveloperMode(true)) {
			$0.developerModeEnabled = true
		}
		#expect(store.state.canLoadUnpacked)
	}

	/// DEV-765. A store request that arrives while the sheet loads waits for the
	/// inventory, then the downloaded package comes up for review.
	@Test
	internal func webstoreRequestWaitsForInventoryThenShowsReview() async throws {
		let loadedInventory = inventory()
		let request = webstoreRequest()
		let prompt = webstorePrompt(in: loadedInventory)
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		let store = Store(initialState: ExtensionsFeature.State(profile: profile, isAvailable: true)) {
			ExtensionsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in
					started.continuation.yield(())
					for await _ in release.stream { break }
					return loadedInventory
				},
				webstoreAvailability: { true },
				prepareWebstoreInstallation: { received, inventory in
					expectNoDifference(received, request)
					expectNoDifference(inventory, loadedInventory)
					return prompt
				},
				declineWebstoreInstallation: { _ in
					Issue.record("A request the sheet can review must not be declined")
				}
			)
		}

		let load = store.send(.ui(.present))
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)
		await store.send(.webstoreRequested(request)).finish()
		expectNoDifference(store.webstoreRequest, request)
		#expect(store.pendingInstallation == nil)

		release.continuation.finish()
		await load.finish()
		await waitWhile { store.pendingInstallation == nil }

		expectNoDifference(store.pendingInstallation, prompt)
		#expect(store.webstoreRequest == nil)
	}

	@Test(arguments: ["profile", "selection", "unavailable"])
	internal func webstoreRequestTheSheetCannotTakeIsDeclined(reason: String) async throws {
		var state = loaded(inventory())
		state.isWebstoreAvailable = reason != "unavailable"
		if reason == "selection" { state.packageSelection = .init(inventory: inventory(), expectedExtensionID: nil) }
		let request = webstoreRequest(profileID: reason == "profile" ? other.id : profile.id)
		let declined = LockIsolated<[BrowserWebstoreInstallRequest]>([])
		let store = Store(initialState: state) {
			ExtensionsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				webstoreAvailability: { reason != "unavailable" },
				prepareWebstoreInstallation: { _, _ in
					Issue.record("A declined request must not download")
					throw BrowserExtensionsClient.Failure.unavailable
				},
				declineWebstoreInstallation: { received in declined.withValue { $0.append(received) } }
			)
		}

		await store.send(.webstoreRequested(request)).finish()

		expectNoDifference(declined.value, [request])
		#expect(store.webstoreRequest == nil && store.pendingInstallation == nil && !store.isWorking)
	}

	@Test
	internal func dismissDeclinesAWaitingWebstoreRequest() async throws {
		var state = loaded(inventory())
		state.isWebstoreAvailable = true
		state.isWorking = true
		let request = webstoreRequest()
		let declined = LockIsolated<[BrowserWebstoreInstallRequest]>([])
		let store = Store(initialState: state) {
			ExtensionsFeature()
		} withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				webstoreAvailability: { true },
				declineWebstoreInstallation: { received in declined.withValue { $0.append(received) } }
			)
		}

		await store.send(.webstoreRequested(request)).finish()
		expectNoDifference(store.webstoreRequest, request)
		await store.send(.ui(.dismiss)).finish()

		expectNoDifference(declined.value, [request])
		#expect(store.webstoreRequest == nil)
	}

	private func webstoreRequest(profileID: Profile.ID? = nil) -> BrowserWebstoreInstallRequest {
		.init(id: UUID(90), profileID: profileID ?? profile.id, extensionID: String(repeating: "b", count: 32))
	}

	// MARK: - Store updates (DEV-776)

	@Test
	internal func checkForUpdatesInstallsAQuietUpdateAndSkipsAnUpToDateOne() async throws {
		let before = storeInventory(revision: 1)
		let after = storeInventory(revision: 2, updatedVersion: "2")
		let quiet = updatePrompt(in: before, extensionID: storeID, permissionIncrease: false)
		let prepared = LockIsolated<[String]>([])
		let resolved = LockIsolated<[Bool]>([])
		var state = loaded(before)
		state.isWebstoreUpdateAvailable = true
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				resolveInstallation: { prompt, accept in
					expectNoDifference(prompt, quiet)
					resolved.withValue { $0.append(accept) }
					return after
				},
				webstoreUpdateAvailability: { true },
				prepareWebstoreUpdate: { request in
					prepared.withValue { $0.append(request.extensionID) }
					guard request.extensionID == storeID else {
						// The second check runs against the inventory the update returned.
						#expect(request.revision == 2)
						throw BrowserExtensionsClient.Failure.upToDate
					}
					#expect(request.revision == 1)
					return quiet
				}
			)
		}

		#expect(store.updatableExtensionIDs == [storeID, otherStoreID])
		store.send(.ui(.checkForUpdates))
		await waitWhile { store.updateCheckResult == nil }

		expectNoDifference(prepared.value, [storeID, otherStoreID])
		expectNoDifference(resolved.value, [true])
		expectNoDifference(store.updateCheckResult, .init(updated: 1, failed: 0))
		expectNoDifference(store.inventory, after)
		#expect(store.pendingInstallation == nil && store.updateCheck == nil && !store.isWorking)
	}

	@Test(arguments: [true, false])
	internal func anUpdateAskingForMorePermissionsWaitsForReview(accept: Bool) async throws {
		let before = storeInventory(revision: 1)
		let after = storeInventory(revision: 2, updatedVersion: accept ? "2" : "1")
		let review = updatePrompt(in: before, extensionID: storeID, permissionIncrease: true)
		let resolved = LockIsolated<[Bool]>([])
		var state = loaded(before)
		state.isWebstoreUpdateAvailable = true
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in after },
				resolveInstallation: { _, accept in
					resolved.withValue { $0.append(accept) }

					// The adapter answers a decline with the refreshed, unchanged inventory.
					return after
				},
				webstoreUpdateAvailability: { true },
				prepareWebstoreUpdate: { request in
					guard request.extensionID == storeID
					else { throw BrowserExtensionsClient.Failure.upToDate }
					return review
				}
			)
		}

		store.send(.ui(.checkForUpdates))
		await waitWhile { store.pendingInstallation == nil }
		expectNoDifference(store.pendingInstallation, review)
		#expect(resolved.value.isEmpty)

		store.send(.ui(.respondToInstallation(review, accept)))
		await waitWhile { store.updateCheckResult == nil }

		expectNoDifference(resolved.value, [accept])

		// A declined review is neither an update nor a failure, and the check goes on.
		expectNoDifference(store.updateCheckResult, .init(updated: accept ? 1 : 0, declined: accept ? 0 : 1, failed: 0))
		#expect(store.error == nil && store.inventory == after)
	}

	@Test
	internal func aFailedCheckReloadsAndGoesOnToTheNextExtension() async throws {
		let before = storeInventory(revision: 1)
		let reloaded = storeInventory(revision: 2)
		var state = loaded(before)
		state.isWebstoreUpdateAvailable = true
		let store = Store(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				inspect: { _ in reloaded },
				webstoreUpdateAvailability: { true },
				prepareWebstoreUpdate: { request in
					guard request.extensionID == storeID
					else { throw BrowserExtensionsClient.Failure.upToDate }
					throw BrowserExtensionsClient.Failure.invalidPackage
				}
			)
		}

		store.send(.ui(.checkForUpdates))
		await waitWhile { store.updateCheckResult == nil }

		expectNoDifference(store.updateCheckResult, .init(updated: 0, failed: 1))
		#expect(store.error == nil && store.inventory == reloaded)
	}

	@Test(arguments: ["capability", "working", "none"])
	internal func checkForUpdatesNeedsTheCapabilityAndAStoreExtension(reason: String) async throws {
		var state = loaded(reason == "none" ? inventory() : storeInventory(revision: 1))
		state.isWebstoreUpdateAvailable = reason != "capability"
		state.isWorking = reason == "working"
		let store = TestStore(initialState: state) { ExtensionsFeature() } withDependencies: {
			$0.browserExtensions = .init(
				isAvailable: true,
				installationAvailability: { true },
				webstoreUpdateAvailability: { reason != "capability" },
				prepareWebstoreUpdate: { _ in
					Issue.record("No update check may start")
					throw BrowserExtensionsClient.Failure.unavailable
				}
			)
		}

		if reason == "none" {
			// The only extension isn't from the store: the check ends at once with nothing to do.
			await store.send(.ui(.checkForUpdates)) {
				$0.updateCheckResult = .init(updated: 0, failed: 0)
			}
		} else {
			await store.send(.ui(.checkForUpdates))
		}
		await store.finish()
	}

	private var storeID: String { String(repeating: "c", count: 32) }
	private var otherStoreID: String { String(repeating: "d", count: 32) }

	/// The local fixture plus two store extensions.
	private func storeInventory(
		revision: UInt64,
		updatedVersion: String = "1"
	) -> BrowserExtensionInventory {
		let local = inventory(revision: revision)
		return .init(
			id: local.id,
			profileID: local.profileID,
			revision: revision,
			extensions: local.extensions + [
				.init(
					id: storeID,
					name: "Store",
					version: updatedVersion,
					fromWebStore: true,
					state: .enabled,
					canDisable: true,
					canRemove: true
				),
				.init(
					id: otherStoreID,
					name: "Other store",
					version: "1",
					fromWebStore: true,
					state: .enabled,
					canDisable: true,
					canRemove: true
				),
			]
		)
	}

	private func updatePrompt(
		in inventory: BrowserExtensionInventory,
		extensionID: String,
		permissionIncrease: Bool
	) -> BrowserExtensionInstallPrompt {
		.init(
			id: UUID(95),
			profileID: inventory.profileID,
			inventoryID: inventory.id,
			revision: inventory.revision,
			candidate: .init(
				extensionID: extensionID,
				name: "Store",
				version: "2",
				packageSHA256: String(repeating: "e", count: 64),
				sourceBasename: "Chrome Web Store",
				isUpdate: true,
				requiredPermissions: .init(apis: permissionIncrease ? ["storage", "tabs"] : ["storage"], hosts: []),
				optionalPermissions: .init(apis: [], hosts: []),
				warnings: [],
				permissionIncrease: permissionIncrease
			)
		)
	}

	private func webstorePrompt(in inventory: BrowserExtensionInventory) -> BrowserExtensionInstallPrompt {
		.init(
			id: UUID(91),
			profileID: inventory.profileID,
			inventoryID: inventory.id,
			revision: inventory.revision,
			candidate: .init(
				extensionID: String(repeating: "b", count: 32),
				name: "Store item",
				version: "1",
				packageSHA256: String(repeating: "c", count: 64),
				sourceBasename: "Chrome Web Store",
				isUpdate: false,
				requiredPermissions: .init(apis: ["storage"], hosts: ["<all_urls>"]),
				optionalPermissions: .init(apis: [], hosts: []),
				warnings: []
			)
		)
	}

	private func developer(_ inventory: BrowserExtensionInventory) -> ExtensionsFeature.State {
		var state = loaded(inventory)
		state.developerModeEnabled = true
		state.isUnpackedAvailable = true

		return state
	}

	private func installPrompt(
		in inventory: BrowserExtensionInventory,
		id: UUID = UUID(80),
		isUpdate: Bool = false
	) -> BrowserExtensionInstallPrompt {
		.init(
			id: id,
			profileID: inventory.profileID,
			inventoryID: inventory.id,
			revision: inventory.revision,
			candidate: .init(
				extensionID: extensionID,
				name: "Verified fixture",
				version: isUpdate ? "2" : "1",
				packageSHA256: String(repeating: "a", count: 64),
				sourceBasename: "Selected.crx",
				isUpdate: isUpdate,
				requiredPermissions: .init(
					apis: isUpdate ? ["storage", "tabs", "nativeMessaging"] : ["storage"],
					hosts: []
				),
				optionalPermissions: .init(apis: [], hosts: []),
				warnings: []
			)
		)
	}

	/// Extensions a, b and c, each with the icon path given for it.
	private func iconInventory(
		revision: UInt64,
		icons: [String?]
	) -> BrowserExtensionInventory {
		.init(
			id: UUID(Int(revision) + 20),
			profileID: profile.id,
			revision: revision,
			extensions: zip(["a", "b", "c"], icons).map { letter, icon in
				.init(
					id: String(repeating: letter, count: 32),
					name: letter.uppercased(),
					version: "1",
					state: .enabled,
					iconPath: icon
				)
			}
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
		enabled: Bool = true,
		revision: UInt64 = 1,
		hasOptions: Bool = false,
		unpacked: Bool = false,
		allowedInPrivate: Bool = false,
		canAllowInPrivate: Bool = false
	) -> BrowserExtensionInventory {
		.init(
			id: UUID(Int(revision) + 10),
			profileID: profileID ?? profile.id,
			revision: revision,
			extensions: [
				.init(
					id: extensionID,
					name: "Fixture",
					version: "1",
					state: enabled ? .enabled : .disabled,
					disableReasons: enabled ? [] : [.userAction],
					canEnable: !enabled,
					canDisable: enabled,
					canRemove: true,
					canOpenOptions: hasOptions,
					canReload: unpacked,
					sourcePath: unpacked ? "/tmp/arx-unpacked" : nil,
					allowedInPrivate: allowedInPrivate,
					canAllowInPrivate: canAllowInPrivate
				),
			]
		)
	}
}
