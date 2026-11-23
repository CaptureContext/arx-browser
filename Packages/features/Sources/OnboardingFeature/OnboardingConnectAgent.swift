import AgentClient
import ChatFeature
import _ComposableArchitecture

/// "Connect your agent": the built-in assistant's providers and whether each is ready.
///
/// Sign-in always happens in the provider's own app, so the page only reads each provider's
/// status and never starts a sign-in or a turn. A provider that's already signed in on a
/// subscription connects with one click; the parent records the step and makes it every
/// profile's assistant. Later (the footer's Skip) moves on without recording anything.
@Reducer
public struct OnboardingConnectAgent {
	@ObservableState
	public struct State: Equatable, Sendable {
		/// The providers this build ships, in the order the chat lists them.
		public var providers: [AgentProvider]

		/// The last status each provider reported; missing until its first check finishes.
		public var accounts: [AgentProvider: AgentAccount]

		/// Whether a status check is running.
		public var isChecking: Bool

		/// The provider connected from this page.
		public var connected: AgentProvider?

		public init(
			providers: [AgentProvider] = [],
			accounts: [AgentProvider: AgentAccount] = [:],
			isChecking: Bool = false,
			connected: AgentProvider? = nil
		) {
			self.providers = providers
			self.accounts = accounts
			self.isChecking = isChecking
			self.connected = connected
		}

		/// What the page says about a provider, or `nil` before its first check.
		public func status(of provider: AgentProvider) -> Status? {
			accounts[provider].map(Status.init)
		}

		/// The provider the main action connects: the first one that's ready.
		public var suggestedProvider: AgentProvider? {
			providers.first { status(of: $0)?.isReady == true }
		}
	}

	/// A provider's state, as the page names it.
	public enum Status: Equatable, Sendable {
		/// Signed in on a subscription Arx can use.
		case signedIn(label: String?)

		/// Signed in on a free plan, which the built-in assistant can't run on.
		case needsPaidPlan

		/// Not installed, not signed in, or signed in a way Arx refuses to use.
		case notSetUp(Reason)

		/// This run may not use agents, such as a test, smoke or headless run.
		case unavailable

		public enum Reason: Equatable, Sendable {
			case missing
			case signedOut(instructions: String)
			case unsupportedSignIn(method: String)
		}

		public init(_ account: AgentAccount) {
			switch account.status {
			case let .signedIn(identity):
				self = Self.isFreePlan(identity.plan) ? .needsPaidPlan : .signedIn(label: identity.label)

			case let .signedOut(instructions):
				self = .notSetUp(.signedOut(instructions: instructions))

			case let .unsupportedSignIn(method):
				self = .notSetUp(.unsupportedSignIn(method: method))

			case .runtimeMissing:
				self = .notSetUp(.missing)

			case .unavailable:
				self = .unavailable
			}
		}

		public var isReady: Bool {
			guard case .signedIn = self
			else { return false }

			return true
		}

		/// Providers report the plan in their own words; only an explicit free plan is refused.
		private static func isFreePlan(_ plan: String?) -> Bool {
			guard let plan
			else { return false }

			return ["free", "none"].contains(plan.trimmingCharacters(in: .whitespaces).lowercased())
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			/// The page appeared; reads every provider's status.
			case task

			/// Check Again, after signing in with the provider's own app.
			case checkAgain

			/// Connect on a provider's row, or the footer's Connect.
			case connect(AgentProvider)
		}

		@CasePathable
		public enum Event: Sendable {
			/// The app became active again; the person may have signed in from Terminal.
			case applicationBecameActive
			case accountsChecked([AgentAccount])
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// A ready provider was connected; the parent records the step and applies it.
			case connected(AgentProvider)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.agentProviders)
	private var agentProviders

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.task) { state in
			if state.providers.isEmpty {
				state.providers = agentProviders.providers
			}
			return check(&state)
		}

		Pullback(\.ui.checkAgain) { state in
			check(&state)
		}

		Pullback(\.event.applicationBecameActive) { state in
			check(&state)
		}

		Pullback(\.event.accountsChecked) { state, accounts in
			state.isChecking = false
			for account in accounts {
				state.accounts[account.provider] = account
			}
			return .none
		}

		Pullback(\.ui.connect) { state, provider in
			guard
				state.connected != provider,
				state.status(of: provider)?.isReady == true
			else { return .none }

			state.connected = provider
			return .send(.delegate(.connected(provider)))
		}
	}

	/// Cancels a status check still running, so leaving the page drops its result.
	public static func cancelInFlightWork<Action>() -> Effect<Action> {
		.cancel(id: Cancellation.check)
	}

	/// Reads each provider's status. It only asks the provider's own tool whether someone is
	/// signed in; it never signs in, changes a sign-in or sends anything to the provider.
	private func check(_ state: inout State) -> Effect<Action> {
		state.isChecking = true
		let clients: [AgentProviderClient] = state.providers.map { agentProviders[$0] }
		return .run { send in
			var accounts: [AgentAccount] = []
			for client in clients {
				accounts.append(await client.account())
			}
			await send(.event(.accountsChecked(accounts)))
		}
		.cancellable(id: Cancellation.check, cancelInFlight: true)
	}

	private enum Cancellation: Hashable {
		case check
	}
}
