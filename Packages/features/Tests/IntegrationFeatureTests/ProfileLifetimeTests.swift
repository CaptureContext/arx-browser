import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-880. Launch loads only the profiles windows show; idle ones are released by sweeps.
@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct ProfileLifetimeTests {
	private let shown: Profile.ID = .init(rawValue: UUID(10))
	private let sheet: Profile.ID = .init(rawValue: UUID(11))
	private let prompt: Profile.ID = .init(rawValue: UUID(12))
	private let opener: Profile.ID = .init(rawValue: UUID(13))
	private let idle: Profile.ID = .init(rawValue: UUID(14))
	private let promptTab: BrowserCore.Tab.ID = .init(rawValue: UUID(20))
	private let sheetSpace: Space.ID = .init(rawValue: UUID(2))

	@Test
	internal func launchPreparesOnlyTheShownProfileAndSweepsPassTheAppsUses() async throws {
		let clock: TestClock<Duration> = .init()
		let prepared = LockIsolated<[Profile.ID]>([])
		let sweeps = LockIsolated<[(Set<Profile.ID>, Duration)]>([])
		let store = TestStore(initialState: state()) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.browserEngine.prepareProfile = { profile in prepared.withValue { $0.append(profile) } }
			$0.browserEngine.releaseIdleProfiles = { used, gracePeriod in
				sweeps.withValue { $0.append((used, gracePeriod)) }
				return []
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let release = ProfileRelease(gracePeriod: .seconds(8))

		await store.send(.startProfileRelease(release))
		await waitWhile { prepared.value.isEmpty }
		expectNoDifference(prepared.value, [shown])
		#expect(sweeps.value.isEmpty)

		// Each sweep passes what the app uses and the grace period; it prepares nothing.
		await store.send(.releaseIdleProfiles(release))
		await waitWhile { sweeps.value.isEmpty }
		expectNoDifference(sweeps.value.map(\.0), [[shown]])
		expectNoDifference(sweeps.value.map(\.1), [.seconds(8)])
		expectNoDifference(prepared.value, [shown])

		await store.skipInFlightEffects()
	}

	@Test
	internal func aWindowShowingAnotherProfilePreparesIt() async throws {
		let prepared = LockIsolated<[Profile.ID]>([])
		let store = TestStore(initialState: state()) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.browserEngine.prepareProfile = { profile in prepared.withValue { $0.append(profile) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.newWindowInSpace(sheetSpace)))
		await waitWhile { prepared.value.isEmpty }
		expectNoDifference(prepared.value, [sheet])

		// Another window on a profile already shown prepares nothing more.
		await store.send(.ui(.newWindowInSpace(sheetSpace)))
		for _ in 0..<1000 { await Task.yield() }
		expectNoDifference(prepared.value, [sheet])
	}

	@Test
	internal func everyKindOfAppUseHoldsItsProfile() {
		var state = state()
		expectNoDifference(state.profilesInUse, [shown])
		expectNoDifference(state.profilesShownInWindows, [shown])

		state.settings.siteSettings = .init(profileID: sheet, profileName: "Sheet")
		state.automation.passwordSave = .init(
			tabID: promptTab,
			token: 1,
			origin: "https://capturecontext.dev",
			username: "",
			isUpdate: false
		)
		state.privateProfileOpeners[.init(rawValue: UUID(30))] = opener
		expectNoDifference(state.profilesInUse, [shown, sheet, prompt, opener])

		// Windows alone decide what launch loads.
		expectNoDifference(state.profilesShownInWindows, [shown])

		// A closed main window shows nothing; a profile no longer in the workspace isn't held.
		state.windowIsOpen = false
		state.settings.siteSettings = nil
		state.workspace.profiles.remove(id: opener)
		expectNoDifference(state.profilesInUse, [prompt])
	}

	@Test
	internal func theGracePeriodComesFromTheEnvironmentOnlyWithinBounds() {
		let variable = ProfileRelease.gracePeriodVariable
		#expect(ProfileRelease.configured(environment: [:]) == .init())
		#expect(ProfileRelease.configured(environment: [variable: "5"]).gracePeriod == .seconds(5))
		#expect(ProfileRelease.configured(environment: [variable: "0"]) == .init())
		#expect(ProfileRelease.configured(environment: [variable: "soon"]) == .init())
	}

	private func state() -> AppFeature.State {
		let space = Space.ID(rawValue: UUID(1))
		let profiles: [Profile] = [shown, sheet, prompt, opener, idle].enumerated().map { index, id in
			.init(id: id, name: "Profile \(index)", favorites: id == prompt ? [promptTab] : [])
		}
		let organization = BrowserOrganization(
			profiles: profiles,
			spaces: [
				.init(id: space, profileID: shown, name: "Shown"),
				.init(id: sheetSpace, profileID: sheet, name: "Sheet"),
			],
			tabs: [
				.init(
					id: promptTab,
					profileID: prompt,
					restoration: .init(title: "Sign in", url: URL(string: "https://capturecontext.dev")!)
				)
			]
		)
		return AppFeature.State(main: .init(organization: organization, spaceID: space))
	}
}
