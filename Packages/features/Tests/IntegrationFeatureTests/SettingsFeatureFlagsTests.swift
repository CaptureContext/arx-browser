import AppUI
import BrowserCore
import CustomDump
import Foundation
@testable import AppFeature
@testable import SettingsFeature
import Testing
import _ComposableArchitecture

/// DEV-1115: Settings › Advanced › Feature Flags reads every flag, saves a toggle to user
/// defaults, leaves a flag the environment sets alone, and offers Relaunch for the changes that
/// wait for one.
@MainActor
@Suite(.dependencies)
internal struct SettingsFeatureFlagsTests {
	@Test
	internal func aToggleSavesAndWaitsForARelaunch() async throws {
		let defaults = try #require(UserDefaults(suiteName: "SettingsFeatureFlagsTests.\(UUID())"))
		let launched = Self.states(environment: [:], defaults: defaults)
		var initial = SettingsFeature.State()
		initial.launchFeatureFlags = launched.mapValues(\.isOn)
		let store = TestStore(initialState: initial) {
			SettingsFeature()
		} withDependencies: {
			$0.featureFlags = Self.client(environment: [:], defaults: defaults)
		}

		await store.send(.ui(.featureFlagsAppeared)) {
			$0.featureFlagStates = launched
		}

		// Reading mode is on by default (DEV-1143); turning it off is saved as `off`.
		await store.send(.ui(.featureFlagChanged(.readingMode, false))) {
			$0.featureFlagStates[.readingMode] = .init(isOn: false, source: .defaults)
		}
		expectNoDifference(defaults.string(forKey: FeatureFlag.readingMode.name), "off")
		expectNoDifference(store.state.featureFlagsAwaitingRelaunch, [.readingMode])

		// Back to how Arx launched: nothing waits.
		await store.send(.ui(.featureFlagChanged(.readingMode, true))) {
			$0.featureFlagStates[.readingMode] = .init(isOn: true, source: .defaults)
		}
		expectNoDifference(store.state.featureFlagsAwaitingRelaunch, [])

		// Relaunch asks AppFeature to quit the usual way.
		await store.send(.ui(.relaunchForFeatureFlags))
		await store.receive(\.delegate.quitToRelaunch)
	}

	/// Relaunch quits as Quit does, and Arx opens again only once the quit goes ahead.
	@Test
	internal func relaunchReopensOnlyAfterTheQuitGoesAhead() async {
		let organization = IntegrationFeatureTests().fixture()
		let initial: AppFeature.State = .init(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let reopened = LockIsolated(0)
		let permits = LockIsolated(false)
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in permits.value }
			$0.browserDownloads.activeCount = { 0 }
			$0.browserDownloads.unresumableCount = { 0 }
			$0.quitConfirmation.confirm = { _ in
				Issue.record("Relaunch asked with nothing to lose")
				return .cancel
			}
			$0.featureFlags.reopenAfterQuit = { reopened.withValue { $0 += 1 } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// A page that won't close keeps Arx open, and nothing reopens.
		await store.send(.settings(.delegate(.quitToRelaunch))) {
			$0.quitsToRelaunch = true
		}
		await store.receive(\.ui.quit)
		await store.receive(\.event.quitDecision) {
			$0.quitsToRelaunch = false
		}
		await store.finish()
		#expect(reopened.value == 0)

		permits.setValue(true)
		await store.send(.settings(.delegate(.quitToRelaunch))) {
			$0.quitsToRelaunch = true
		}
		await store.receive(\.ui.quit)
		await store.receive(\.event.quitDecision) {
			$0.shouldQuit = true
			$0.quitsToRelaunch = false
		}
		await store.skipReceivedActions()
		await store.finish()
		#expect(reopened.value == 1)
	}

	/// Relaunch asks before losing a download that can't resume, as ⌘Q does with its warning off,
	/// and a cancel there keeps Arx open with nothing to reopen.
	@Test
	internal func relaunchAsksBeforeLosingADownload() async {
		let organization = IntegrationFeatureTests().fixture()
		let initial: AppFeature.State = .init(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.settings.$general.withLock { $0.warnsBeforeQuitting = false }
		let answer = LockIsolated(QuitConfirmation.Answer.cancel)
		let asked = LockIsolated<[QuitConfirmation.Downloads]>([])
		let reopened = LockIsolated(0)
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.browserEngine.permitsClosing = { _ in true }
			$0.browserDownloads.activeCount = { 2 }
			$0.browserDownloads.unresumableCount = { 1 }
			$0.quitConfirmation.confirm = { downloads in
				asked.withValue { $0.append(downloads) }
				return answer.value
			}
			$0.featureFlags.reopenAfterQuit = { reopened.withValue { $0 += 1 } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.delegate(.quitToRelaunch))) {
			$0.quitsToRelaunch = true
		}
		await store.receive(\.event.relaunchDeclined) {
			$0.quitsToRelaunch = false
		}
		await store.finish()
		expectNoDifference(asked.value, [.init(active: 2, unresumable: 1)])
		#expect(!store.state.shouldQuit && !store.state.checkingQuit)
		#expect(reopened.value == 0)

		// Quit there accepts the loss, so the quit itself doesn't ask again.
		answer.setValue(.quit)
		await store.send(.settings(.delegate(.quitToRelaunch))) {
			$0.quitsToRelaunch = true
		}
		await store.receive(\.event.quitConfirmed) {
			$0.quitAcceptedLosses = 1
		}
		await store.receive(\.ui.quit)
		await store.receive(\.event.quitDecision) {
			$0.shouldQuit = true
			$0.quitsToRelaunch = false
		}
		await store.skipReceivedActions()
		await store.finish()
		expectNoDifference(asked.value.count, 2)
		#expect(reopened.value == 1)
	}

	@Test
	internal func aFlagTheEnvironmentSetsStaysAsItIs() async throws {
		let defaults = try #require(UserDefaults(suiteName: "SettingsFeatureFlagsTests.\(UUID())"))
		let environment = [FeatureFlag.agentTabs.name: "1"]
		let launched = Self.states(environment: environment, defaults: defaults)
		var initial = SettingsFeature.State()
		initial.launchFeatureFlags = launched.mapValues(\.isOn)
		let store = TestStore(initialState: initial) {
			SettingsFeature()
		} withDependencies: {
			$0.featureFlags = Self.client(environment: environment, defaults: defaults)
		}
		expectNoDifference(launched[.agentTabs], .init(isOn: true, source: .environment))

		await store.send(.ui(.featureFlagsAppeared)) {
			$0.featureFlagStates = launched
		}
		await store.send(.ui(.featureFlagChanged(.agentTabs, false)))
		expectNoDifference(defaults.string(forKey: FeatureFlag.agentTabs.name), nil)
		expectNoDifference(store.state.featureFlagsAwaitingRelaunch, [])
	}

	/// DEV-1143: a flag says why it's off by default only when it is, which none is for the beta.
	@Test
	internal func onlyAFlagOffByDefaultSaysWhy() {
		for flag in FeatureFlag.allCases {
			expectNoDifference(flag.offReason != nil, !flag.isOnByDefault, "\(flag)")
		}
	}

	/// Agents can't reach the page: it's the person's.
	@Test
	internal func thePageIsTheUsers() async throws {
		expectNoDifference(SettingsDestination.page(.featureFlags).access, .user)
		let entry = try #require(SettingsCategory.searchIndex.first { $0.destination == .page(.featureFlags) })
		expectNoDifference(entry.category, .advanced)
		expectNoDifference(
			SettingsCategory.searchIndex.matching(FeatureFlag.iCloudSync.name).first?.destination,
			.page(.featureFlags)
		)
	}

	private static func client(
		environment: [String: String],
		defaults: UserDefaults
	) -> FeatureFlagsClient {
		nonisolated(unsafe) let defaults = defaults
		return .init(
			state: { $0.state(environment: environment, defaults: defaults) },
			set: { flag, isOn in flag.set(isOn, defaults: defaults) },
			reopenAfterQuit: unimplemented("reopenAfterQuit")
		)
	}

	private static func states(
		environment: [String: String],
		defaults: UserDefaults
	) -> [FeatureFlag: FeatureFlagState] {
		Dictionary(
			uniqueKeysWithValues: FeatureFlag.allCases.map { ($0, $0.state(environment: environment, defaults: defaults)) }
		)
	}
}
