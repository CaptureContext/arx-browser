import AppKit
import AppUI
import BrowserCore
import Foundation
import SwiftUI
import _ComposableArchitecture

/// Settings › Advanced › Feature Flags (DEV-1115): reads every flag when the page opens, saves a
/// toggle to user defaults, and offers Relaunch while a change waits for one. A flag the
/// environment sets can't change here.
@Reducer
internal struct SettingsFeatureFlagsPage {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	@Dependency(\.featureFlags)
	private var featureFlags

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.featureFlagsAppeared) { state in
			state.featureFlagStates = Self.states(featureFlags)
			return .none
		}

		Pullback(\.ui.featureFlagChanged) { state, value in
			let (flag, isOn) = value
			guard featureFlags.state(flag).source != .environment else {
				state.featureFlagStates[flag] = featureFlags.state(flag)
				return .none
			}

			featureFlags.set(flag, isOn)
			state.featureFlagStates[flag] = featureFlags.state(flag)
			return .none
		}

		// Through AppFeature's usual quit, so unsaved changes, downloads and pages that ask to
		// stay keep Arx open as they would for Quit.
		Pullback(\.ui.relaunchForFeatureFlags) { _ in
			.send(.delegate(.quitToRelaunch))
		}
	}

	private static func states(_ client: FeatureFlagsClient) -> [FeatureFlag: FeatureFlagState] {
		Dictionary(uniqueKeysWithValues: FeatureFlag.allCases.map { ($0, client.state($0)) })
	}
}

extension SettingsFeature.State {
	/// The flags whose change waits for a relaunch: each reads only at launch, and its value now
	/// isn't the one Arx launched with.
	public var featureFlagsAwaitingRelaunch: [FeatureFlag] {
		FeatureFlag.allCases.filter { flag in
			guard
				flag.needsRelaunch,
				let launched = launchFeatureFlags[flag],
				let now = featureFlagStates[flag]
			else { return false }

			return launched != now.isOn
		}
	}
}
