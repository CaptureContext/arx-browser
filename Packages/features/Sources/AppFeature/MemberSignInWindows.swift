import BrowserCore
import BrowserEngineClient
import Foundation
import LittleArxFeature
import MemberNumberClient
import _ComposableArchitecture

/// The member number's sign-in with Apple while it's open (DEV-1323): the private Little Arx it
/// runs in.
public struct MemberSignInSession: Equatable, Sendable {
	/// The client's request, answered once.
	public let requestID: UUID
	public let windowID: UUID

	/// The scheme Arx's server redirects to with Apple's answer, lowercased.
	public let scheme: String

	/// The window is on screen.
	public var isOpen: Bool
}

@CasePathable
public enum MemberSignInAction: Sendable {
	/// Starts answering the member number client's sign-ins. Sent once at launch.
	case observe
	case requested(MemberSignInWindow.Request)
	/// The client stopped waiting: the window closes.
	case abandoned(UUID)
	/// The sign-in window reached the server's address with Apple's answer.
	case answered(URL)
	case timedOut(UUID)
}

/// Apple's sign-in for the member number, in a private Little Arx (`PrivateLittleArx`), with the
/// answer handed back to `MemberNumberClient` (DEV-1323).
///
/// When Arx's server redirects to `dev.capturecontext.arx.auth`, the engine offers that link to
/// the app as a link for another app; ``AppFeature/State/memberSignInLink(_:)`` takes it from
/// the sign-in window only, so no prompt shows and nothing else sees it, and drops every other
/// app's link from that window. The scheme isn't registered with macOS. The window then closes
/// and its profile goes. One sign-in at a time: closing the window by hand is a cancel; ten
/// minutes without an answer, a second sign-in while one is open, or a profile that can't be
/// prepared is a failed sign-in.
@Reducer
internal struct MemberSignInWindows {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	/// How long Apple's page may stay open without an answer.
	internal static let timeout: Duration = .seconds(600)

	@Dependency(\.memberSignInWindow)
	private var broker

	@Dependency(\.continuousClock)
	private var clock

	@Dependency(\.uuid)
	private var uuid

	private enum Cancellation: Hashable {
		case events
		case timeout
	}

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.memberSignIn.observe) { _ in
			.run { [broker] send in
				for await event in broker.events {
					switch event {
					case let .open(request): await send(.memberSignIn(.requested(request)))
					case let .cancelled(id): await send(.memberSignIn(.abandoned(id)))
					}
				}
			}
			.cancellable(id: Cancellation.events, cancelInFlight: true)
		}

		Pullback(\.memberSignIn.requested) { state, request in
			guard state.memberSignIn == nil else {
				broker.finish(request.id, with: .failure(.signInFailed))
				// The open one comes forward instead.
				if let open = state.memberSignIn, open.isOpen {
					state.focusedWindowID = open.windowID
					state.appActivationRequest += 1
				}
				return .none
			}

			let windowID = uuid()
			state.memberSignIn = .init(
				requestID: request.id,
				windowID: windowID,
				scheme: request.scheme.lowercased(),
				isOpen: false
			)
			return .send(.privateLittleArx(.open(windowID, request.url)))
		}

		Pullback(\.privateLittleArx.delegate.opened) { state, windowID in
			guard
				var session = state.memberSignIn,
				session.windowID == windowID
			else { return .none }

			session.isOpen = true
			state.memberSignIn = session
			let requestID = session.requestID
			return .run { [clock] send in
				try await clock.sleep(for: Self.timeout)
				await send(.memberSignIn(.timedOut(requestID)))
			}
			.cancellable(id: Cancellation.timeout, cancelInFlight: true)
		}

		Pullback(\.privateLittleArx.delegate.failed) { state, windowID in
			guard let session = state.memberSignIn, session.windowID == windowID else { return .none }

			state.memberSignIn = nil
			broker.finish(session.requestID, with: .failure(.signInFailed))
			return .none
		}

		Pullback(\.memberSignIn.answered) { state, url in
			guard let session = state.memberSignIn else { return .none }

			broker.finish(session.requestID, with: .success(url))
			return end(session, state: &state)
		}

		Pullback(\.memberSignIn.abandoned) { state, requestID in
			guard let session = state.memberSignIn, session.requestID == requestID else { return .none }

			return end(session, state: &state)
		}

		Pullback(\.memberSignIn.timedOut) { state, requestID in
			guard let session = state.memberSignIn, session.requestID == requestID else { return .none }

			broker.finish(requestID, with: .failure(.signInFailed))
			return end(session, state: &state)
		}

		// Closed by hand, or by its page: a cancel. PrivateLittleArx releases the profile.
		Pullback(\.littleWindows) { state, action in
			guard
				case let .element(id, .delegate(.closeApproved)) = action,
				let session = state.memberSignIn,
				session.windowID == id
			else { return .none }

			state.memberSignIn = nil
			broker.finish(session.requestID, with: .failure(.cancelled))
			return .cancel(id: Cancellation.timeout)
		}
	}

	/// Closes the sign-in window, or keeps it from opening.
	private func end(
		_ session: MemberSignInSession,
		state: inout State
	) -> Effect<Action> {
		state.memberSignIn = nil
		return .merge(
			.cancel(id: Cancellation.timeout),
			.send(.privateLittleArx(.close(session.windowID)))
		)
	}
}

extension AppFeature.State {
	/// What a link for another app from a page means for the member number's sign-in
	/// (DEV-1323).
	internal enum MemberSignInLink: Equatable {
		/// The sign-in window reached the server's address: Apple's answer.
		case answer(URL)
		/// Any other app's link from the sign-in window: dropped, never offered.
		case drop
	}

	/// `nil` unless `link` comes from the open sign-in window's page in its own private profile.
	/// Only that window can deliver the sign-in's scheme.
	internal func memberSignInLink(_ link: BrowserExternalLink) -> MemberSignInLink? {
		guard
			let session = memberSignIn,
			session.isOpen,
			let little = littleWindows[id: session.windowID],
			little.isPrivate,
			link.sourceTabID == little.tab.id,
			link.profileID == little.tab.profileID,
			privateLittleArxProfiles[session.windowID] == little.tab.profileID
		else { return nil }

		guard
			let url = URL(string: link.link),
			url.scheme?.lowercased() == session.scheme
		else { return .drop }

		return .answer(url)
	}
}
