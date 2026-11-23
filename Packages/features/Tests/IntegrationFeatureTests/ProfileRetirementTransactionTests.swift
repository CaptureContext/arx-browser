import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct ProfileRetirementTransactionTests {
	/// The link menus' and Share's actions left the ui domain (DEV-854) but stay blocked while a
	/// profile retires, as the clicks behind them were.
	@Test
	internal func linkAndShareActionsWaitForRetirement() {
		let url = URL(string: "https://capturecontext.dev")!
		let space = Space.ID(rawValue: UUID(91))
		let profile = Profile.ID(rawValue: UUID(90))
		let actions: [AppFeature.Action] = [
			.sharePage(.init(title: "Capture Context", url: url), sourceWindowID: UUID(92)),
			.openInNewWindow(url, space),
			.openInMainWindow(url, space),
			.openInPrivateWindow(url, opener: profile),
			.downloadURL(url, profile),
			.downloadLink(.init(
				token: 1,
				tabID: .init(rawValue: UUID(93)),
				profileID: profile,
				sessionRevision: 1,
				documentRevision: 1,
				isPrivate: false,
				item: .init(title: "", url: url),
				x: 0,
				y: 0
			)),
		]
		for action in actions {
			#expect(!action.permittedDuringRetirement)
		}
	}

	@Test
	internal func liveAuthorizationPreservesUnrelatedCompletionButRejectsTargetOwnershipChange() {
		let fixture = RetirementTransactionFixture()
		let operation = UUID(90)
		var state = AppFeature.State(main: .init(organization: fixture.organization, spaceID: fixture.space))
		state.profileRetirement.isBusy = true
		state.profileRetirement.operationID = operation
		state.profileRetirement.profileID = fixture.target
		state.profileRetirement.original = fixture.organization
		expectNoDifference(state.authorizesRetirement(operation), true)
		state.workspace.tabs[0].restoration.title = "Ordinary completion"
		expectNoDifference(state.authorizesRetirement(operation), true)
		state.workspace.spaces[0] = .init(id: fixture.space, profileID: fixture.target, name: "Reassigned")
		expectNoDifference(state.authorizesRetirement(operation), false)
		state.workspace = fixture.organization
		state.workspace.legacyProfileID = fixture.survivor
		expectNoDifference(state.authorizesRetirement(operation), false)
		state.workspace = fixture.organization
		state.checkingQuit = true
		expectNoDifference(state.authorizesRetirement(operation), false)
	}

	/// DEV-889. A private window runs in the private context of the profile it was opened from,
	/// so that profile can't retire while the window is open.
	@Test
	internal func aProfileWithAnOpenPrivateWindowDoesNotRetire() async throws {
		let fixture = RetirementTransactionFixture()
		let store = fixture.store(privateWindowOpeners: [.init(rawValue: UUID(50)): fixture.target])
		await store.send(.profileRetirement(.begin(fixture.target)))
		await store.receive(\.settings.event.organizationChangeFailed)
		expectNoDifference(fixture.events, [])
		#expect(!store.state.profileRetirement.isBusy)
	}

	@Test
	internal func defaultRemovalRetainsWebsiteDataAndEraseRequiresExactName() async throws {
		let fixture = RetirementTransactionFixture()
		let store = fixture.store()
		await store.send(.settings(.ui(.editOrganization(.init(
			kind: .removeProfile(fixture.target),
			name: "Default",
			eraseWebsiteData: true
		)))))
		await store.send(.settings(.ui(.submitOrganizationEditor)))
		expectNoDifference(fixture.events, [])
		expectNoDifference(store.state.workspace, fixture.organization)
		await store.send(
			.settings(.ui(.organizationEditorChanged(.init(kind: .removeProfile(fixture.target), name: "Default"))))
		)
		await store.send(.settings(.ui(.submitOrganizationEditor)))
		await store.receive(\.delegate.save)
		await store.finish()
		expectNoDifference(fixture.events.contains("queue"), false)
		expectNoDifference(store.state.workspace.retiredProfileIDs, [])
		expectNoDifference(store.state.workspace.profiles.ids.contains(fixture.target), false)
	}

	@Test
	internal func consentIsDurableBeforeActualCloseAndQueueAndMetadataWaitsForAck() async throws {
		let fixture = RetirementTransactionFixture()
		fixture.holdClose = true
		let store = fixture.store()
		await store.send(.profileRetirement(.begin(fixture.target)))
		await store.receive(\.profileRetirement.prepared)
		try await fixture.waitForClose()
		expectNoDifference(fixture.events, ["prepare", "inspect", "block", "persist", "close"])
		expectNoDifference(store.state.workspace, fixture.organization)
		await store.send(
			.settings(.ui(.changeOrganization(.renameProfile(fixture.survivor, name: "Concurrent"))))
		)
		expectNoDifference(store.state.workspace, fixture.organization)
		fixture.completeClose(true)
		await store.receive(\.profileRetirement.finished)
		await store.receive(\.delegate.save)
		await store.finish()
		expectNoDifference(fixture.events, ["prepare", "inspect", "block", "persist", "close", "queue", "ack"])
		expectNoDifference(store.state.workspace.retiredProfileIDs, [fixture.target])
		expectNoDifference(store.state.workspace.legacyProfileID, fixture.target)
		expectNoDifference(store.state.profileRetirement.intents.first?.acknowledged, true)
		expectNoDifference(store.state.profileRetirement.snapshot?.records.first?.state, .awaitingStartup)
	}

	@Test(arguments: [true, false])
	internal func failedIntentWriteOrRefusedCloseNeverQueuesAndKeepsMetadata(writeFails: Bool) async throws {
		let fixture = RetirementTransactionFixture()
		fixture.failWrite = writeFails
		fixture.closeAllowed = writeFails
		let store = fixture.store()
		await store.send(.profileRetirement(.begin(fixture.target)))
		await store.receive(\.profileRetirement.prepared)
		await store.receive(\.profileRetirement.failed)
		await store.finish()
		expectNoDifference(fixture.events.contains("queue"), false)
		expectNoDifference(fixture.events.contains("ack"), false)
		expectNoDifference(store.state.workspace, fixture.organization)
		expectNoDifference(store.state.profileRetirement.intents.count, 1)
		expectNoDifference(store.state.profileRetirement.isBusy, false)
	}

	@Test
	internal func uncertainQueueRetriesWithFreshRevisionAndOriginalConsent() async throws {
		let fixture = RetirementTransactionFixture()
		fixture.failQueue = true
		let store = fixture.store()
		await store.send(.profileRetirement(.begin(fixture.target)))
		await store.receive(\.profileRetirement.prepared)
		await store.receive(\.profileRetirement.failed)
		await store.finish()
		let original = try #require(store.state.profileRetirement.intents.first)
		expectNoDifference(store.state.workspace, fixture.organization)
		fixture.failQueue = false
		fixture.revision = 20
		await store.send(.settings(.ui(.retryProfileRetirement(fixture.target))))
		await store.receive(\.profileRetirement.prepared)
		await store.receive(\.profileRetirement.finished)
		await store.receive(\.delegate.save)
		await store.finish()
		let retry = try #require(fixture.persisted.last)
		expectNoDifference(retry.requestID, original.requestID)
		expectNoDifference(retry.expectedRevision, 12)
		expectNoDifference(retry.attemptRevision, 20)
		expectNoDifference(store.state.workspace.retiredProfileIDs, [fixture.target])
	}

	@Test
	internal func foreignErasedReceiptCannotRemoveMetadataOrClaimConfirmedErasure() async throws {
		let fixture = RetirementTransactionFixture()
		let intent = ProfileRetirementIntent(
			profileID: fixture.target,
			profileName: "Default",
			requestID: UUID(50),
			expectedRevision: 12
		)
		fixture.nativeRequest = UUID(51)
		fixture.nativeState = .erased
		fixture.revision = 13
		let store = fixture.store(intents: [intent])
		await store.send(.profileRetirement(.refresh))
		await store.receive(\.profileRetirement.refreshed)
		await store.finish()
		expectNoDifference(fixture.events, ["inspect"])
		expectNoDifference(store.state.workspace, fixture.organization)
		expectNoDifference(store.state.profileRetirement.intents[0].acknowledged, false)
		#expect(!store.state.settings.profileRetirements[0].message.contains("confirmed"))
	}

	@Test
	internal func restartReconcilesNativeRetirementAndReportsRestartBeforeErased() async throws {
		let fixture = RetirementTransactionFixture()
		let intent = ProfileRetirementIntent(
			profileID: fixture.target,
			profileName: "Default",
			requestID: UUID(50),
			expectedRevision: 12
		)
		fixture.nativeRequest = intent.requestID
		fixture.nativeState = .restartRequired
		let store = fixture.store(intents: [intent])
		await store.send(.profileRetirement(.refresh))
		await store.receive(\.profileRetirement.refreshed)
		await store.receive(\.delegate.save)
		await store.finish()
		expectNoDifference(fixture.events, ["inspect", "ack"])
		expectNoDifference(store.state.workspace.retiredProfileIDs, [fixture.target])
		expectNoDifference(store.state.profileRetirement.snapshot?.records.first?.state, .restartRequired)
		#expect(!store.state.settings.profileRetirements[0].message.contains("confirmed"))
		fixture.nativeState = .erased
		await store.send(.profileRetirement(.refresh))
		await store.receive(\.profileRetirement.refreshed)
		await store.finish()
		expectNoDifference(store.state.profileRetirement.snapshot?.records.first?.state, .erased)
		#expect(store.state.settings.profileRetirements[0].message.contains("confirmed"))
	}

	@Test
	internal func ordinaryNativeOpenDownloadTerminalAndCleanupCompleteWhileRetirementWaits() async throws {
		let fixture = RetirementTransactionFixture()
		fixture.includeOrdinaryTab = true
		fixture.holdClose = true
		let store = fixture.store()
		await store.send(.main(.ui(.task)))
		await store.receive(\.main.viewer)
		try await fixture.waitForOpen()
		await store.send(.profileRetirement(.begin(fixture.target)))
		await store.receive(\.profileRetirement.prepared)
		try await fixture.waitForClose()
		fixture.completeOpen()
		await store.receive(\.main.viewer.panes)
		expectNoDifference(store.state.main.viewer.item.navigation.title, "Opened")
		expectNoDifference(store.state.profileRetirement.isBusy, true)
		let terminal = BrowserDownload(
			id: .init(profileID: fixture.survivor, guid: "owned-terminal"),
			profileName: "Survivor",
			filename: "owned.txt",
			status: .complete,
			startedAt: Date(timeIntervalSince1970: 1)
		)
		await store.send(.downloads(.event(.queueChanged(.init(downloads: [terminal])))))
		expectNoDifference(store.state.downloads.queue.downloads.first?.status, .complete)
		await store.send(.event(.captureCapability(true)))
		expectNoDifference(store.state.captureAvailable, true)
		await store.send(.ui(.closeWindow))
		expectNoDifference(store.state.windowIsOpen, false)
		fixture.completeClose(true)
		await store.receive(\.profileRetirement.finished)
		await store.receive(\.delegate.save)
		await store.finish()
		expectNoDifference(store.state.workspace.retiredProfileIDs, [fixture.target])
	}

	@Test
	internal func shutdownFailureDuringQueuePreservesIntentAndMetadata() async throws {
		let fixture = RetirementTransactionFixture()
		fixture.holdQueue = true
		let store = fixture.store()
		await store.send(.profileRetirement(.begin(fixture.target)))
		await store.receive(\.profileRetirement.prepared)
		try await fixture.waitForQueue()
		expectNoDifference(store.state.profileRetirement.isBusy, true)
		fixture.stopForShutdown()
		await store.receive(\.profileRetirement.failed)
		await store.finish()
		expectNoDifference(store.state.profileRetirement.isBusy, false)
		expectNoDifference(store.state.workspace, fixture.organization)
		expectNoDifference(fixture.persisted.count, 1)
		expectNoDifference(fixture.events.contains("ack"), false)
	}
}

@MainActor
private final class RetirementTransactionFixture {
	internal let target: Profile.ID = .init(rawValue: UUID(40))
	internal let survivor: Profile.ID = .init(rawValue: UUID(41))
	internal let tab: BrowserCore.Tab.ID = .init(rawValue: UUID(42))
	internal let space: Space.ID = .init(rawValue: UUID(43))
	internal var events: [String] = []
	internal var persisted: [ProfileRetirementIntent] = []
	internal var failWrite: Bool = false
	internal var failQueue: Bool = false
	internal var closeAllowed: Bool = true
	internal var holdClose: Bool = false
	internal var closeContinuation: CheckedContinuation<Bool, Never>?
	internal var revision: UInt64 = 12
	internal var nativeState: ProfileRetirementRecord.State = .active
	internal var nativeRequest: UUID?
	internal var includeOrdinaryTab: Bool = false
	internal var openContinuation: CheckedContinuation<Void, Never>?
	internal var holdQueue: Bool = false
	internal var queueContinuation: CheckedContinuation<ProfileRetirementSnapshot, any Error>?
	private let ordinaryTab: BrowserCore.Tab.ID = .init(rawValue: UUID(44))

	internal init() {}

	internal var organization: BrowserOrganization {
		var organization = BrowserOrganization(
			profiles: [
				.init(id: target, name: "Default", favorites: [tab]),
				.init(id: survivor, name: "Survivor"),
			],
			legacyProfileID: target,
			spaces: [.init(id: space, profileID: survivor, name: "Work")],
			tabs: [
				.init(
					id: tab,
					profileID: target,
					savedDestination: .init(title: "Saved", url: URL(string: "https://capturecontext.dev")!),
					restoration: .init(title: "Saved", url: URL(string: "https://capturecontext.dev")!)
				)
			]
		)
		if includeOrdinaryTab {
			organization.tabs.append(
				.init(
					id: ordinaryTab,
					profileID: survivor,
					restoration: .init(title: "Ordinary", url: URL(string: "https://capturecontext.dev")!)
				)
			)
			organization.spaces[0].unpinnedTabs = [ordinaryTab]
			organization.spaces[0].selectedTabID = ordinaryTab
		}
		return organization
	}

	internal func store(
		intents: [ProfileRetirementIntent] = [],
		privateWindowOpeners: [Profile.ID: Profile.ID] = [:]
	) -> TestStoreOf<AppFeature> {
		var initial = AppFeature.State(
			main: .init(organization: organization, spaceID: space),
			retirementIntents: intents
		)
		initial.settings.retirementAvailable = true
		initial.privateProfileOpeners = privateWindowOpeners
		let store = TestStore(initialState: initial) {
			AppFeature()
		} withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.status = { .ready }
			$0.browserEngine.retirementIsAvailable = { true }
			$0.browserEngine.prepareProfile = { [self] _ in events.append("prepare") }
			$0.browserEngine.open = { [self] tab in
				if includeOrdinaryTab, tab.id == ordinaryTab {
					await withCheckedContinuation { openContinuation = $0 }
				}
			}
			$0.browserEngine.events = { [self] id in
				.init { continuation in
					if id == ordinaryTab { continuation.yield(.init(title: "Opened")) }
					continuation.finish()
				}
			}
			$0.browserEngine.blockProfileRetirement = { [self] _ in events.append("block") }
			$0.browserEngine.profileRetirementSnapshot = { [self] in
				events.append("inspect")
				return snapshot()
			}
			$0.browserEngine.snapshot = { _ in .init(navigation: .init(), revision: 3) }
			$0.browserEngine.close = { _ in }
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserEngine.closeAuthorized = { [self] _, _, authorize, didClose in
				events.append("close")
				guard authorize() else { throw ProfileRetirementFailure.stale }
				let allowed = holdClose
				? await withCheckedContinuation { closeContinuation = $0 }
				: closeAllowed
				if allowed { didClose() }
				return allowed
			}
			$0.browserEngine.retireProfile = { [self] request, authorize in
				events.append("queue")
				guard authorize(), !failQueue else { throw ProfileRetirementFailure.io }
				if holdQueue {
					return try await withCheckedThrowingContinuation { queueContinuation = $0 }
				}
				expectNoDifference(request.expectedRevision, revision)
				nativeRequest = request.requestID
				nativeState = .awaitingStartup
				revision += 1
				return snapshot()
			}
			$0.profileRetirementPersistence.record = { [self] intent in
				events.append("persist")
				if failWrite { throw ProfileRetirementFailure.io }
				persisted.append(intent)
			}
			$0.profileRetirementPersistence.acknowledge = { [self] _ in events.append("ack") }
			$0.profileRetirementPersistence.authorize = { _ in true }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}

	internal func waitForClose() async throws {
		for _ in 0..<1000 {
			if closeContinuation != nil { return }
			await Task.yield()
		}
		throw ProfileRetirementFailure.busy
	}

	internal func completeClose(_ allowed: Bool) {
		closeContinuation?.resume(returning: allowed)
		closeContinuation = nil
	}

	internal func waitForOpen() async throws {
		for _ in 0..<1000 {
			if openContinuation != nil { return }
			await Task.yield()
		}
		throw ProfileRetirementFailure.busy
	}

	internal func completeOpen() {
		openContinuation?.resume()
		openContinuation = nil
	}

	internal func waitForQueue() async throws {
		for _ in 0..<1000 {
			if queueContinuation != nil { return }
			await Task.yield()
		}
		throw ProfileRetirementFailure.busy
	}

	internal func stopForShutdown() {
		queueContinuation?.resume(throwing: ProfileRetirementFailure.unavailable)
		queueContinuation = nil
	}

	private func snapshot() -> ProfileRetirementSnapshot {
		.init(
			revision: nativeRequest == nil ? revision : max(revision, 13),
			isDurable: true,
			records: [
				.init(profileID: target, requestID: nativeRequest, state: nativeState),
				.init(profileID: survivor, requestID: nil, state: .active),
			]
		)
	}
}
