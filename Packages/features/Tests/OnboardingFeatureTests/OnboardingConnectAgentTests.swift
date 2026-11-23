import AgentClient
import BrowserCore
import ChatFeature
import Foundation
import OnboardingFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-700: onboarding's "Connect your agent" page. Providers are doubles whose `send`
/// fails the test, so the page can only ever read sign-in status.
@Suite(.dependencies)
@MainActor
internal struct OnboardingConnectAgentTests {
	private static let earlierSteps: [OnboardingStep] = [.welcome, .tour, .migration]

	private static let claudeSignedIn: AgentAccount = .init(
		provider: .claude,
		status: .signedIn(.init(id: "~/.claude", label: "me@example.com", plan: "max"))
	)

	private static let codexSignedOut: AgentAccount = .init(
		provider: .openAI,
		status: .signedOut(instructions: "Open Terminal and run: codex login")
	)

	// MARK: - When the page shows

	@Test
	internal func thePageShowsOnlyWhenAProviderShipsAndAgentsMayRun() {
		#expect(
			OnboardingFlow.steps(includesConnectAgent: true)
				== [.welcome, .tour, .migration, .connectAgent, .outsideAgents, .defaultBrowser]
		)
		#expect(!OnboardingFlow.steps(includesConnectAgent: false).contains(.connectAgent))

		let cases: [(AgentProviders, Bool)] = [
			(Self.providers(isEnabled: true), true),
			(Self.providers(isEnabled: false), false),
			(.init(clients: [], isEnabled: true), false),
		]
		for (providers, shows) in cases {
			let steps: [OnboardingStep] = withDependencies {
				$0.agentProviders = providers
			} operation: {
				OnboardingFlow.steps
			}
			#expect(steps.contains(.connectAgent) == shows)
		}
	}

	// MARK: - Status

	@Test
	internal func thePageReadsEachProvidersSignInWhenItAppears() async {
		let checks: LockIsolated<Int> = .init(0)
		let store = Self.store(
			accounts: [Self.claudeSignedIn, Self.codexSignedOut],
			checks: checks
		)
		#expect(store.state.page == .connectAgent(.init()))

		await store.send(.page(.connectAgent(.ui(.task)))) {
			$0.page.modify(\.connectAgent) {
				$0.providers = [.claude, .openAI]
				$0.isChecking = true
			}
		}
		await store.receive(\.page.connectAgent.event.accountsChecked) {
			$0.page.modify(\.connectAgent) {
				$0.isChecking = false
				$0.accounts = [.claude: Self.claudeSignedIn, .openAI: Self.codexSignedOut]
			}
		}
		let page = store.state.page.connectAgent
		#expect(page?.status(of: .claude) == .signedIn(label: "me@example.com"))
		#expect(page?.status(of: .openAI) == .notSetUp(.signedOut(instructions: "Open Terminal and run: codex login")))
		#expect(page?.suggestedProvider == .claude)
		#expect(checks.value == 2)
		#expect(store.state.completedSteps == Self.earlierSteps)
	}

	@Test
	internal func statusesNameWhatThePersonHasToDo() {
		func status(_ status: AgentAccount.Status) -> OnboardingConnectAgent.Status {
			.init(.init(provider: .claude, status: status))
		}

		#expect(status(.signedIn(.init(id: "a", plan: "pro"))) == .signedIn(label: nil))
		#expect(status(.signedIn(.init(id: "a"))) == .signedIn(label: nil))
		#expect(status(.signedIn(.init(id: "a", plan: "Free"))) == .needsPaidPlan)
		#expect(status(.unsupportedSignIn(method: "API key")) == .notSetUp(.unsupportedSignIn(method: "API key")))
		#expect(status(.runtimeMissing) == .notSetUp(.missing))
		#expect(status(.unavailable) == .unavailable)
		#expect(!status(.signedIn(.init(id: "a", plan: "free"))).isReady)
	}

	@Test
	internal func nothingIsSuggestedUntilAProviderIsReady() {
		let state: OnboardingConnectAgent.State = .init(
			providers: [.claude, .openAI],
			accounts: [
				.claude: .init(provider: .claude, status: .signedIn(.init(id: "a", plan: "free"))),
				.openAI: Self.codexSignedOut,
			]
		)
		#expect(state.suggestedProvider == nil)
	}

	@Test
	internal func becomingActiveReadsTheSignInsAgain() async {
		let checks: LockIsolated<Int> = .init(0)
		let store = Self.store(accounts: [Self.claudeSignedIn, Self.codexSignedOut], checks: checks)
		store.exhaustivity = .off

		await store.send(.page(.connectAgent(.ui(.task))))
		await store.receive(\.page.connectAgent.event.accountsChecked)
		await store.send(.page(.connectAgent(.event(.applicationBecameActive))))
		await store.receive(\.page.connectAgent.event.accountsChecked)
		await store.send(.page(.connectAgent(.ui(.checkAgain))))
		await store.receive(\.page.connectAgent.event.accountsChecked)
		#expect(checks.value == 6)
	}

	// MARK: - Connect and Later

	@Test
	internal func connectRecordsTheStepAppliesTheProviderAndMovesOn() async {
		let store = Self.store(accounts: [Self.claudeSignedIn, Self.codexSignedOut])
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.page(.connectAgent(.ui(.task))))
		await store.receive(\.page.connectAgent.event.accountsChecked)
		store.exhaustivity = .on

		await store.send(.page(.connectAgent(.ui(.connect(.claude))))) {
			$0.page.modify(\.connectAgent) { $0.connected = .claude }
		}
		await store.receive(\.page.connectAgent.delegate.connected, .claude) {
			$0.completedSteps = Self.earlierSteps + [.connectAgent]
			$0.index = 4
			$0.page = .outsideAgents(.init())
		}
		await store.receive(\.delegate.stepCompleted, .connectAgent)
		await store.receive(\.delegate.agentConnected, .claude)
	}

	@Test
	internal func aProviderThatIsntReadyCantBeConnected() async {
		let store = Self.store(accounts: [Self.claudeSignedIn, Self.codexSignedOut])
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.page(.connectAgent(.ui(.task))))
		await store.receive(\.page.connectAgent.event.accountsChecked)
		store.exhaustivity = .on

		await store.send(.page(.connectAgent(.ui(.connect(.openAI)))))
		#expect(store.state.step == .connectAgent)
		#expect(store.state.completedSteps == Self.earlierSteps)
	}

	@Test
	internal func laterMovesOnWithoutRecordingAnything() async {
		let store = Self.store(accounts: [Self.claudeSignedIn, Self.codexSignedOut])

		await store.send(.ui(.skip)) {
			$0.index = 4
			$0.page = .outsideAgents(.init())
		}
		#expect(store.state.completedSteps == Self.earlierSteps)
	}

	@Test
	internal func theStepOpensOnItsOwnFromSettings() async {
		let store = Self.store(
			accounts: [Self.claudeSignedIn, Self.codexSignedOut],
			mode: .step(.connectAgent)
		)
		#expect(store.state.steps == [.connectAgent])
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.page(.connectAgent(.ui(.task))))
		await store.receive(\.page.connectAgent.event.accountsChecked)
		await store.send(.page(.connectAgent(.ui(.connect(.claude)))))
		await store.receive(\.delegate.agentConnected, .claude)
		await store.receive(\.delegate.dismissed)
	}

	// MARK: - Doubles

	private static func providers(
		accounts: [AgentAccount] = [claudeSignedIn, codexSignedOut],
		isEnabled: Bool = true,
		checks: LockIsolated<Int> = .init(0)
	) -> AgentProviders {
		.init(
			clients: accounts.map { account in
				var client: AgentProviderClient = .unimplemented(account.provider)
				client.account = {
					checks.withValue { $0 += 1 }
					return account
				}
				return client
			},
			isEnabled: isEnabled
		)
	}

	private static func store(
		accounts: [AgentAccount],
		checks: LockIsolated<Int> = .init(0),
		mode: OnboardingFeature.Mode = .flow
	) -> TestStoreOf<OnboardingFeature> {
		let providers: AgentProviders = providers(accounts: accounts, checks: checks)
		let state: OnboardingFeature.State = withDependencies {
			$0.agentProviders = providers
		} operation: {
			OnboardingFeature.State(mode: mode, completedSteps: earlierSteps)
		}
		return TestStore(initialState: state) {
			OnboardingFeature()
		} withDependencies: {
			$0.agentProviders = providers
		}
	}
}
