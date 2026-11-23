import AppUI
import BrowserCore
import CustomDump
import Foundation
import SettingsFeature
import Testing
import _TestSupport
import _ComposableArchitecture

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct GlobalShortcutTests {
	@Test
	internal func disabledPreferenceDoesNotRegisterAndLegacySnapshotsRemainOptOut() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let store = TestStore(initialState: state) { GlobalShortcuts() }
		await store.send(.configureGlobalShortcut)
		await store.send(.event(.globalShortcut(0, .pressed)))
		let old = Data(#"{"grainEnabled":true,"grainIntensity":0.35,"grainSize":1,"searchShortcuts":[]}"#.utf8)
		#expect(try !JSONDecoder().decode(BrowserPreferences.self, from: old).globalLittleArxEnabled)
	}

	@Test
	internal func registrationFailureIsVisibleAndDisablingRejectsLateCallbacks() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.settings.$linkClicks.withLock { $0.globalLittleArxEnabled = true }
		let (stream, continuation) = AsyncStream<GlobalShortcutEvent>.makeStream()
		let store = TestStore(initialState: state) {
			CombineReducers {
				GlobalShortcuts()
				Scope(state: \.settings, action: \.settings) { SettingsFeature() }
			}
			.reconfiguringGlobalShortcut()
		} withDependencies: {
			$0.globalShortcut.events = { _ in stream }
		}
		await store.send(.configureGlobalShortcut) {
			$0.globalShortcutBinding = BrowserCommand.littleArx.shortcut
			$0.globalShortcutGeneration = 1
			$0.settings.globalShortcutMessage = String.localized(.appUI.settings.globalShortcutRegistering)
		}
		await store.receive(\.event.globalShortcutStarted)
		continuation.yield(.failed(-9878))
		await store.receive(\.event.globalShortcut) {
			$0.settings.globalShortcutMessage = String.localized(.appUI.settings.globalShortcutFailed(-9878))
		}
		await store.send(.settings(.ui(.globalLittleArxEnabled(false)))) {
			$0.settings.$linkClicks.withLock { $0.globalLittleArxEnabled = false }
		}

		// Switching it off reaches the registration through the shared preference, not a delegate action.
		await store.receive(\.configureGlobalShortcut) {
			$0.globalShortcutBinding = nil
			$0.globalShortcutGeneration = 2
			$0.settings.globalShortcutMessage = nil
		}
		await store.send(.event(.globalShortcut(1, .registered)))
		await store.send(.event(.globalShortcut(1, .pressed)))
		await store.finish()
	}

	/// Back-to-back reconfiguration races the registrations off the main actor. Only the newest
	/// generation may reach the single native registration slot, and it must stay registered.
	@Test
	internal func backToBackReconfigurationRegistersOnlyTheNewestBinding() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.settings.$linkClicks.withLock { $0.globalLittleArxEnabled = true }
		let registered = String.localized(.appUI.settings.globalShortcutRegistered)
		var lost = 0
		var duplicated = 0

		for _ in 0..<200 {
			let registrations = LockIsolated<(count: Int, terminated: Int)>((0, 0))
			let store = Store(initialState: state) {
				CombineReducers {
					GlobalShortcuts()
					Scope(state: \.settings, action: \.settings) { SettingsFeature() }
				}
			} withDependencies: {
				$0.globalShortcut.events = { _ in
					let (stream, continuation) = AsyncStream<GlobalShortcutEvent>.makeStream()
					registrations.withValue { $0.count += 1 }
					continuation.onTermination = { _ in registrations.withValue { $0.terminated += 1 } }
					continuation.yield(.registered)
					return stream
				}
			}

			// Register, release while recording, then register the same binding again.
			store.send(.configureGlobalShortcut)
			store.send(.settings(.ui(.recordKeyboardShortcut(.newTab))))
			store.send(.settings(.ui(.recordKeyboardShortcut(nil))))

			if !(await eventually {
				store.globalShortcutBinding != nil && store.settings.globalShortcutMessage == registered
			}) { lost += 1 }
			if !(await eventually { registrations.value.count == 1 && registrations.value.terminated == 0 }) { duplicated += 1 }
			store.send(.settings(.ui(.recordKeyboardShortcut(.newTab))))
		}

		#expect(lost == 0)
		#expect(duplicated == 0)
	}

	@Test
	internal func recordingTemporarilyReleasesTheGlobalBinding() async throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.settings.$linkClicks.withLock { $0.globalLittleArxEnabled = true }
		state.globalShortcutBinding = BrowserCommand.littleArx.shortcut
		state.globalShortcutGeneration = 1
		state.settings.globalShortcutMessage = String.localized(.appUI.settings.globalShortcutRegistered)
		let store = TestStore(initialState: state) {
			CombineReducers {
				GlobalShortcuts()
				Scope(state: \.settings, action: \.settings) { SettingsFeature() }
			}
		}
		await store.send(.settings(.ui(.recordKeyboardShortcut(.newTab)))) { $0.settings.recordingCommand = .newTab }
		await store.receive(\.configureGlobalShortcut) {
			$0.globalShortcutBinding = nil
			$0.globalShortcutGeneration = 2
			$0.settings.globalShortcutMessage = nil
		}
		await store.send(.event(.globalShortcut(1, .pressed)))
		expectNoDifference(store.state.settings.keyboardShortcuts.shortcut(for: .littleArx), BrowserCommand.littleArx.shortcut)
	}

	@Test
	internal func optInWithoutABindingExplainsTheRequiredSetting() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.settings.$linkClicks.withLock { $0.globalLittleArxEnabled = true }
		state.settings.$keyboardShortcuts.withLock { $0.setShortcut(nil, for: .littleArx) }
		let store = TestStore(initialState: state) { GlobalShortcuts() }
		await store.send(.configureGlobalShortcut) {
			$0.settings.globalShortcutMessage = String.localized(.appUI.settings.globalShortcutNeedsBinding)
		}
	}

	private func eventually(_ condition: () -> Bool) async -> Bool {
		// Until a deadline rather than a fixed number of polls, which a busy Mac used up first.
		try? await waitWhile { !condition() }
		return condition()
	}
}
