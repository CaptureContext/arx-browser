import BrowserCore
import BrowserDownloadsClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct AppDownloadsTests {
	/// DEV-966: quitting with a download running or paused (the native count includes paused ones)
	/// asks nothing with the warning off and cancels nothing; the engine leaves it interrupted, and
	/// next launch it can be resumed.
	@Test
	internal func aDownloadInProgressQuitsWithoutAPromptAndResumesNextTime() async throws {
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies { $0.workspaceDocument = document } operation: { fixture() }
		state.settings.$general.withLock { $0.warnsBeforeQuitting = false }
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserDownloads.activeCount = { 1 }
			$0.browserDownloads.unresumableCount = { 0 }
			$0.quitConfirmation.confirm = { _ in
				Issue.record("Asked before quitting with a resumable download")
				return .cancel
			}
			$0.browserDownloads.cancelAll = { Issue.record("Quitting cancelled the download") }
		}
		await store.send(.ui(.confirmQuit)).finish()
		for _ in 0..<1_000 where !store.shouldQuit { await Task.yield() }
		#expect(store.shouldQuit)

		// The next launch: the engine reports the transfer interrupted by the quit, resumable.
		let interrupted = BrowserDownload(
			id: .init(profileID: .init(rawValue: UUID(1)), guid: "archive-guid"),
			profileName: "Personal",
			url: URL(string: "https://files.example/archive.zip"),
			filename: "archive.zip",
			status: .interrupted,
			receivedBytes: 4_096,
			totalBytes: 8_192,
			startedAt: Date(timeIntervalSince1970: 100),
			interruptReason: 40,
			canResume: true
		)
		var resumed: [BrowserDownload.ID] = []
		var relaunch = fixture()
		relaunch.downloads.filter = .allProfiles
		let relaunched = Store(initialState: relaunch) { AppFeature() } withDependencies: {
			$0.browserDownloads.setPaused = { id, isPaused in
				#expect(!isPaused)
				resumed.append(id)
			}
		}
		await relaunched.send(.downloads(.event(.queueChanged(.init(downloads: [interrupted]))))).finish()
		#expect(relaunched.downloads.queue.downloads.first?.canResume == true)
		await relaunched.send(.downloads(.ui(.resume(interrupted.id)))).finish()
		expectNoDifference(resumed, [interrupted.id])
	}

	/// A download quitting would lose makes ⌘Q ask even with the warning off, saying so.
	@Test
	internal func aDownloadThatCantResumeAsksEvenWithTheWarningOff() async throws {
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies { $0.workspaceDocument = document } operation: { fixture() }
		state.settings.$general.withLock { $0.warnsBeforeQuitting = false }
		var asked: [QuitConfirmation.Downloads] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserDownloads.activeCount = { 2 }
			$0.browserDownloads.unresumableCount = { 1 }
			$0.quitConfirmation.confirm = {
				asked.append($0)
				return .cancel
			}
			$0.browserDownloads.cancelAll = { Issue.record("Quitting cancelled downloads") }
		}
		await store.send(.ui(.confirmQuit)).finish()
		expectNoDifference(asked, [.init(active: 2, unresumable: 1)])
		#expect(!store.shouldQuit && !store.checkingQuit)
	}

	/// With the warning on, the question says which downloads quitting stops, a paused one too.
	@Test
	internal func theQuestionSaysWhichDownloadsStop() async throws {
		var asked: [QuitConfirmation.Downloads] = []
		let store = Store(initialState: fixture()) { AppFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserDownloads.activeCount = { 1 }
			$0.browserDownloads.unresumableCount = { 0 }
			$0.quitConfirmation.confirm = {
				asked.append($0)
				return .cancel
			}
		}
		await store.send(.ui(.confirmQuit)).finish()
		expectNoDifference(asked, [.init(active: 1, unresumable: 0)])
	}

	/// A download quitting would lose that starts while pages agree to close makes a person's quit
	/// ask, with the warning off too; quitting goes on only if they say so (DEV-1130).
	@Test(arguments: [QuitConfirmation.Answer.cancel, .quit])
	internal func aLossThatStartsWhilePagesAgreeAsksAgain(answer: QuitConfirmation.Answer) async throws {
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies { $0.workspaceDocument = document } operation: { fixture() }
		state.settings.$general.withLock { $0.warnsBeforeQuitting = false }
		let losses = LockIsolated(0)
		var asked: [QuitConfirmation.Downloads] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.browserEngine.permitsClosing = { _ in

				// A private download starts while the pages are asked.
				losses.setValue(1)
				return true
			}
			$0.browserDownloads.activeCount = { losses.value }
			$0.browserDownloads.unresumableCount = { losses.value }
			$0.quitConfirmation.confirm = {
				asked.append($0)
				return answer
			}
		}
		await store.send(.ui(.confirmQuit)).finish()
		for _ in 0..<1_000 where asked.isEmpty || store.checkingQuit { await Task.yield() }
		expectNoDifference(asked, [.init(active: 1, unresumable: 1)])
		#expect(store.shouldQuit == (answer == .quit))
	}

	/// A loss that starts while that question is open is asked about too, and Don't Ask Again there
	/// turns the warning off, as it does the first time (DEV-1130).
	@Test
	internal func aLossDuringTheQuestionAsksAgainAndDontAskAgainSticks() async throws {
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies { $0.workspaceDocument = document } operation: { fixture() }
		let losses = LockIsolated(0)
		var asked: [Int] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.browserEngine.permitsClosing = { _ in
				losses.setValue(1)
				return true
			}
			$0.browserDownloads.activeCount = { losses.value }
			$0.browserDownloads.unresumableCount = { losses.value }
			$0.quitConfirmation.confirm = { downloads in
				asked.append(downloads.unresumable)
				switch asked.count {
				case 1: return .quit
				case 2:
					// Another private download starts while this question is open.
					losses.setValue(2)
					return .quitAndStopAsking
				default: return .quit
				}
			}
		}
		await store.send(.ui(.confirmQuit)).finish()
		for _ in 0..<1_000 where asked.count < 3 || store.checkingQuit { await Task.yield() }
		expectNoDifference(asked, [0, 1, 2])
		#expect(!store.settings.general.warnsBeforeQuitting)
		// Saving sends the same quit again; it doesn't ask about what was accepted.
		#expect(store.quitAcceptedLosses == 2)
	}

	/// Unattended and agent quits go straight to `quit`, which never asks, even about a download it
	/// would lose.
	@Test
	internal func unattendedQuitsNeverAsk() async throws {
		let store = Store(initialState: fixture()) { AppFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserDownloads.activeCount = { 1 }
			$0.browserDownloads.unresumableCount = { 1 }
			$0.quitConfirmation.confirm = { _ in
				Issue.record("An unattended quit asked")
				return .cancel
			}
			$0.browserDownloads.cancelAll = { Issue.record("Quitting cancelled downloads") }
		}
		await store.send(.ui(.quit)).finish()
		#expect(store.shouldQuit)
	}

	@Test
	internal func explicitQuitCancellationIgnoresLatePageApproval() async throws {
		let (started, startedContinuation) = AsyncStream<Void>.makeStream()
		var approval: CheckedContinuation<Bool, Never>?
		var requests = 0
		let store = Store(initialState: fixture()) { AppFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in
				requests += 1
				return await withCheckedContinuation { continuation in
					approval = continuation
					startedContinuation.yield(())
				}
			}
			$0.browserDownloads.activeCount = {
				Issue.record("Canceled quit queried transfers")
				return 1
			}
			$0.browserDownloads.cancelAll = { Issue.record("Canceled quit stopped downloads") }
		}
		let attempt = store.send(.ui(.quit))
		for await _ in started { break }
		await store.send(.ui(.cancelQuit)).finish()

		// Native page-close callbacks can arrive after their Swift task was canceled.
		try #require(approval).resume(returning: true)
		startedContinuation.finish()
		await attempt.finish()
		await store.send(.event(.retryQuit)).finish()
		expectNoDifference(requests, 1)
		#expect(!store.shouldQuit && !store.checkingQuit)
	}

	@Test
	internal func canceledQuitRejectionCannotCancelANewerAttempt() async throws {
		let state = fixture()
		let guardedTab = try #require(state.main.viewer.item.tab?.id)
		let (started, continuation) = AsyncStream<Void>.makeStream()
		var approvals: [CheckedContinuation<Bool, Never>] = []
		var transferQueries = 0
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { id in
				guard id == guardedTab else { return true }
				return await withCheckedContinuation {
					approvals.append($0)
					continuation.yield(())
				}
			}
			$0.browserDownloads.activeCount = {
				transferQueries += 1
				return 0
			}
		}
		var iterator = started.makeAsyncIterator()
		let firstAttempt = store.send(.ui(.quit))
		_ = await iterator.next()
		await store.send(.ui(.cancelQuit)).finish()
		let secondAttempt = store.send(.ui(.quit))
		_ = await iterator.next()
		approvals[0].resume(returning: false)
		await firstAttempt.finish()
		#expect(store.checkingQuit && !store.shouldQuit)
		approvals[1].resume(returning: true)
		await secondAttempt.finish()
		continuation.finish()
		#expect(store.shouldQuit)
		// Quitting leaves downloads to the engine's shutdown, so it reads none (DEV-966).
		expectNoDifference(transferQueries, 0)
	}

	@Test
	internal func utilityPreservesBrowsingAndPrivateOriginSelectsItsSeparateQueue() async throws {
		var state = fixture()
		let privateID = UUID(50)
		state.windows.append(.init(organization: state.workspace, spaceID: state.main.sidebar.spaceID, isPrivate: true, id: privateID))
		let store = Store(initialState: state) { AppFeature() } withDependencies: { $0.uuid = .incrementing }
		await store.send(.ui(.openDownloads(state.main.id))).finish()
		#expect(!store.downloads.isPresented)
		await store.send(.event(.downloadsReady)).finish()
		let original = store.main
		await store.send(.ui(.openDownloads(state.main.id))).finish()
		expectNoDifference(store.downloads.profileID, state.main.sidebar.space.profileID)
		expectNoDifference(store.downloads.filter, .currentProfile)
		#expect(store.downloads.isPresented)
		await store.send(.downloads(.ui(.dismissed))).finish()
		expectNoDifference(store.main, original)
		await store.send(.ui(.openDownloads(privateID))).finish()
		expectNoDifference(store.downloads.filter, .privateTransfers)
		#expect(store.downloads.profileID == nil)
		await store.send(.ui(.closeAdditionalWindow(privateID))).finish()
		#expect(store.downloads.isPresented)
		expectNoDifference(store.main.viewer, state.main.viewer)
	}

	@Test
	internal func profileConfigurationFailureKeepsExistingTransferControlsAvailable() async throws {
		var attempts = 0
		let store = Store(initialState: fixture()) { AppFeature() } withDependencies: {
			$0.browserDownloads.configure = { _ in
				attempts += 1
				throw BrowserDownloadsClient.Failure.unavailable
			}
		}
		await store.send(.event(.downloadsReady)).finish()
		await store.send(.event(.downloadsReady)).finish()
		expectNoDifference(attempts, 1)
		#expect(store.downloadsReady)
		#expect(store.downloads.message != nil)
		await store.send(.ui(.command(.downloads, .application))).finish()
		#expect(store.downloads.isPresented)
	}

	@Test
	internal func availableQueueIsReachableAfterTheLastBrowserWindowCloses() async throws {
		var state = fixture()
		state.windowIsOpen = false
		state.focusedWindowID = nil
		let store = Store(initialState: state) { AppFeature() }
		await store.send(.event(.downloadsReady)).finish()
		await store.send(.ui(.command(.downloads, .application))).finish()
		#expect(store.downloads.isPresented)
		#expect(!store.windowIsOpen)
		await store.send(.ui(.command(.closeTab, .downloads))).finish()
		#expect(!store.downloads.isPresented)
	}

	@Test
	internal func newWindowsShareUtilityAvailabilityAcrossCommandSurfaces() async throws {
		let store = Store(initialState: fixture()) { AppFeature() } withDependencies: { $0.uuid = .incrementing }
		await store.send(.event(.downloadsReady)).finish()
		await store.send(.ui(.newWindow)).finish()
		let window = try #require(store.windows.first)
		#expect(BrowserCommand.downloads.isEnabled(in: window.commandContext))
		#expect(window.commandCandidates.contains { $0.presentation.id == "command-downloads" })
		await store.send(.ui(.openLittleArx())).finish()
		let little = try #require(store.littleWindows.first)
		#expect(BrowserCommand.downloads.isEnabled(in: little.commandContext))
	}

	@Test(arguments: [false, true])
	internal func newerConfigurationStopsOlderPreparationAndItsLateFailure(fromReadiness: Bool) async throws {
		var state = fixture()
		let removedProfile = Profile.ID(rawValue: UUID(51))
		state.workspace.profiles.append(.init(id: removedProfile, name: "Removed before preparation"))
		state.workspace.spaces.append(.init(id: .init(rawValue: UUID(52)), profileID: removedProfile, name: "Removed"))
		state.main.sidebar.organization = state.workspace
		state.downloadsReady = !fromReadiness
		let privateTransfer = BrowserDownload(
			id: .init(profileID: .init(rawValue: UUID(53)), guid: "private-fixture"),
			profileName: "Private",
			filename: "private.txt",
			status: .inProgress,
			startedAt: .now,
			isPrivate: true
		)
		state.downloads.queue = .init(privateDownloads: [privateTransfer])
		let started = AsyncStream<Void>.makeStream()
		var release: CheckedContinuation<Void, Never>?
		var preparedRemoved = false
		var configurations: [BrowserOrganization] = []
		let store = Store(initialState: state) { AppFeature() } withDependencies: {
			$0.browserDownloads.configure = { organization in
				configurations.append(organization)
				guard organization.profiles.ids.contains(removedProfile) else { return }
				await withCheckedContinuation {
					release = $0
					started.continuation.yield(())
				}

				// Mirrors production's cancellation boundary between native profile preparations.
				try Task.checkCancellation()
				preparedRemoved = true
				throw BrowserDownloadsClient.Failure.unavailable
			}
			$0.browserDownloads.cancelAll = { Issue.record("Configuration changes must not cancel transfers") }
		}
		let first = store.send(fromReadiness ? .event(.downloadsReady) : .delegate(.save(state.workspace)))
		var iterator = started.stream.makeAsyncIterator()
		_ = await iterator.next()
		var current = state.workspace
		current.profiles.removeLast()
		current.spaces.removeLast()
		current.spaces[0].name = "Latest origin label"
		await store.send(.main(.reconcile(current))).finish()
		await store.send(.main(.delegate(.organizationChanged(current)))).finish()
		try #require(release).resume()
		await first.finish()
		expectNoDifference(configurations, [state.workspace, current])
		#expect(!preparedRemoved)
		#expect(store.downloads.message == nil)
		expectNoDifference(store.downloads.queue.privateDownloads, [privateTransfer])
		#expect(store.downloadsReady)
	}

	@Test
	internal func configurationReportsInBeforeReachingTheClient() async throws {
		var state = fixture()
		state.downloadsReady = true
		let configurations = LockIsolated<[BrowserOrganization]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserDownloads.configure = { organization in configurations.withValue { $0.append(organization) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.delegate(.save(state.workspace))) {
			$0.downloadsConfiguration = 1
		}
		await store.receive(\.event.downloadsConfigurationStarted, 1)
		await store.finish()

		// A configuration superseded before it reported in changes nothing.
		await store.send(.event(.downloadsConfigurationStarted(0)))
		expectNoDifference(configurations.value, [state.workspace])
	}

	/// Back-to-back saves race to register their configuration effects off the main actor.
	/// Only the newest organization may reach the client, whichever effect registers first.
	@Test
	internal func backToBackSavesConfigureOnlyTheNewestOrganization() async throws {
		var state = fixture()
		state.downloadsReady = true
		let older = state.workspace
		var newer = older
		newer.spaces[0].name = "Newest"
		var inverted = 0

		for _ in 0..<200 {
			let configurations = LockIsolated<[BrowserOrganization]>([])
			let store = Store(initialState: state) { AppFeature() } withDependencies: {
				$0.browserDownloads.configure = { organization in configurations.withValue { $0.append(organization) } }
			}

			// Configuration follows the published workspace, so publish the newer one in between.
			let first = store.send(.delegate(.save(older)))
			store.send(.main(.reconcile(newer)))
			let second = store.send(.main(.delegate(.organizationChanged(newer))))
			await first.finish()
			await second.finish()

			if configurations.value != [newer] { inverted += 1 }
		}

		#expect(inverted == 0)
	}

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		return state
	}
}

@MainActor
private final class StoreContext {
	weak var store: StoreOf<AppFeature>?
}
