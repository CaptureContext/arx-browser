import BrowserCaptureClient
import BrowserCore
import BrowserExtensionsClient
import BrowserMediaClient
import BrowserPageInspectionClient
import CustomDump
import Foundation
import PageCaptureFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct BrowserCapabilitiesTests {
	@Test
	internal func preconstructedDependenciesFollowReadinessAndObservationShutdown() async throws {
		let running = CapabilityFlag(false)
		var factories = 0
		let observations = AsyncStream<BrowserMediaSnapshot>.makeStream()
		let started = AsyncStream<Void>.makeStream()

		let capabilities = BrowserCapabilities(
			isRunning: { running.value },
			capture: .init(isAvailable: { true }),
			media: {
				factories += 1

				return .init(
					isAvailable: true,
					events: {
						started.continuation.yield(())
						return observations.stream
					}
				)
			},
			extensions: { _ in .init(isAvailable: true) }
		)
		let store = store(capabilities)

		capabilities.activate()
		await store.send(.configureMedia).finish()
		await store.send(.configureCapture).finish()
		await store.send(.settings(.configureExtensions(Array(store.workspace.profiles)))).finish()

		#expect(factories == 0)
		#expect(!store.media.isAvailable && !store.captureAvailable && !store.settings.extensions.isAvailable)

		running.value = true
		capabilities.activate()
		capabilities.activate()
		let observation = store.send(.configureMedia)
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)
		await store.send(.configureCapture).finish()
		await store.send(.settings(.configureExtensions(Array(store.workspace.profiles)))).finish()

		#expect(factories == 1)
		#expect(
			store.media.isAvailable
			&& store.media.isObserving
			&& store.captureAvailable
			&& store.settings.extensions.isAvailable
		)

		capabilities.stop()
		await observation.finish()
		await store.send(.configureCapture).finish()
		await store.send(.settings(.configureExtensions(Array(store.workspace.profiles)))).finish()

		#expect(
			!store.media.isAvailable
			&& !store.media.isObserving
			&& !store.captureAvailable
			&& !store.settings.extensions.isAvailable
		)
		#expect(
			!capabilities.media.isAvailable
			&& !capabilities.capture.isAvailable()
			&& !capabilities.extensions.isAvailable
		)
		capabilities.activate()
		#expect(factories == 1)
	}

	@Test(arguments: [false, true])
	internal func runtimeStoppingOrOwnerReleaseImmediatelyRevokesClients(releaseOwner: Bool) async throws {
		let running = CapabilityFlag(true)
		let capabilities = BrowserCapabilities(
			isRunning: { running.value },
			capture: .init(isAvailable: { true }),
			media: { .init(isAvailable: true) },
			extensions: { _ in .init(isAvailable: true) }
		)
		var owner: StoreOf<AppFeature>? = store(capabilities)
		let profile = try #require(owner?.workspace.profiles.first?.id)

		capabilities.activate()
		#expect(
			capabilities.media.isAvailable
			&& capabilities.capture.isAvailable()
			&& capabilities.extensions.isAvailable
		)

		if releaseOwner { owner = nil } else { running.value = false }

		#expect(
			!capabilities.media.isAvailable
			&& !capabilities.capture.isAvailable()
			&& !capabilities.extensions.isAvailable
		)
		await #expect(throws: BrowserExtensionsClient.Failure.unavailable) {
			try await capabilities.extensions.inspect(profile)
		}
	}

	/// DEV-800 review: Mute Tab did nothing because the app's media client dropped the tab-level calls.
	@Test
	internal func muteTabReachesTheNativeClient() async throws {
		let muted = LockIsolated<Set<BrowserCore.Tab.ID>>([])
		let volumes = LockIsolated<[BrowserCore.Tab.ID: Double]>([:])
		let capabilities = BrowserCapabilities(
			isRunning: { true },
			capture: .init(isAvailable: { true }),
			media: {
				.init(
					isAvailable: true,
					position: { id in .init(sourceID: nil, isMuted: muted.value.contains(id)) },
					setMuted: { id, isMuted in
						muted.withValue { if isMuted { $0.insert(id) } else { $0.remove(id) } }
					},
					supportsVolume: { true },
					setVolume: { id, volume in volumes.withValue { $0[id] = volume } }
				)
			},
			extensions: { _ in .init(isAvailable: true) }
		)
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.media.isAvailable = true
		state.main.mediaAvailable = true
		let tab = organization.tabs[1]

		let store = Store(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.browserMedia = capabilities.media
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		capabilities.store = store
		capabilities.activate()

		// The tab row's menu, as the sidebar sends it.
		await store.send(.main(.sidebar(.ui(.sidebar(.setMuted(.tab(tab.id.rawValue), true)))))).finish()
		expectNoDifference(muted.value, [tab.id])
		expectNoDifference(store.mutedTabs, [tab.id])
		#expect(capabilities.media.position(tab.id)?.isMuted == true)

		await store.send(.ui(.setTabMuted(tab.id, false))).finish()
		expectNoDifference(muted.value, [])
		expectNoDifference(store.mutedTabs, [])

		#expect(capabilities.media.supportsVolume())
		try capabilities.media.setVolume(tab.id, 0.4)
		expectNoDifference(volumes.value, [tab.id: 0.4])

		// A tab this window doesn't own is refused before it reaches the engine.
		let stranger = BrowserCore.Tab.ID(rawValue: UUID())
		#expect(throws: BrowserMediaClient.Failure.staleSource) {
			try capabilities.media.setMuted(stranger, true)
		}
		#expect(capabilities.media.position(stranger) == nil)
		expectNoDifference(muted.value, [])

		capabilities.stop()
		#expect(throws: BrowserMediaClient.Failure.unavailable) {
			try capabilities.media.setMuted(tab.id, true)
		}
		#expect(!capabilities.media.supportsVolume())
	}

	@Test
	internal func pdfFollowsTheNativeClientAndRuntime() async throws {
		let running = CapabilityFlag(true)
		let request = PagePDFRequest(
			tabID: IntegrationFeatureTests().fixture().tabs[0].id,
			revision: 1,
			documentRevision: 1,
			kind: .source,
			maximumBytes: 1024
		)
		let capabilities = BrowserCapabilities(
			isRunning: { running.value },
			capture: .init(
				isAvailable: { true },
				pdfIsAvailable: { true },
				pdfAuthorized: { request, authorize in
					guard authorize() else { throw PageCaptureFailure.staleDocument }
					return .init(request: request, documentID: "document", data: Data("%PDF".utf8))
				}
			),
			media: { .init(isAvailable: true) },
			extensions: { _ in .init(isAvailable: true) }
		)
		let owner = store(capabilities)
		let capture = capabilities.capture

		capabilities.activate()
		#expect(capture.pdfIsAvailable())
		let pdf = try await capture.pdfAuthorized(request) { true }
		expectNoDifference(pdf.documentID, "document")
		await #expect(throws: PageCaptureFailure.staleDocument) {
			try await capture.pdfAuthorized(request) { false }
		}

		running.value = false
		#expect(!capture.pdfIsAvailable())
		await #expect(throws: PageCaptureFailure.unavailable) {
			try await capture.pdfAuthorized(request) { true }
		}
		_ = owner
	}

	@Test
	internal func canceledQuitKeepsTheSameClientsAvailable() async throws {
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		let capabilities = BrowserCapabilities(
			isRunning: { true },
			capture: .init(isAvailable: { true }),
			media: { .init(isAvailable: true) },
			extensions: { _ in .init(isAvailable: true) }
		)
		let capture = capabilities.capture
		let media = capabilities.media
		let extensions = capabilities.extensions

		let store = store(
			capabilities,
			configure: {
				$0.browserEngine.permitsClosing = { _ in
					started.continuation.yield(())
					for await _ in release.stream { break }
					return true
				}
			}
		)

		capabilities.activate()
		let quitting = store.send(.ui(.quit))
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)

		#expect(store.checkingQuit && !store.shouldQuit)
		#expect(capture.isAvailable() && media.isAvailable && extensions.isAvailable)

		await store.send(.ui(.cancelQuit)).finish()
		release.continuation.finish()
		await quitting.finish()

		#expect(!store.checkingQuit && !store.shouldQuit)
		#expect(capture.isAvailable() && media.isAvailable && extensions.isAvailable)
	}

	@Test
	internal func canceledQuitRetainsMediaObservedWhileClosingWithoutANewSnapshot() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[0]
		var source = BrowserMediaSource(
			id: .init(tabID: tab.id, profileID: tab.profileID, generation: 1),
			revision: 1,
			title: "Ordinary",
			site: nil,
			playback: .playing,
			actions: [.pause]
		)
		let snapshots = AsyncStream<BrowserMediaSnapshot>.makeStream()
		let observed = AsyncStream<BrowserMediaSnapshot>.makeStream()
		let closing = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		var commands = 0

		let capabilities = BrowserCapabilities(
			isRunning: { true },
			capture: .init(),
			media: {
				.init(
					isAvailable: true,
					events: { snapshots.stream },
					isSourceCurrent: { _ in true },
					perform: { _ in commands += 1 }
				)
			},
			extensions: { _ in .init() }
		)
		let media = capabilities.media
		let store = store(
			capabilities,
			organization: organization,
			observeSnapshot: { observed.continuation.yield($0) }
		) {
			$0.browserEngine.permitsClosing = { _ in
				closing.continuation.yield(())
				for await _ in release.stream { break }
				return true
			}
		}

		capabilities.activate()
		let observation = store.send(.configureMedia)
		var received = observed.stream.makeAsyncIterator()
		snapshots.continuation.yield(.init(revision: 1, sources: [source]))
		try #require(await received.next() != nil)

		expectNoDifference(store.media.visibleSources, [source])

		let quitting = store.send(.ui(.quit))
		var started = closing.stream.makeAsyncIterator()
		try #require(await started.next() != nil)
		#expect(store.checkingQuit && !store.shouldQuit)

		source.revision = 2
		source.playback = .paused
		snapshots.continuation.yield(.init(revision: 2, sources: [source]))
		try #require(await received.next() != nil)

		expectNoDifference(store.media.visibleSources, [source])
		#expect(!media.isSourceCurrent(source.id))
		await #expect(throws: BrowserMediaClient.Failure.staleSource) {
			try await media.perform(.init(source: source, action: .pause))
		}
		#expect(commands == 0)

		await store.send(.ui(.cancelQuit)).finish()
		release.continuation.finish()
		await quitting.finish()

		#expect(!store.checkingQuit && !store.shouldQuit)
		expectNoDifference(store.media.snapshot, .init(revision: 2, sources: [source]))
		expectNoDifference(store.media.visibleSources, [source])
		#expect(media.isSourceCurrent(source.id))
		try await media.perform(.init(source: source, action: .pause))
		#expect(commands == 1)

		capabilities.stop()
		await observation.finish()
	}

	@Test
	internal func unavailableMediaFactoryDoesNotDisableOtherCapabilities() {
		let capabilities = BrowserCapabilities(
			isRunning: { true },
			capture: .init(isAvailable: { true }),
			media: { throw BrowserMediaClient.Failure.unavailable },
			extensions: { _ in .init(isAvailable: true) }
		)
		let store = store(capabilities)
		defer { _ = store }

		withKnownIssue("Media initialization failure is reported without disabling other capabilities.") {
			capabilities.activate()
		}

		#expect(!capabilities.media.isAvailable)
		#expect(capabilities.capture.isAvailable() && capabilities.extensions.isAvailable)
	}

	@Test(arguments: [false, true])
	internal func deletedProfileCannotStartOrPublishExtensionWork(managing: Bool) async throws {
		let profile = Profile.ID(rawValue: UUID(91))
		let inventory = BrowserExtensionInventory(
			id: UUID(92),
			profileID: profile,
			revision: 1,
			extensions: []
		)
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		var authorize: (@MainActor @Sendable (Profile.ID) -> Bool)?
		var calls = 0

		let operation: @MainActor @Sendable () async -> BrowserExtensionInventory = {
			calls += 1
			started.continuation.yield(())
			for await _ in release.stream { break }
			return inventory
		}
		let capabilities = BrowserCapabilities(
			isRunning: { true },
			capture: .init(),
			media: { .init() },
			extensions: {
				authorize = $0

				return .init(
					isAvailable: true,
					inspect: { _ in await operation() },
					manage: { _ in await operation() }
				)
			}
		)

		var organization = IntegrationFeatureTests().fixture()
		organization.profiles.append(.init(id: profile, name: "Removed"))
		let store = store(capabilities, organization: organization)
		capabilities.activate()

		let request = BrowserExtensionRequest(
			inventory: inventory,
			extensionID: String(repeating: "a", count: 32),
			action: .remove
		)
		let task = Task {
			if managing {
				return try await capabilities.extensions.manage(request)
			}

			return try await capabilities.extensions.inspect(profile)
		}
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)

		await store.send(.settings(.delegate(.changeOrganization(.removeProfile(profile))))).finish()
		#expect(authorize?(profile) == false)
		release.continuation.finish()

		await #expect(throws: BrowserExtensionsClient.Failure.missingProfile) {
			try await task.value
		}
		await #expect(throws: BrowserExtensionsClient.Failure.missingProfile) {
			try await capabilities.extensions.manage(request)
		}
		#expect(calls == 1)
	}

	/// DEV-801: the app's client forwards the Chrome Web Store members, so the sheet shows the
	/// store button and Add to Chrome reaches it, and only for profiles this window owns.
	@Test
	internal func webstoreInstallsReachTheAppForOwnedProfilesOnly() async throws {
		let running = CapabilityFlag(true)
		let requests = AsyncStream<BrowserWebstoreInstallRequest>.makeStream()
		var declined: [UUID] = []
		var prepared: [UUID] = []

		let capabilities = BrowserCapabilities(
			isRunning: { running.value },
			capture: .init(),
			media: { .init() },
			extensions: { _ in
				.init(
					isAvailable: true,
					installationAvailability: { true },
					webstoreAvailability: { true },
					webstoreInstallRequests: { requests.stream },
					prepareWebstoreInstallation: { request, _ in
						prepared.append(request.id)
						throw BrowserExtensionsClient.Failure.busy
					},
					declineWebstoreInstallation: { declined.append($0.id) }
				)
			}
		)
		let store = store(capabilities)
		let owned = try #require(store.workspace.profiles.first?.id)
		let unowned = Profile.ID(rawValue: UUID(93))

		#expect(!capabilities.extensions.isWebstoreAvailable)
		capabilities.activate()
		#expect(capabilities.extensions.isWebstoreAvailable)

		await store.send(.settings(.configureExtensions(Array(store.workspace.profiles)))).finish()
		#expect(store.settings.extensions.isWebstoreAvailable)

		let foreign = BrowserWebstoreInstallRequest(id: UUID(94), profileID: unowned, extensionID: "foreign")
		let local = BrowserWebstoreInstallRequest(id: UUID(95), profileID: owned, extensionID: "local")
		var iterator = capabilities.extensions.webstoreInstallRequests().makeAsyncIterator()
		requests.continuation.yield(foreign)
		requests.continuation.yield(local)
		#expect(await iterator.next() == local)
		#expect(declined == [foreign.id])

		let inventory = BrowserExtensionInventory(id: UUID(96), profileID: owned, revision: 1, extensions: [])
		await #expect(throws: BrowserExtensionsClient.Failure.busy) {
			try await capabilities.extensions.prepareWebstoreInstallation(local, inventory)
		}
		#expect(prepared == [local.id])

		await #expect(throws: BrowserExtensionsClient.Failure.missingProfile) {
			try await capabilities.extensions.prepareWebstoreInstallation(foreign, inventory)
		}
		#expect(prepared == [local.id])
		#expect(declined == [foreign.id, foreign.id])

		capabilities.extensions.declineWebstoreInstallation(local)
		#expect(declined == [foreign.id, foreign.id, local.id])

		running.value = false
		#expect(!capabilities.extensions.isWebstoreAvailable)
		requests.continuation.finish()
	}

	/// DEV-776: store updates go through the app's client too, for owned profiles only, so
	/// Check for Updates shows and the periodic check reaches native code.
	@Test
	internal func webstoreUpdatesReachTheAppForOwnedProfilesOnly() async throws {
		let running = CapabilityFlag(true)
		var prepared: [String] = []
		var cancelled: [UUID] = []

		let capabilities = BrowserCapabilities(
			isRunning: { running.value },
			capture: .init(),
			media: { .init() },
			extensions: { _ in
				.init(
					isAvailable: true,
					installationAvailability: { true },
					cancelInstallation: { cancelled.append($0.id) },
					webstoreUpdateAvailability: { true },
					prepareWebstoreUpdate: { request in
						prepared.append(request.extensionID)
						throw BrowserExtensionsClient.Failure.upToDate
					}
				)
			}
		)
		let store = store(capabilities)
		let owned = try #require(store.workspace.profiles.first?.id)
		let unowned = Profile.ID(rawValue: UUID(93))

		#expect(!capabilities.extensions.isWebstoreUpdateAvailable)
		capabilities.activate()
		#expect(capabilities.extensions.isWebstoreUpdateAvailable)

		await store.send(.settings(.configureExtensions(Array(store.workspace.profiles)))).finish()
		#expect(store.settings.extensions.isWebstoreUpdateAvailable)

		let local = BrowserExtensionInventory(id: UUID(96), profileID: owned, revision: 1, extensions: [])
		await #expect(throws: BrowserExtensionsClient.Failure.upToDate) {
			try await capabilities.extensions.prepareWebstoreUpdate(.init(inventory: local, extensionID: "local"))
		}
		let foreign = BrowserExtensionInventory(id: UUID(97), profileID: unowned, revision: 1, extensions: [])
		await #expect(throws: BrowserExtensionsClient.Failure.missingProfile) {
			try await capabilities.extensions.prepareWebstoreUpdate(.init(inventory: foreign, extensionID: "foreign"))
		}
		#expect(prepared == ["local"])
		#expect(cancelled.isEmpty)

		running.value = false
		#expect(!capabilities.extensions.isWebstoreUpdateAvailable)
		await #expect(throws: BrowserExtensionsClient.Failure.unavailable) {
			try await capabilities.extensions.prepareWebstoreUpdate(.init(inventory: local, extensionID: "local"))
		}
		#expect(prepared == ["local"])
	}

	@Test
	internal func mediaWithholdsPrivateAndUnknownSourcesAndRechecksAfterAwait() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[0]
		let ordinary = BrowserMediaSource(
			id: .init(tabID: tab.id, profileID: tab.profileID, generation: 1),
			revision: 1,
			title: "Ordinary",
			site: nil,
			playback: .playing,
			actions: [.pause]
		)

		var privateSource = ordinary
		privateSource.id.tabID = .init(rawValue: UUID(93))
		privateSource.isPrivate = true

		var unknown = ordinary
		unknown.id.profileID = .init(rawValue: UUID(94))
		unknown.id.tabID = .init(rawValue: UUID(95))

		let snapshots = AsyncStream<BrowserMediaSnapshot>.makeStream()
		let activations = AsyncStream<BrowserMediaSource.ID>.makeStream()
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		let running = CapabilityFlag(true)
		var calls = 0

		let capabilities = BrowserCapabilities(
			isRunning: { running.value },
			capture: .init(),
			media: {
				.init(
					isAvailable: true,
					events: { snapshots.stream },
					activations: { activations.stream },
					isSourceCurrent: { _ in true },
					perform: { _ in
						calls += 1
						started.continuation.yield(())
						for await _ in release.stream { break }
					}
				)
			},
			extensions: { _ in .init() }
		)
		let store = store(capabilities, organization: organization)

		defer {
			capabilities.stop()
			_ = store
		}

		capabilities.activate()
		var events = capabilities.media.events().makeAsyncIterator()
		snapshots.continuation.yield(.init(revision: 1, sources: [ordinary, privateSource, unknown]))
		let snapshot = await events.next()
		expectNoDifference(snapshot?.sources, [ordinary])

		var activation = capabilities.media.activations().makeAsyncIterator()
		activations.continuation.yield(unknown.id)
		activations.continuation.yield(ordinary.id)
		let activated = await activation.next()
		expectNoDifference(activated, ordinary.id)

		#expect(!capabilities.media.isSourceCurrent(unknown.id))
		await #expect(throws: BrowserMediaClient.Failure.staleSource) {
			try await capabilities.media.perform(.init(source: unknown, action: .pause))
		}

		let task = Task {
			try await capabilities.media.perform(.init(source: ordinary, action: .pause))
		}
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)

		running.value = false
		release.continuation.finish()

		await #expect(throws: BrowserMediaClient.Failure.unavailable) {
			try await task.value
		}
		#expect(calls == 1)
	}

	@Test
	internal func explicitCaptureRetainsHostAuthorizationAcrossNativeAwait() async throws {
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		var authorized = true

		let capabilities = BrowserCapabilities(
			isRunning: { true },
			capture: .init(
				isAvailable: { true },
				captureAuthorized: { request, authorize in
					guard authorize() else {
						throw PageCaptureFailure.staleDocument
					}

					started.continuation.yield(())
					for await _ in release.stream { break }

					guard authorize() else {
						throw PageCaptureFailure.staleDocument
					}

					return .init(
						request: request,
						documentID: "fixture",
						image: .init(png: Data([1]), width: 1, height: 1),
						viewportWidth: 1,
						viewportHeight: 1,
						deviceScale: 1,
						wasLoading: false
					)
				}
			),
			media: { .init() },
			extensions: { _ in .init() }
		)
		let store = store(capabilities)
		defer { _ = store }

		capabilities.activate()
		let request = PageCaptureRequest(tabID: .init(rawValue: UUID(96)), revision: 7)
		let task = Task {
			try await capabilities.capture.captureAuthorized(request, { authorized })
		}
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)

		authorized = false
		release.continuation.finish()

		await #expect(throws: PageCaptureFailure.staleDocument) {
			try await task.value
		}
	}

	/// DEV-634: hover previews capture hidden tabs offscreen, so the capability has to reach the app.
	@Test
	internal func offscreenCaptureAvailabilityFollowsTheNativeClientAndReadiness() async throws {
		var offscreen = true
		let capabilities = BrowserCapabilities(
			isRunning: { true },
			capture: .init(
				isAvailable: { true },
				offscreenIsAvailable: { offscreen }
			),
			media: { .init() },
			extensions: { _ in .init() }
		)
		let store = store(capabilities)
		defer { _ = store }

		#expect(!capabilities.capture.offscreenIsAvailable())
		capabilities.activate()
		#expect(capabilities.capture.offscreenIsAvailable())
		offscreen = false
		#expect(!capabilities.capture.offscreenIsAvailable())
	}

	@Test
	internal func retainedInteractionDependencyTracksReadinessOwnershipAndShutdown() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[0]
		let running = CapabilityFlag(false)
		var calls = 0
		let capabilities = BrowserCapabilities(
			isRunning: { running.value },
			capture: .init(),
			media: { .init() },
			extensions: { _ in .init() },
			interaction: .init(
				isAvailable: { true },
				clickAuthorized: { request, _, authorize in
					guard authorize() else {
						return .init(operationID: request.operationID, disposition: .notDispatched, failure: .denied)
					}
					calls += 1
					return .init(operationID: request.operationID, disposition: .dispatched)
				}
			)
		)
		let store = store(capabilities, organization: organization)
		defer { _ = store }
		let retained = capabilities.interaction
		let request = AutomationClickRequest(
			operationID: UUID(),
			targetID: tab.id.rawValue,
			expectedRevision: String(repeating: "a", count: 64),
			snapshotID: "snapshot",
			reference: "opaque"
		)
		var inspection = AutomationInspectionResult(
			request: .init(targetID: tab.id.rawValue, expectedRevision: request.expectedRevision),
			source: .init(tabID: tab.id, profileID: tab.profileID, sessionRevision: 3, documentRevision: 8, scopeID: UUID()),
			snapshot: .init(
				snapshotID: "snapshot",
				documentID: "document",
				frameID: "frame",
				domVersion: "4",
				nodes: [.init(index: 0, role: "button", reference: "opaque")],
				omissions: PageInspectionOmission.allCases
			)
		)
		expectNoDifference(retained.isAvailable(), false)
		let early = await retained.clickAuthorized(request, inspection) { true }
		expectNoDifference(early.disposition, .notDispatched)
		expectNoDifference(calls, 0)

		running.value = true
		capabilities.activate()
		expectNoDifference(retained.isAvailable(), true)
		let ready = await retained.clickAuthorized(request, inspection) { true }
		expectNoDifference(ready.disposition, .dispatched)
		expectNoDifference(calls, 1)

		inspection.source.profileID = .init(rawValue: UUID())
		let foreign = await retained.clickAuthorized(request, inspection) { true }
		expectNoDifference(foreign.failure, .denied)
		expectNoDifference(calls, 1)
		capabilities.stop()
		expectNoDifference(retained.isAvailable(), false)
		let stopped = await retained.clickAuthorized(request, inspection) { true }
		expectNoDifference(stopped.disposition, .notDispatched)
		expectNoDifference(calls, 1)
	}

	@Test
	internal func captureInspectionReadsOnlyTheLiveSessionsExactSource() async throws {
		let organization = IntegrationFeatureTests().fixture()

		// A Little Arx or temporary Peek page: its tab isn't saved in the workspace.
		let tabID = BrowserCore.Tab.ID(rawValue: UUID(700))
		let profileID = organization.tabs[0].profileID
		let source = PageInspectionSource(
			tabID: tabID,
			profileID: profileID,
			sessionRevision: 3,
			documentRevision: 8,
			scopeID: UUID(701)
		)
		var reads = 0
		let capabilities = BrowserCapabilities(
			isRunning: { true },
			capture: .init(),
			media: { .init() },
			extensions: { _ in .init() },
			inspection: .init(
				isAvailable: { true },
				inspectAuthorized: { _, _, authorize in
					guard authorize() else { throw AutomationFailure.denied }
					reads += 1
					return .init(snapshotID: "s", documentID: "d", frameID: "f", domVersion: "1", nodes: [], omissions: [])
				}
			)
		)
		let empty = store(capabilities, organization: organization)
		capabilities.activate()
		let request = AutomationInspectionRequest(
			targetID: tabID.rawValue,
			expectedRevision: String(repeating: "0", count: 64),
			includesBounds: true
		)

		await #expect(throws: AutomationFailure.denied) {
			_ = try await capabilities.captureInspection.inspectAuthorized(request, source) { true }
		}
		await #expect(throws: AutomationFailure.denied) {
			_ = try await capabilities.inspection.inspectAuthorized(request, source) { true }
		}

		let session = PageCaptureFeature.State(
			id: UUID(702),
			source: .init(host: .little(UUID(703)), tabID: tabID, profileID: profileID, spaceID: organization.spaces[0].id),
			title: "Little",
			mode: .area,
			sourceGeneration: 0,
			phase: .selecting,
			inspection: source
		)
		var state = empty.state
		state.captureSessions = [session]
		let capturing = Store(initialState: state) { EmptyReducer<AppFeature.State, AppFeature.Action>() }
		capabilities.store = capturing
		_ = try await capabilities.captureInspection.inspectAuthorized(request, source) { true }
		expectNoDifference(reads, 1)

		var other = source
		other.scopeID = UUID(704)
		await #expect(throws: AutomationFailure.denied) {
			_ = try await capabilities.captureInspection.inspectAuthorized(request, other) { true }
		}
		await #expect(throws: AutomationFailure.denied) {
			_ = try await capabilities.inspection.inspectAuthorized(request, source) { true }
		}
		expectNoDifference(reads, 1)
		_ = empty
	}

	@Test
	internal func retainedFormDependencyTracksReadinessOwnershipAndShutdown() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[0]
		let running = CapabilityFlag(false)
		var calls = 0
		let capabilities = BrowserCapabilities(
			isRunning: { running.value },
			capture: .init(),
			media: { .init() },
			extensions: { _ in .init() },
			interaction: .init(
				formIsAvailable: { true },
				formAuthorized: { request, _, authorize in
					guard authorize() else {
						return .init(operationID: request.operationID, disposition: .notDispatched, failure: .denied)
					}
					calls += 1
					return .init(operationID: request.operationID, disposition: .unchanged)
				}
			)
		)
		let store = store(capabilities, organization: organization)
		defer { _ = store }
		let retained = capabilities.interaction
		let target = AutomationClickRequest(
			operationID: UUID(),
			targetID: tab.id.rawValue,
			expectedRevision: String(repeating: "a", count: 64),
			snapshotID: "snapshot",
			reference: "opaque"
		)
		let request = AutomationFormRequest(target: target, kind: .replaceText, value: "fixture")
		var inspection = AutomationInspectionResult(
			request: .init(targetID: tab.id.rawValue, expectedRevision: target.expectedRevision),
			source: .init(tabID: tab.id, profileID: tab.profileID, sessionRevision: 3, documentRevision: 8, scopeID: UUID()),
			snapshot: .init(
				snapshotID: "snapshot",
				documentID: "document",
				frameID: "frame",
				domVersion: "4",
				nodes: [.init(index: 0, role: "button", reference: "opaque")],
				omissions: PageInspectionOmission.allCases
			)
		)
		expectNoDifference(retained.formIsAvailable(), false)
		let early = await retained.formAuthorized(request, inspection) { true }
		expectNoDifference(early.disposition, .notDispatched)
		expectNoDifference(calls, 0)

		running.value = true
		capabilities.activate()
		expectNoDifference(retained.formIsAvailable(), true)
		let ready = await retained.formAuthorized(request, inspection) { true }
		expectNoDifference(ready.disposition, .unchanged)
		expectNoDifference(calls, 1)

		inspection.source.profileID = .init(rawValue: UUID())
		let foreign = await retained.formAuthorized(request, inspection) { true }
		expectNoDifference(foreign.failure, .denied)
		expectNoDifference(calls, 1)
		capabilities.stop()
		expectNoDifference(retained.formIsAvailable(), false)
		let stopped = await retained.formAuthorized(request, inspection) { true }
		expectNoDifference(stopped.disposition, .notDispatched)
		expectNoDifference(calls, 1)
	}

	@Test
	internal func retainedScrollDependencyTracksReadinessOwnershipAndShutdown() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let tab = organization.tabs[0]
		let running = CapabilityFlag(false)
		var calls = 0
		let capabilities = BrowserCapabilities(
			isRunning: { running.value },
			capture: .init(),
			media: { .init() },
			extensions: { _ in .init() },
			interaction: .init(
				scrollIsAvailable: { true },
				scrollAuthorized: { request, _, authorize in
					guard authorize() else {
						return .init(operationID: request.operationID, disposition: .notDispatched, failure: .denied)
					}
					calls += 1
					return .init(operationID: request.operationID, disposition: .unchanged)
				}
			)
		)
		let store = store(capabilities, organization: organization)
		defer { _ = store }
		let retained = capabilities.interaction
		let target = AutomationClickRequest(
			operationID: UUID(),
			targetID: tab.id.rawValue,
			expectedRevision: String(repeating: "a", count: 64),
			snapshotID: "snapshot",
			reference: "opaque"
		)
		let request = AutomationScrollRequest(target: target, axis: .vertical, deltaCSSPixels: 120)
		var inspection = AutomationInspectionResult(
			request: .init(targetID: tab.id.rawValue, expectedRevision: target.expectedRevision),
			source: .init(tabID: tab.id, profileID: tab.profileID, sessionRevision: 3, documentRevision: 8, scopeID: UUID()),
			snapshot: .init(
				snapshotID: "snapshot",
				documentID: "document",
				frameID: "frame",
				domVersion: "4",
				nodes: [.init(index: 0, role: "button", reference: "opaque")],
				omissions: PageInspectionOmission.allCases
			)
		)
		expectNoDifference(retained.scrollIsAvailable(), false)
		let early = await retained.scrollAuthorized(request, inspection) { true }
		expectNoDifference(early.disposition, .notDispatched)
		expectNoDifference(calls, 0)

		running.value = true
		capabilities.activate()
		expectNoDifference(retained.scrollIsAvailable(), true)
		let ready = await retained.scrollAuthorized(request, inspection) { true }
		expectNoDifference(ready.disposition, .unchanged)
		expectNoDifference(calls, 1)

		inspection.source.profileID = .init(rawValue: UUID())
		let foreign = await retained.scrollAuthorized(request, inspection) { true }
		expectNoDifference(foreign.failure, .denied)
		expectNoDifference(calls, 1)
		capabilities.stop()
		expectNoDifference(retained.scrollIsAvailable(), false)
		let stopped = await retained.scrollAuthorized(request, inspection) { true }
		expectNoDifference(stopped.disposition, .notDispatched)
		expectNoDifference(calls, 1)
	}

	@Test
	internal func deletedInstallOwnerCancelsVerifiedPromptBeforePublication() async throws {
		let profile = Profile.ID(rawValue: UUID(91))
		let inventory = BrowserExtensionInventory(id: UUID(92), profileID: profile, revision: 1, extensions: [])
		let prompt = BrowserExtensionInstallPrompt(
			id: UUID(93),
			profileID: profile,
			inventoryID: inventory.id,
			revision: 1,
			candidate: .init(
				extensionID: String(repeating: "a", count: 32),
				name: "Verified fixture",
				version: "1",
				packageSHA256: String(repeating: "a", count: 64),
				sourceBasename: "Selected.crx",
				isUpdate: false,
				requiredPermissions: .init(apis: [], hosts: []),
				optionalPermissions: .init(apis: [], hosts: []),
				warnings: []
			)
		)
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		var cancelled: [BrowserExtensionInstallPrompt] = []
		var prepares = 0
		let capabilities = BrowserCapabilities(
			isRunning: { true },
			capture: .init(),
			media: { .init() },
			extensions: { _ in
				.init(
					isAvailable: true,
					installationAvailability: { true },
					prepareInstallation: { _ in
						prepares += 1
						started.continuation.yield(())
						for await _ in release.stream { break }
						return prompt
					},
					cancelInstallation: { cancelled.append($0) }
				)
			}
		)
		var organization = IntegrationFeatureTests().fixture()
		organization.profiles.append(.init(id: profile, name: "Removed"))
		let store = store(capabilities, organization: organization)
		capabilities.activate()
		let retained = capabilities.extensions
		#expect(retained.isInstallationAvailable)
		let request = BrowserExtensionInstallRequest(inventory: inventory, selectedFile: URL(filePath: "/tmp/Selected.crx"))
		let task = Task { try await retained.prepareInstallation(request) }
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)
		await store.send(.settings(.delegate(.changeOrganization(.removeProfile(profile))))).finish()
		release.continuation.finish()
		await #expect(throws: BrowserExtensionsClient.Failure.missingProfile) { try await task.value }
		#expect(cancelled == [prompt] && prepares == 1)
		await #expect(throws: BrowserExtensionsClient.Failure.missingProfile) {
			try await retained.prepareInstallation(request)
		}
		await #expect(throws: BrowserExtensionsClient.Failure.missingProfile) {
			try await retained.resolveInstallation(prompt, true)
		}
		#expect(cancelled == [prompt, prompt] && prepares == 1)
		capabilities.stop()
		#expect(!retained.isInstallationAvailable)
	}

	@Test(arguments: [false, true])
	internal func extensionOptionsForwardThroughTheAppAndRecheckOwnership(loseProfile: Bool) async throws {
		let running = CapabilityFlag(true)
		let profile = Profile.ID(rawValue: UUID())
		let inventory = BrowserExtensionInventory(id: UUID(), profileID: profile, revision: 1, extensions: [])
		let request = BrowserExtensionViewRequest(inventory: inventory, extensionID: String(repeating: "a", count: 32))
		var opens = 0
		var owner: StoreOf<AppFeature>?
		let capabilities = BrowserCapabilities(
			isRunning: { running.value },
			capture: .init(),
			media: { .init() },
			extensions: { _ in
				.init(
					isAvailable: true,
					optionsAvailability: { true },
					openOptions: { received in
						#expect(received == request)
						opens += 1
						if loseProfile {
							await owner?.send(.settings(.delegate(.changeOrganization(.removeProfile(profile))))).finish()
						}
						return inventory
					}
				)
			}
		)
		let retained = capabilities.extensions
		#expect(!retained.optionsAvailability())
		var organization = IntegrationFeatureTests().fixture()
		organization.profiles.append(.init(id: profile, name: "Options owner"))
		owner = store(capabilities, organization: organization)
		capabilities.activate()
		#expect(retained.optionsAvailability())

		if loseProfile {
			await #expect(throws: BrowserExtensionsClient.Failure.missingProfile) {
				try await retained.openOptions(request)
			}
		} else {
			let result = try await retained.openOptions(request)
			expectNoDifference(result, inventory)
		}
		#expect(opens == 1)

		running.value = false
		#expect(!retained.optionsAvailability())
		await #expect(throws: BrowserExtensionsClient.Failure.unavailable) {
			try await retained.openOptions(request)
		}
		#expect(opens == 1)
		capabilities.stop()
	}

	@Test
	internal func extensionIconsForwardThroughTheAppWhileExtensionsRun() async throws {
		let running = CapabilityFlag(true)
		let icon = Data("png".utf8)
		let reads = LockIsolated<[String]>([])
		let capabilities = BrowserCapabilities(
			isRunning: { running.value },
			capture: .init(),
			media: { .init() },
			extensions: { _ in
				.init(
					isAvailable: true,
					icon: { path in
						reads.withValue { $0.append(path) }
						return icon
					}
				)
			}
		)
		let retained = capabilities.extensions
		#expect(await retained.icon("/x/icon.png") == nil)

		// The capabilities hold their store weakly; it has to outlive the reads.
		let owner = store(capabilities)
		capabilities.activate()
		#expect(await retained.icon("/x/icon.png") == icon)

		running.value = false
		#expect(await retained.icon("/x/icon.png") == nil)
		expectNoDifference(reads.value, ["/x/icon.png"])
		capabilities.stop()
		withExtendedLifetime(owner) {}
	}

	@Test(arguments: [false, true])
	internal func unpackedLoadingForwardsThroughTheAppAndRechecksOwnership(loseProfile: Bool) async throws {
		let running = CapabilityFlag(true)
		let profile = Profile.ID(rawValue: UUID())
		let inventory = BrowserExtensionInventory(id: UUID(), profileID: profile, revision: 1, extensions: [])
		let request = BrowserExtensionUnpackedRequest(inventory: inventory, directory: URL(fileURLWithPath: "/tmp/unpacked"))
		var loads = 0
		var owner: StoreOf<AppFeature>?
		let capabilities = BrowserCapabilities(
			isRunning: { running.value },
			capture: .init(),
			media: { .init() },
			extensions: { _ in
				.init(
					isAvailable: true,
					unpackedAvailability: { true },
					loadUnpacked: { received in
						#expect(received == request)
						loads += 1
						if loseProfile {
							await owner?.send(.settings(.delegate(.changeOrganization(.removeProfile(profile))))).finish()
						}
						return inventory
					}
				)
			}
		)
		let retained = capabilities.extensions
		#expect(!retained.isUnpackedAvailable)
		var organization = IntegrationFeatureTests().fixture()
		organization.profiles.append(.init(id: profile, name: "Unpacked owner"))
		owner = store(capabilities, organization: organization)
		capabilities.activate()
		#expect(retained.isUnpackedAvailable)

		if loseProfile {
			await #expect(throws: BrowserExtensionsClient.Failure.missingProfile) {
				try await retained.loadUnpacked(request)
			}
		} else {
			let result = try await retained.loadUnpacked(request)
			expectNoDifference(result, inventory)
		}
		#expect(loads == 1)

		running.value = false
		#expect(!retained.isUnpackedAvailable)
		await #expect(throws: BrowserExtensionsClient.Failure.unavailable) {
			try await retained.loadUnpacked(request)
		}
		#expect(loads == 1)
		capabilities.stop()
	}

	private func store(
		_ capabilities: BrowserCapabilities,
		organization: BrowserOrganization? = nil,
		observeSnapshot: @escaping @Sendable (BrowserMediaSnapshot) -> Void = { _ in },
		configure: @escaping (inout DependencyValues) -> Void = { _ in }
	) -> StoreOf<AppFeature> {
		let organization = organization ?? IntegrationFeatureTests().fixture()
		let state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id)
		)

		let store = Store(initialState: state) {
			AppFeature()

			Pullback(\AppFeature.Action.Cases.media.event.changed) { _, value in
				observeSnapshot(value.0)
				return .none
			}
		} withDependencies: {
			$0.browserCapture = capabilities.capture
			$0.browserMedia = capabilities.media
			$0.browserExtensions = capabilities.extensions
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
			configure(&$0)
		}

		capabilities.store = store
		return store
	}
}

@MainActor
private final class CapabilityFlag {
	internal var value: Bool

	internal init(_ value: Bool) {
		self.value = value
	}
}
