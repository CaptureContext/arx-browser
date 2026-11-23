import AppUpdaterClient
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

@testable import AppFeature

/// Settings › General › Updates and Check for Updates… (DEV-859).
@Suite(.dependencies)
@MainActor
internal struct UpdatesSettingsTests {
	private static let lastCheck: Date = .init(timeIntervalSince1970: 1_800_000_000)

	private static let ready: AppUpdaterClient.Status = .init(
		availability: .available,
		canCheck: true,
		automaticallyChecks: true,
		automaticallyDownloads: false,
		lastCheck: lastCheck
	)

	private static func settings(_ updates: AppUpdaterClient.Status?) -> SettingsFeature.State {
		var state: SettingsFeature.State = .init()
		state.updates = updates
		return state
	}

	// MARK: - Unavailable

	@Test
	internal func anUnconfiguredBuildSaysSoAndNeverReachesSparkle() async {
		let store = TestStore(initialState: SettingsFeature.State()) {
			SettingsFeature()
		} withDependencies: {
			$0.appUpdater = .unavailable(.missingPublicKey)
		}

		await store.send(.ui(.startUpdates))
		await store.receive(\.event.updatesChanged) {
			$0.updates = .unavailable(.missingPublicKey)
		}

		// testValue's unimplemented closures would fail the test if any of these reached the client.
		store.dependencies.appUpdater = .testValue
		await store.send(.ui(.checkForUpdates))
		await store.send(.ui(.automaticallyChecksForUpdates(false)))
		await store.send(.ui(.automaticallyDownloadsUpdates(true)))
	}

	@Test
	internal func nothingHappensBeforeTheUpdaterStarts() async {
		let store = TestStore(initialState: SettingsFeature.State()) { SettingsFeature() }

		await store.send(.ui(.checkForUpdates))
		await store.send(.ui(.automaticallyChecksForUpdates(true)))
	}

	// MARK: - Available

	@Test
	internal func startFollowsSparklesState() async {
		let (stream, continuation) = AsyncStream<AppUpdaterClient.Event>.makeStream()
		let store = TestStore(initialState: SettingsFeature.State()) {
			SettingsFeature()
		} withDependencies: {
			$0.appUpdater.start = { stream }
		}

		let task = await store.send(.ui(.startUpdates))
		continuation.yield(.status(Self.ready))
		await store.receive(\.event.updatesChanged) {
			$0.updates = Self.ready
		}

		var checking: AppUpdaterClient.Status = Self.ready
		checking.canCheck = false
		checking.isChecking = true
		continuation.yield(.status(checking))
		await store.receive(\.event.updatesChanged) {
			$0.updates = checking
		}

		continuation.finish()
		await task.finish()
	}

	@Test
	internal func checkNowAsksSparkle() async {
		let checks: LockIsolated<Int> = .init(0)
		let store = TestStore(initialState: Self.settings(Self.ready)) {
			SettingsFeature()
		} withDependencies: {
			$0.appUpdater.checkForUpdates = { checks.withValue { $0 += 1 } }
		}

		await store.send(.ui(.checkForUpdates))
		await store.finish()
		#expect(checks.value == 1)
	}

	@Test
	internal func checkNowWaitsWhileACheckRuns() async {
		var checking: AppUpdaterClient.Status = Self.ready
		checking.canCheck = false
		checking.isChecking = true
		let store = TestStore(initialState: Self.settings(checking)) { SettingsFeature() }

		await store.send(.ui(.checkForUpdates))
	}

	@Test
	internal func automaticChecksTurnOffAndOn() async {
		let values: LockIsolated<[Bool]> = .init([])
		let store = TestStore(initialState: Self.settings(Self.ready)) {
			SettingsFeature()
		} withDependencies: {
			$0.appUpdater.setAutomaticallyChecks = { value in values.withValue { $0.append(value) } }
		}

		await store.send(.ui(.automaticallyChecksForUpdates(false))) {
			$0.updates?.automaticallyChecks = false
		}

		// Already off: nothing to tell Sparkle.
		await store.send(.ui(.automaticallyChecksForUpdates(false)))
		await store.send(.ui(.automaticallyChecksForUpdates(true))) {
			$0.updates?.automaticallyChecks = true
		}
		await store.finish()
		#expect(values.value == [false, true])
	}

	@Test
	internal func automaticDownloadsNeedAutomaticChecks() async {
		let values: LockIsolated<[Bool]> = .init([])
		var manual: AppUpdaterClient.Status = Self.ready
		manual.automaticallyChecks = false
		let store = TestStore(initialState: Self.settings(manual)) {
			SettingsFeature()
		} withDependencies: {
			$0.appUpdater.setAutomaticallyDownloads = { value in values.withValue { $0.append(value) } }
		}

		await store.send(.ui(.automaticallyDownloadsUpdates(true)))
		#expect(values.value.isEmpty)

		store.dependencies.appUpdater.setAutomaticallyChecks = { _ in }
		await store.send(.ui(.automaticallyChecksForUpdates(true))) {
			$0.updates?.automaticallyChecks = true
		}
		await store.send(.ui(.automaticallyDownloadsUpdates(true))) {
			$0.updates?.automaticallyDownloads = true
		}
		await store.finish()
		#expect(values.value == [true])
	}

	// MARK: - Installing

	@Test
	internal func aRelaunchRequestQuitsThroughTheUsualPath() async {
		let store = TestStore(initialState: SettingsFeature.State()) {
			SettingsFeature()
		} withDependencies: {
			$0.appUpdater.start = {
				AsyncStream { continuation in
					continuation.yield(.quitRequested)
					continuation.finish()
				}
			}
		}

		await store.send(.ui(.startUpdates))
		await store.receive(\.delegate.quitToInstallUpdate)
	}

	@Test
	internal func aCancelledQuitClosesSparklesWindowAndKeepsTheUpdate() async {
		let cancellations: LockIsolated<Int> = .init(0)
		let organization = IntegrationFeatureTests().fixture()
		let initial: AppFeature.State = .init(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in false }
			$0.appUpdater.quitCancelled = { cancellations.withValue { $0 += 1 } }
		}

		await store.send(.settings(.delegate(.quitToInstallUpdate))) {
			$0.quitsToInstallUpdate = true
		}
		await store.receive(\.ui.quit) { $0.checkingQuit = true }

		// A page that won't close keeps Arx open, as with any other quit.
		await store.receive(\.event.quitDecision) {
			$0.checkingQuit = false
			$0.quitsToInstallUpdate = false
		}
		await store.receive(\.settings.event.updateQuitCancelled)
		await store.finish()
		#expect(!store.state.shouldQuit)
		#expect(cancellations.value == 1)
	}

	@Test
	internal func anOrdinaryCancelledQuitLeavesSparkleAlone() async {
		let organization = IntegrationFeatureTests().fixture()
		let initial: AppFeature.State = .init(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in false }
		}

		// testValue's quitCancelled is unimplemented, so reaching it would fail the test.
		await store.send(.ui(.quit)) { $0.checkingQuit = true }
		await store.receive(\.event.quitDecision) { $0.checkingQuit = false }
	}

	@Test
	internal func keepOpenAfterAFailedSaveAlsoClosesSparklesWindow() async {
		let cancellations: LockIsolated<Int> = .init(0)
		let organization = IntegrationFeatureTests().fixture()
		var initial: AppFeature.State = .init(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.quitsToInstallUpdate = true
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.appUpdater.quitCancelled = { cancellations.withValue { $0 += 1 } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.cancelQuit)) {
			$0.quitsToInstallUpdate = false
		}
		await store.receive(\.settings.event.updateQuitCancelled)
		await store.finish()
		#expect(cancellations.value == 1)
	}

	@Test
	internal func quitAndInstallOnlyWhileAnUpdateWaits() async {
		let store = TestStore(initialState: Self.settings(Self.ready)) { SettingsFeature() }
		await store.send(.ui(.installUpdate))

		var waiting: AppUpdaterClient.Status = Self.ready
		waiting.canCheck = false
		waiting.isReadyToInstall = true
		let ready = TestStore(initialState: Self.settings(waiting)) { SettingsFeature() }
		await ready.send(.ui(.installUpdate))
		await ready.receive(\.delegate.quitToInstallUpdate)

		// Sparkle's session is still open, so Check Now stays off.
		await ready.send(.ui(.checkForUpdates))
	}
}
