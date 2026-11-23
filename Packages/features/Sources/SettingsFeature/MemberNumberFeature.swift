import AppUI
import BrowserCore
import BrowserWorkspaceClient
import Foundation
import MemberNumberClient
import _ComposableArchitecture

/// The identity card's member number (DEV-701): Get your member number signs in with Apple,
/// sends the ID token once to Arx's server and shows the number it answers with.
///
/// The claim sends this Mac's install day too, and the answer carries the account's member-since
/// day, the earliest any of its Macs sent, which the card shows from then on (DEV-1323). Nothing is
/// asked again until the next claim: there's no refresh of its own.
///
/// The number is kept per Mac in UserDefaults and comes back without asking after a relaunch. It
/// doesn't sync through iCloud: the server gives the same account the same number on every Mac, so
/// each Mac claims it with its own sign-in, and the Production CloudKit schema stays unchanged.
@Reducer
public struct MemberNumberFeature {
	@ObservableState
	public struct State: Equatable {
		public var status: MemberNumberSection.Status

		/// The sign-ins this build offers; read when the section first appears.
		public var providers: [MemberSignInProvider]

		/// Whether the saved number and the providers were read.
		public var isLoaded: Bool

		public init(
			status: MemberNumberSection.Status = .notClaimed,
			providers: [MemberSignInProvider] = [],
			isLoaded: Bool = false
		) {
			self.status = status
			self.providers = providers
			self.isLoaded = isLoaded
		}

		/// The number on the card, once claimed.
		public var number: MemberNumber? {
			guard case let .claimed(number) = status else { return nil }
			return number
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(Observation)

		@CasePathable
		public enum UI: Sendable {
			/// Settings › Arx showed the card: restores a saved number.
			case appeared

			/// Get your member number, or Try Again, with one provider.
			case claim(MemberSignInProvider)
		}

		@CasePathable
		public enum Event: Sendable {
			case claimFinished(Result<MemberNumber, MemberNumberFailure>)
		}

		@CasePathable
		public enum Delegate: Sendable {}

		@CasePathable
		public enum Observation: Sendable {}
	}

	@Dependency(\.memberNumber)
	private var client

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.appeared) { state in
			guard !state.isLoaded else { return .none }

			state.isLoaded = true
			state.providers = client.availableProviders()
			if let number = client.load() {
				state.status = .claimed(number)
			}
			return .none
		}

		Pullback(\.ui.claim) { state, provider in
			switch state.status {
			case .notClaimed, .failed: break
			case .signingIn, .claimed: return .none
			}
			guard state.providers.contains(provider) else { return .none }

			state.status = .signingIn(provider)
			// This Mac's install day (DEV-1323): the server keeps the account's earliest and
			// answers with it, so every Mac's card shows the same date.
			@SharedReader(.installDate)
			var installDate
			let memberSince: String? = installDate.map { InstallDate.dayText($0) }
			return .run { [client] send in
				do throws(MemberNumberFailure) {
					let token = try await client.signIn(provider)
					let number = try await client.claim(provider, token, memberSince)
					client.save(number)
					await send(.event(.claimFinished(.success(number))))
				} catch {
					await send(.event(.claimFinished(.failure(error))))
				}
			}
			.cancellable(id: Cancellation.claim, cancelInFlight: true)
		}

		Pullback(\.event.claimFinished) { state, result in
			switch result {
			case let .success(number): state.status = .claimed(number)
			case let .failure(failure): state.status = .failed(failure)
			}
			return .none
		}
	}

	private enum Cancellation: Hashable {
		case claim
	}
}
