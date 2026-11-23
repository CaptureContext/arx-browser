import BrowserCore
import DefaultBrowserClient
import Foundation
import OnboardingFeature
import SettingsFeature
import Testing
import _ComposableArchitecture

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct DefaultBrowserSettingsTests {
	// MARK: - Settings row

	@Test
	internal func theRowShowsTheCurrentBrowser() async {
		let system: DefaultBrowserDouble = .init(handled: [])
		let store = TestStore(initialState: SettingsFeature.State()) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = system.client
		}

		await store.send(.ui(.checkDefaultBrowser))
		await store.receive(\.event.defaultBrowserChecked) {
			$0.defaultBrowser = .otherBrowser("Safari")
		}
	}

	@Test
	internal func acceptedMakesArxTheDefault() async {
		let system: DefaultBrowserDouble = .init(handled: [])
		system.answer = { system.handled = [.http, .https] }
		let store = TestStore(initialState: settings(.otherBrowser("Safari"))) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = system.client
		}

		await store.send(.ui(.makeDefaultBrowser)) {
			$0.isRequestingDefaultBrowser = true
		}
		await store.receive(\.event.defaultBrowserRequestFinished, .accepted) {
			$0.isRequestingDefaultBrowser = false
			$0.defaultBrowserOutcome = .accepted
			$0.defaultBrowser = .isDefault
		}
		#expect(system.requests == [.http])

		// Arx is the default now, so there's nothing left to ask.
		await store.send(.ui(.makeDefaultBrowser))
		#expect(system.requests == [.http])
	}

	@Test
	internal func declinedKeepsTheCurrentBrowserAndSaysSo() async {
		let system: DefaultBrowserDouble = .init(handled: [])
		system.answer = { throw CocoaError(.userCancelled) }
		let store = TestStore(initialState: settings(.otherBrowser("Safari"))) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = system.client
		}

		await store.send(.ui(.makeDefaultBrowser)) {
			$0.isRequestingDefaultBrowser = true
		}
		await store.receive(\.event.defaultBrowserRequestFinished, .declined) {
			$0.isRequestingDefaultBrowser = false
			$0.defaultBrowserOutcome = .declined
		}
		await store.receive(\.event.defaultBrowserChecked)
		#expect(store.state.defaultBrowser == .otherBrowser("Safari"))
	}

	@Test
	internal func alreadyDefaultAsksNothing() async {
		// Arx became the default in System Settings after the row last checked.
		let system: DefaultBrowserDouble = .init(handled: [.http, .https])
		let store = TestStore(initialState: settings(.otherBrowser("Safari"))) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = system.client
		}

		await store.send(.ui(.makeDefaultBrowser)) {
			$0.isRequestingDefaultBrowser = true
		}
		await store.receive(\.event.defaultBrowserRequestFinished, .alreadyDefault) {
			$0.isRequestingDefaultBrowser = false
			$0.defaultBrowserOutcome = .alreadyDefault
			$0.defaultBrowser = .isDefault
		}
		#expect(system.requests.isEmpty)
	}

	@Test
	internal func becomingActiveChecksAgainButNotMidPrompt() async {
		let system: DefaultBrowserDouble = .init(handled: [])
		let store = TestStore(initialState: settings(.otherBrowser("Safari"))) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = system.client
		}

		// The person made Arx the default in System Settings meanwhile.
		system.handled = [.http, .https]
		await store.send(.event(.applicationBecameActive))
		await store.receive(\.event.defaultBrowserChecked) {
			$0.defaultBrowser = .isDefault
		}

		var requesting: SettingsFeature.State = settings(.otherBrowser(nil))
		requesting.isRequestingDefaultBrowser = true
		let prompting = TestStore(initialState: requesting) { SettingsFeature() }
		await prompting.send(.event(.applicationBecameActive))
		await prompting.send(.ui(.makeDefaultBrowser))
	}

	@Test
	internal func unavailableRunsOfferNothing() async {
		let store = TestStore(initialState: SettingsFeature.State()) {
			SettingsFeature()
		} withDependencies: {
			$0.defaultBrowser = .unavailable
		}

		await store.send(.ui(.checkDefaultBrowser))
		await store.receive(\.event.defaultBrowserChecked) {
			$0.defaultBrowser = .unavailable
		}
		await store.send(.ui(.makeDefaultBrowser))
	}

	// MARK: - App activation

	@Test
	internal func activationOnlyReachesAnOpenSettingsWindowAndTheVisiblePage() async {
		let organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		let initial: AppFeature.State = .init(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)

		// Nothing is open, so nothing reads the default.
		let closed = TestStore(initialState: initial) { AppFeature() }
		await closed.send(.event(.applicationBecameActive))

		let system: DefaultBrowserDouble = .init(handled: [])
		var open: AppFeature.State = initial
		open.settingsIsOpen = true
		open.onboarding = .init(mode: .step(.defaultBrowser))
		let store = TestStore(initialState: open) {
			AppFeature()
		} withDependencies: {
			$0.defaultBrowser = system.client
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.applicationBecameActive))
		await store.receive(\.settings.event.applicationBecameActive)
		await store.receive(\.onboarding.page.defaultBrowser.event.applicationBecameActive)
		await store.receive(\.settings.event.defaultBrowserChecked)
		await store.receive(\.onboarding.page.defaultBrowser.event.statusChecked)
		#expect(store.state.settings.defaultBrowser == .otherBrowser("Safari"))
		#expect(store.state.onboarding?.page.defaultBrowser?.status == .otherBrowser("Safari"))
	}

	@Test
	internal func activationReachesTheImportPageForFullDiskAccess() async {
		let organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		var state: AppFeature.State = .init(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		state.onboarding = .init(mode: .step(.migration))
		let store = TestStore(initialState: state) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.event(.applicationBecameActive))
		await store.receive(\.onboarding.page.migration.event.applicationBecameActive)
	}

	// MARK: - Helpers

	private func settings(_ status: DefaultBrowserClient.Status) -> SettingsFeature.State {
		var state: SettingsFeature.State = .init()
		state.defaultBrowser = status
		return state
	}
}

/// Launch Services as the client sees it.
@MainActor
private final class DefaultBrowserDouble {
	var handled: Set<DefaultBrowserClient.Scheme>
	var answer: @MainActor () throws -> Void
	var requests: [DefaultBrowserClient.Scheme]

	init(handled: Set<DefaultBrowserClient.Scheme>) {
		self.handled = handled
		self.answer = {}
		self.requests = []
	}

	var client: DefaultBrowserClient {
		.init(
			isAvailable: { true },
			isDefault: { scheme in self.handled.contains(scheme) },
			currentBrowserName: { "Safari" },
			requestDefault: { scheme in
				self.requests.append(scheme)
				try self.answer()
			}
		)
	}
}
