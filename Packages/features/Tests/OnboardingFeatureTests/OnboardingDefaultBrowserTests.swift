import BrowserCore
import DefaultBrowserClient
import Foundation
import OnboardingFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct OnboardingDefaultBrowserTests {
	/// Every step before the default-browser page, so the flow opens on it as its last page.
	private static let earlierSteps: [OnboardingStep] = [.welcome, .tour, .migration, .outsideAgents]

	// MARK: - Checking

	@Test
	internal func thePageReadsTheDefaultWhenItAppears() async {
		let system: DefaultBrowserDouble = .init(handled: [])
		let store = TestStore(initialState: OnboardingFeature.State(completedSteps: Self.earlierSteps)) {
			OnboardingFeature()
		} withDependencies: {
			$0.defaultBrowser = system.client
		}
		#expect(store.state.page == .defaultBrowser(.init()))

		await store.send(.page(.defaultBrowser(.ui(.task))))
		await store.receive(\.page.defaultBrowser.event.statusChecked) {
			$0.page = .defaultBrowser(.init(status: .otherBrowser("Safari")))
		}
		#expect(store.state.completedSteps == Self.earlierSteps)
	}

	@Test
	internal func alreadyDefaultRecordsTheStepAndStaysForContinue() async {
		let system: DefaultBrowserDouble = .init(handled: [.http, .https])
		let store = TestStore(initialState: OnboardingFeature.State(completedSteps: Self.earlierSteps)) {
			OnboardingFeature()
		} withDependencies: {
			$0.defaultBrowser = system.client
		}

		await store.send(.page(.defaultBrowser(.ui(.task))))
		await store.receive(\.page.defaultBrowser.event.statusChecked) {
			$0.page = .defaultBrowser(.init(status: .isDefault))
		}
		await store.receive(\.page.defaultBrowser.delegate.foundDefault) {
			$0.completedSteps = Self.earlierSteps + [.defaultBrowser]
		}
		await store.receive(\.delegate.stepCompleted, .defaultBrowser)
		#expect(store.state.step == .defaultBrowser)
		#expect(system.requests.isEmpty)

		// Checking again after the app becomes active doesn't record it twice.
		await store.send(.page(.defaultBrowser(.event(.applicationBecameActive))))
		await store.receive(\.page.defaultBrowser.event.statusChecked)

		await store.send(.ui(.continueSetup))
		await store.receive(\.delegate.handOff)
	}

	// MARK: - Make Default

	@Test
	internal func acceptedRecordsTheStepAndMovesOn() async {
		let system: DefaultBrowserDouble = .init(handled: [])
		system.answer = { system.handled = [.http, .https] }
		let store = TestStore(initialState: page(status: .otherBrowser("Safari"))) {
			OnboardingFeature()
		} withDependencies: {
			$0.defaultBrowser = system.client
		}

		await store.send(.page(.defaultBrowser(.ui(.makeDefault)))) {
			$0.page = .defaultBrowser(.init(status: .otherBrowser("Safari"), isRequesting: true))
		}
		#expect(!store.state.canClose)
		await store.receive(\.page.defaultBrowser.event.requestFinished, .accepted) {
			$0.page = .defaultBrowser(.init(status: .isDefault, outcome: .accepted))
		}
		await store.receive(\.page.defaultBrowser.delegate.madeDefault) {
			$0.completedSteps = Self.earlierSteps + [.defaultBrowser]
		}
		await store.receive(\.delegate.stepCompleted, .defaultBrowser)
		await store.receive(\.delegate.handOff)
		#expect(system.requests == [.http])
	}

	@Test
	internal func declinedRecordsNothingAndStaysOnThePage() async {
		let system: DefaultBrowserDouble = .init(handled: [])
		system.answer = { throw CocoaError(.userCancelled) }
		let store = TestStore(initialState: page(status: .otherBrowser("Safari"))) {
			OnboardingFeature()
		} withDependencies: {
			$0.defaultBrowser = system.client
		}

		await store.send(.page(.defaultBrowser(.ui(.makeDefault)))) {
			$0.page = .defaultBrowser(.init(status: .otherBrowser("Safari"), isRequesting: true))
		}
		await store.receive(\.page.defaultBrowser.event.requestFinished, .declined) {
			$0.page = .defaultBrowser(.init(status: .otherBrowser("Safari"), outcome: .declined))
		}
		await store.receive(\.page.defaultBrowser.event.statusChecked)
		#expect(store.state.completedSteps == Self.earlierSteps)
		#expect(store.state.step == .defaultBrowser)

		// Not Now moves on without recording the step.
		await store.send(.ui(.skip))
		await store.receive(\.delegate.handOff)
		#expect(store.state.completedSteps == Self.earlierSteps)
	}

	@Test
	internal func alreadyDefaultFromMakeDefaultRecordsTheStepAndMovesOn() async {
		// Arx became the default in System Settings after the page last checked.
		let system: DefaultBrowserDouble = .init(handled: [.http, .https])
		let store = TestStore(initialState: page(status: .otherBrowser("Safari"))) {
			OnboardingFeature()
		} withDependencies: {
			$0.defaultBrowser = system.client
		}

		await store.send(.page(.defaultBrowser(.ui(.makeDefault)))) {
			$0.page = .defaultBrowser(.init(status: .otherBrowser("Safari"), isRequesting: true))
		}
		await store.receive(\.page.defaultBrowser.event.requestFinished, .alreadyDefault) {
			$0.page = .defaultBrowser(.init(status: .isDefault, outcome: .alreadyDefault))
		}
		await store.receive(\.page.defaultBrowser.delegate.madeDefault) {
			$0.completedSteps = Self.earlierSteps + [.defaultBrowser]
		}
		await store.receive(\.delegate.stepCompleted, .defaultBrowser)
		await store.receive(\.delegate.handOff)
		#expect(system.requests.isEmpty)
	}

	@Test
	internal func theWindowStaysWhileTheSystemPromptMayBeShowing() async {
		let store = TestStore(
			initialState: page(status: .otherBrowser(nil), isRequesting: true)
		) {
			OnboardingFeature()
		}

		#expect(!store.state.canClose)
		await store.send(.ui(.dismiss))
		await store.send(.ui(.continueSetup))
		await store.send(.ui(.skip))
		await store.send(.ui(.back))

		// A second press doesn't ask again, and activation doesn't check mid-prompt.
		await store.send(.page(.defaultBrowser(.ui(.makeDefault))))
		await store.send(.page(.defaultBrowser(.event(.applicationBecameActive))))
	}

	@Test
	internal func unavailableRunsOfferNothingToMakeDefault() async {
		let store = TestStore(initialState: OnboardingFeature.State(completedSteps: Self.earlierSteps)) {
			OnboardingFeature()
		} withDependencies: {
			$0.defaultBrowser = .unavailable
		}

		await store.send(.page(.defaultBrowser(.ui(.task))))
		await store.receive(\.page.defaultBrowser.event.statusChecked) {
			$0.page = .defaultBrowser(.init(status: .unavailable))
		}
		#expect(store.state.page.defaultBrowser?.canMakeDefault == false)
		await store.send(.page(.defaultBrowser(.ui(.makeDefault))))
		#expect(store.state.completedSteps == Self.earlierSteps)
	}

	// MARK: - Helpers

	private func page(
		status: DefaultBrowserClient.Status,
		isRequesting: Bool = false
	) -> OnboardingFeature.State {
		var state: OnboardingFeature.State = .init(completedSteps: Self.earlierSteps)
		state.page = .defaultBrowser(.init(status: status, isRequesting: isRequesting))
		return state
	}
}

/// Launch Services as the client sees it.
@MainActor
private final class DefaultBrowserDouble {
	internal var handled: Set<DefaultBrowserClient.Scheme>
	internal var answer: @MainActor () throws -> Void
	internal var requests: [DefaultBrowserClient.Scheme]

	internal init(handled: Set<DefaultBrowserClient.Scheme>) {
		self.handled = handled
		self.answer = {}
		self.requests = []
	}

	internal var client: DefaultBrowserClient {
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
